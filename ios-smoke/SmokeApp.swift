import SwiftUI
import WebKit

@main
struct WheelMakerSmokeApp: App {
    var body: some Scene {
        WindowGroup { ConnectionView() }
    }
}

private struct ConnectionView: View {
    @AppStorage("hubAddress") private var hubAddress = ""
    @State private var address = ""
    @State private var activeURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("https://your-hub.example", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                Button("Connect", action: connect)
            }
            .padding(.horizontal)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if let activeURL {
                HubView(url: activeURL, errorMessage: $errorMessage)
                    .id(activeURL)
            } else {
                Spacer()
            }
        }
        .onAppear {
            address = hubAddress
            if !address.isEmpty { connect() }
        }
    }

    private func connect() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            errorMessage = "Enter a valid HTTPS Hub address."
            return
        }
        errorMessage = nil
        hubAddress = input
        activeURL = url
    }
}

private struct HubView: UIViewRepresentable {
    let url: URL
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator { Coordinator(errorMessage: $errorMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var errorMessage: String?

        init(errorMessage: Binding<String?>) {
            _errorMessage = errorMessage
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            errorMessage = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            errorMessage = error.localizedDescription
        }
    }
}
