import SwiftUI
import UIKit
import WebKit

@main
struct KeyboardProbe: App {
    var body: some Scene {
        WindowGroup {
            ProbeView().ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}

private struct ProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ProbeController { ProbeController() }
    func updateUIViewController(_ controller: ProbeController, context: Context) {}
}

@MainActor
private final class ProbeController: UIViewController, WKNavigationDelegate {
    private let web = WKWebView(frame: .zero)
    private var shown = 0
    private var hidden = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        web.navigationDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)

        let guide = view.keyboardLayoutGuide
        guide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: guide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardShown(_:)),
                                               name: UIResponder.keyboardDidShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden(_:)),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        web.loadHTMLString(Self.document, baseURL: nil)
    }

    @objc private func keyboardShown(_ notification: Notification) { shown += 1 }
    @objc private func keyboardHidden(_ notification: Notification) { hidden += 1 }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let destination = URL.documentsDirectory.appendingPathComponent("result.json")
            do {
                let result = try await measure()
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                try data.write(to: destination, options: .atomic)
            } catch {
                let data = try? JSONSerialization.data(withJSONObject: ["error": String(describing: error)])
                try? data?.write(to: destination, options: .atomic)
            }
        }
    }

    private func measure() async throws -> [String: Any] {
        var cycles: [[String: Any]] = []
        for (index, mode) in ["short", "wrapped", "wrapped"].enumerated() {
            _ = try await web.evaluateJavaScript("prepare('\(mode)')")
            try await Task.sleep(for: .milliseconds(200))
            let before = try await snapshot()

            let previousShowCount = shown
            _ = try await web.evaluateJavaScript("startEditing()")
            try await waitForKeyboard("show") { shown > previousShowCount }
            try await Task.sleep(for: .milliseconds(250))
            let open = try await snapshot()

            let previousHideCount = hidden
            _ = try await web.evaluateJavaScript("document.getElementById('editor').blur(); true")
            try await waitForKeyboard("hide") { hidden > previousHideCount }
            let dismissed = try await snapshot()
            try await Task.sleep(for: .seconds(1))
            let settled = try await snapshot()
            cycles.append(["cycle": index + 1, "mode": mode, "before": before,
                           "open": open, "dismissed": dismissed, "settled": settled])
        }
        return ["iOS": UIDevice.current.systemVersion, "cycles": cycles]
    }

    private func waitForKeyboard(_ event: String, until condition: () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "KeyboardProbe", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Software keyboard did not \(event)"])
    }

    private func snapshot() async throws -> [String: Any] {
        view.layoutIfNeeded()
        guard let window = view.window,
              let page = try await web.evaluateJavaScript("geometry()") as? [String: Any] else {
            throw NSError(domain: "KeyboardProbe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Window or page geometry unavailable"])
        }
        let frame = web.convert(web.bounds, to: window)
        let scroll = web.scrollView
        return [
            "windowHeight": window.bounds.height,
            "windowSafeTop": window.safeAreaInsets.top,
            "windowSafeBottom": window.safeAreaInsets.bottom,
            "webTop": frame.minY,
            "webBottom": frame.maxY,
            "webHeight": frame.height,
            "webSafeBottom": web.safeAreaInsets.bottom,
            "keyboardGuideTop": view.keyboardLayoutGuide.layoutFrame.minY,
            "scrollOffsetY": scroll.contentOffset.y,
            "scrollContentHeight": scroll.contentSize.height,
            "scrollInsetBottom": scroll.adjustedContentInset.bottom,
            "page": page,
        ]
    }

    private static let document = """
        <!doctype html>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        *, *::before, *::after { box-sizing: border-box; }
        html, body, main { height: 100%; width: 100%; margin: 0; overflow: hidden; }
        body { background: #1e1e1e; color: white; font: 16px system-ui; }
        main { display: flex; flex-direction: column; }
        header { padding: max(8px, env(safe-area-inset-top, 0px)) 12px 8px; }
        section { min-height: 0; flex: 1; overflow-y: auto; overscroll-behavior: contain; padding: 12px; }
        footer { flex: none; padding: 0 12px max(6px, env(safe-area-inset-bottom, 0px)); }
        #editor { min-height: 34px; max-height: 180px; overflow-y: auto; padding: 6px 8px;
                  background: #2e2e2e; border-radius: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
        </style>
        <main>
          <header>Synthetic conversation</header>
          <section id="messages"></section>
          <footer id="composer">
            <div id="editor" contenteditable="true" role="textbox" aria-multiline="true" enterkeyhint="enter"></div>
          </footer>
        </main>
        <script>
        const editor = document.getElementById('editor');
        const messages = document.getElementById('messages');
        const composer = document.getElementById('composer');
        for (let index = 0; index < 40; index++) {
          const line = document.createElement('p');
          line.textContent = 'Sample message ' + (index + 1);
          messages.append(line);
        }
        function prepare(mode) {
          editor.textContent = mode === 'short'
            ? 'Draft'
            : 'This longer sample draft wraps onto multiple lines in a narrow chat composer. '.repeat(6);
          messages.scrollTop = messages.scrollHeight;
          return true;
        }
        function startEditing() {
          editor.focus();
          window.getSelection().collapse(editor.lastChild, editor.lastChild.length);
          return document.activeElement === editor;
        }
        function geometry() {
          const box = editor.getBoundingClientRect();
          return {
            innerHeight,
            documentHeight: document.documentElement.clientHeight,
            visualHeight: visualViewport.height,
            visualOffsetTop: visualViewport.offsetTop,
            visualScale: visualViewport.scale,
            pageScrollY: scrollY,
            composerPaddingBottom: getComputedStyle(composer).paddingBottom,
            composerBottom: composer.getBoundingClientRect().bottom,
            editorBottom: box.bottom,
            editorGapToVisualBottom: visualViewport.offsetTop + visualViewport.height - box.bottom,
            editorHeight: box.height,
            editorFocused: document.activeElement === editor,
            transcriptScrollTop: messages.scrollTop,
          };
        }
        </script>
        """
}
