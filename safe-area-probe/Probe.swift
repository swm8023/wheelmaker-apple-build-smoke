import SwiftUI
import WebKit

private let mode = ProcessInfo.processInfo.environment["SAFE_AREA_MODE"] ?? "baseline"

@main
struct SafeAreaProbe: App {
    var body: some Scene {
        WindowGroup {
            if mode == "container" || mode == "both" {
                Browser().ignoresSafeArea(.all, edges: .vertical)
            } else {
                Browser().ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
    }
}

private struct Browser: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ProbeController { ProbeController() }
    func updateUIViewController(_ controller: ProbeController, context: Context) {}
}

@MainActor
private final class ProbeController: UIViewController, WKNavigationDelegate {
    private let web = WKWebView(frame: .zero)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .lightGray
        web.navigationDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .never
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let viewport = mode == "viewport" || mode == "both" ? ",viewport-fit=cover" : ""
        web.loadHTMLString("""
            <!doctype html>
            <meta name="viewport" content="width=device-width,initial-scale=1\(viewport)">
            <style>
            html, body { margin: 0; background: #e6f7ff; }
            body { height: 100dvh; display: flex; flex-direction: column; justify-content: space-between; }
            header { padding-top: env(safe-area-inset-top, 0px); }
            footer { padding-bottom: max(6px, env(safe-area-inset-bottom, 0px)); }
            </style>
            <header>Header</header><footer><input placeholder="Composer"></footer>
            """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let result = try await web.callAsyncJavaScript("""
                    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                    const header = document.querySelector('header');
                    const footer = document.querySelector('footer');
                    return {
                      innerHeight, viewportHeight: visualViewport.height,
                      bodyHeight: document.body.getBoundingClientRect().height,
                      headerPadding: getComputedStyle(header).paddingTop,
                      footerPadding: getComputedStyle(footer).paddingBottom,
                      inputBottom: document.querySelector('input').getBoundingClientRect().bottom
                    };
                    """, arguments: [:], in: nil, contentWorld: .page)
                view.layoutIfNeeded()
                guard let window = view.window else { fatalError("Window unavailable") }
                let hostFrame = view.convert(view.bounds, to: window)
                let webFrame = web.convert(web.bounds, to: window)
                let record: [String: Any] = [
                    "mode": mode, "device": UIDevice.current.model,
                    "iOS": UIDevice.current.systemVersion,
                    "window": window.bounds.height, "windowWidth": window.bounds.width,
                    "windowSafeTop": window.safeAreaInsets.top, "windowSafeBottom": window.safeAreaInsets.bottom,
                    "hostTop": hostFrame.minY, "hostBottom": hostFrame.maxY, "hostHeight": hostFrame.height,
                    "webTop": webFrame.minY, "webBottom": webFrame.maxY, "webHeight": webFrame.height,
                    "webSafeTop": web.safeAreaInsets.top, "webSafeBottom": web.safeAreaInsets.bottom,
                    "scrollTop": web.scrollView.adjustedContentInset.top,
                    "scrollBottom": web.scrollView.adjustedContentInset.bottom,
                    "keyboardGuideTop": view.keyboardLayoutGuide.layoutFrame.minY,
                    "page": result,
                ]
                let data = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
                FileHandle.standardOutput.write(Data("SAFE_AREA_RESULT ".utf8) + data + Data("\n".utf8))
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("SAFE_AREA_ERROR \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }
}
