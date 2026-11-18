import SwiftUI
import WebKit

struct EPUBReaderView: NSViewRepresentable {
    let reader: ReaderModel
    let chapterIndex: Int
    let anchorToken: Int
    let theme: ThemeSnapshot

    func makeCoordinator() -> Coordinator { Coordinator(reader: reader, theme: theme) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "folio")
        context.coordinator.installScripts(on: config.userContentController)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = theme.theme.background
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        reader.webView = webView
        context.coordinator.load(chapterIndex, token: anchorToken)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator
        if c.theme != theme {
            c.theme = theme
            c.installScripts(on: webView.configuration.userContentController)
            webView.underPageBackgroundColor = theme.theme.background
            let vars = (try? String(data: JSONSerialization.data(withJSONObject: theme.vars), encoding: .utf8)) ?? "{}"
            webView.evaluateJavaScript("window.folio && folio.setTheme(\(vars))", completionHandler: nil)
        }
        if c.loadedIndex != chapterIndex {
            c.load(chapterIndex, token: anchorToken)
        } else if c.anchorToken != anchorToken {
            c.anchorToken = anchorToken
            c.applyAnchor(smooth: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let reader: ReaderModel
        var theme: ThemeSnapshot
        weak var webView: WKWebView?
        var loadedIndex = -1
        var anchorToken = -1
        var isFirstLoad = true

        init(reader: ReaderModel, theme: ThemeSnapshot) {
            self.reader = reader
            self.theme = theme
        }

        func installScripts(on ucc: WKUserContentController) {
            ucc.removeAllUserScripts()
            ucc.addUserScript(WKUserScript(source: ReaderScripts.bootstrap(theme: theme), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            ucc.addUserScript(WKUserScript(source: ReaderScripts.js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        func load(_ index: Int, token: Int) {
            guard let epub = reader.epub, let webView, epub.spine.indices.contains(index) else { return }
            loadedIndex = index
            anchorToken = token
            webView.alphaValue = 0
            webView.loadFileURL(epub.spine[index], allowingReadAccessTo: epub.root)
        }

        func applyAnchor(smooth: Bool) {
            guard let anchor = reader.pendingAnchor else { return }
            let script: String
            switch anchor {
            case .top: script = "window.scrollTo(0, 0)"
            case .fraction(let f): script = "folio.scrollToFraction(\(f))"
            case .fragment(let f): script = "folio.scrollToFragment(\(ReaderScripts.jsonString(f)), \(smooth))"
            case .highlight(let id): script = "folio.scrollToHighlight(\(ReaderScripts.jsonString(id)), \(smooth))"
            case .search(let q, let n): script = "folio.find(\(ReaderScripts.jsonString(q)), \(n), \(smooth))"
            }
            webView?.evaluateJavaScript(script, completionHandler: nil)
            DispatchQueue.main.async { [reader] in
                if reader.pendingAnchor == anchor { reader.pendingAnchor = nil }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let highlights = ReaderModel.json(reader.chapterHighlights(loadedIndex))
            let nextTitle: String
            if let epub = reader.epub, loadedIndex + 1 < epub.spine.count {
                nextTitle = ReaderScripts.jsonString(epub.chapterTitle(loadedIndex + 1))
            } else {
                nextTitle = "null"
            }
            webView.evaluateJavaScript("folio.load(\(highlights)); folio.setNext(\(nextTitle)); \(reader.searchMarkScript)") { [weak self] _, _ in
                guard let self else { return }
                self.applyAnchor(smooth: false)
                if self.isFirstLoad || !(webView.window?.firstResponder is NSTextView) {
                    webView.window?.makeFirstResponder(webView)
                }
                self.isFirstLoad = false
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    webView.animator().alphaValue = 1
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL, let epub = reader.epub {
                let fragment = url.fragment
                var base = URLComponents(url: url, resolvingAgainstBaseURL: false)
                base?.fragment = nil
                if let target = base?.url, let idx = epub.spineIndex(of: target) {
                    if idx == loadedIndex {
                        decisionHandler(.allow)
                    } else {
                        decisionHandler(.cancel)
                        reader.goToChapter(idx, anchor: fragment.map { .fragment($0) } ?? .top)
                    }
                    return
                }
                decisionHandler(.cancel)
                return
            }
            if reader.videoID != nil, let seconds = YouTube.timestamp(in: url) {
                reader.seekVideo(seconds)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            let text = body["text"] as? String ?? ""
            let id = body["id"] as? String ?? ""
            let color = (body["color"] as? String).flatMap(HighlightColor.init(rawValue:)) ?? .yellow
            switch type {
            case "highlight":
                guard let s = body["start"] as? NSNumber, let e = body["end"] as? NSNumber else { return }
                reader.addEPUBHighlight(start: s.intValue, end: e.intValue, text: text, color: color)
            case "recolor": reader.recolor(id, to: color)
            case "remove": reader.removeHighlight(id)
            case "ask": reader.ask(about: text)
            case "copy":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "scroll":
                if let f = body["fraction"] as? NSNumber { reader.updateFraction(f.doubleValue) }
            case "nav":
                if (body["dir"] as? NSNumber)?.intValue ?? 0 > 0 { reader.next() } else { reader.previous() }
            default: break
            }
        }
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
