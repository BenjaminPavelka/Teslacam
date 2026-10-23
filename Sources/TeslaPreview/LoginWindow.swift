import SwiftUI
import TeslaCamCore
import WebKit

/// Okno s dashcam.tesla.com. Po přihlášení stačí přetáhnout do stránky libovolný
/// šifrovaný klip: stránka si řekne o klíč a my z jejího vlastního požadavku
/// zachytíme hlavičku `Authorization`. Nic se neukládá (neperzistentní úložiště).
struct LoginWindow: View {
    static let id = "login"

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.token == nil ? "1.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.token == nil ? Color.accentColor : .green)
                VStack(alignment: .leading, spacing: 2) {
                    if model.token == nil {
                        Text("Přihlas se ke svému Tesla účtu.").bold()
                        Text("Pak do stránky přetáhni libovolný šifrovaný klip (nebo ho vyber tlačítkem na stránce). Token se zachytí sám a okno se zavře.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Token zachycen.").bold()
                        Text("Okno můžeš zavřít.").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(.bar)
            Divider()
            TeslaWebView { raw in
                model.acceptToken(raw)
                if model.token != nil { dismissWindow(id: Self.id) }
            }
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}

struct TeslaWebView: NSViewRepresentable {
    let onToken: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.captureScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: .page
        ))
        controller.add(context.coordinator, contentWorld: .page, name: "teslaToken")
        config.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: config)
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: TeslaKeyClient.origin))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "teslaToken", contentWorld: .page)
    }

    /// Obalí fetch a XMLHttpRequest a nahlásí hodnotu hlavičky Authorization.
    static let captureScript = """
    (function () {
      const report = (value) => {
        try {
          if (typeof value === 'string' && /^\\s*bearer\\s+eyJ/i.test(value)) {
            window.webkit.messageHandlers.teslaToken.postMessage(value);
          }
        } catch (e) {}
      };
      const fromHeaders = (headers) => {
        if (!headers) return;
        if (typeof Headers !== 'undefined' && headers instanceof Headers) { report(headers.get('Authorization')); return; }
        if (Array.isArray(headers)) { headers.forEach(([k, v]) => { if (/^authorization$/i.test(k)) report(v); }); return; }
        for (const k in headers) { if (/^authorization$/i.test(k)) report(headers[k]); }
      };
      const originalFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          if (init && init.headers) fromHeaders(init.headers);
          if (typeof Request !== 'undefined' && input instanceof Request) fromHeaders(input.headers);
        } catch (e) {}
        return originalFetch.apply(this, arguments);
      };
      const originalSet = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        if (/^authorization$/i.test(name)) report(value);
        return originalSet.apply(this, arguments);
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        let onToken: @MainActor (String) -> Void

        init(onToken: @escaping @MainActor (String) -> Void) { self.onToken = onToken }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Přijmout jen z dashcam.tesla.com přes HTTPS, ne z jiných rámců.
            let origin = message.frameInfo.securityOrigin
            guard origin.protocol == "https", origin.host == TeslaKeyClient.origin.host,
                  let value = message.body as? String
            else { return }
            MainActor.assumeIsolated { onToken(value) }
        }

        /// Tlačítko „vybrat soubor“ na stránce.
        func webView(
            _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.message = "Vyber libovolný šifrovaný klip, aby stránka požádala o klíč"
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }
}
