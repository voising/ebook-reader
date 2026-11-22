import SwiftUI
import WebKit

struct VideoSeek: Equatable {
    var time: Double
    var token: Int
    /// True when the seek was requested while the player was hidden, so a new player must start there.
    var startsThere = false
}

/// Imports a YouTube video's transcript (via `yt-dlp`) and packages it as an EPUB, one chapter per video
/// chapter, so everything that works on a book — highlights, chat, maps, cards — works on a video.
enum YouTube {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Segment {
        var start: Double
        var text: String
    }

    // MARK: Identity

    /// The video id for an EPUB this importer created, or nil for ordinary books.
    static func videoID(forImported book: EPUBBook?) -> String? {
        guard let identifier = book?.identifier, identifier.hasPrefix("youtube:") else { return nil }
        return videoID(from: String(identifier.dropFirst("youtube:".count)))
    }

    static func videoID(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return trimmed }
        guard let comps = URLComponents(string: trimmed), let host = comps.host?.lowercased() else { return nil }
        let valid: (String) -> String? = { $0.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil ? $0 : nil }
        if host.hasSuffix("youtu.be") { return valid(String(comps.path.dropFirst().prefix(11))) }
        guard host.contains("youtube") else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return valid(v) }
        let parts = comps.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) { return valid(parts[1]) }
        return nil
    }

    /// Seconds for a timestamp link written into a transcript.
    static func timestamp(in url: URL) -> Double? {
        guard let host = url.host?.lowercased(), host.contains("youtube") || host.contains("youtu.be"),
              let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value else { return nil }
        return Double(t.trimmingCharacters(in: CharacterSet(charactersIn: "s")))
    }

    static func epubURL(_ id: String) -> URL {
        AppPaths.videos.appendingPathComponent("\(id).epub")
    }

    // MARK: Import

    #if os(macOS)
    static func importVideo(_ input: String, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let id = videoID(from: input) else { throw ImportError(message: "That doesn't look like a YouTube link.") }
        let out = epubURL(id)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let ytdlp = tool("yt-dlp") else {
            throw ImportError(message: "Importing videos needs yt-dlp. Install it with `brew install yt-dlp`, then try again.")
        }
        let watch = "https://www.youtube.com/watch?v=\(id)"

        status("Fetching video details…")
        let meta = try await run(ytdlp, ["-J", "--no-playlist", "--no-warnings", watch])
        guard meta.status == 0, let info = try? JSONSerialization.jsonObject(with: meta.stdout) as? [String: Any] else {
            throw ImportError(message: lastLine(meta.stderr) ?? "Couldn't read that video.")
        }
        let title = (info["title"] as? String)?.collapsed.nilIfEmpty ?? "YouTube video"
        let channel = ((info["channel"] as? String) ?? (info["uploader"] as? String) ?? "").collapsed
        let duration = (info["duration"] as? NSNumber)?.doubleValue ?? 0
        guard let lang = captionLanguage(info) else {
            throw ImportError(message: "This video has no captions, so there's no transcript to import.")
        }

        status("Downloading the transcript…")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("folio-yt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let subs = try await run(ytdlp, ["--skip-download", "--no-playlist", "--no-warnings", "--write-subs", "--write-auto-subs",
                                         "--sub-langs", lang, "--sub-format", "json3", "-o", work.appendingPathComponent("sub").path, watch])
        let file = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "json3" }
        guard let file, let data = try? Data(contentsOf: file) else {
            throw ImportError(message: lastLine(subs.stderr) ?? "The transcript couldn't be downloaded.")
        }
        let segments = parseJSON3(data)
        guard segments.count > 3 else { throw ImportError(message: "The transcript for this video is empty.") }

        status("Building the transcript…")
        var chapters: [(start: Double, title: String)] = ((info["chapters"] as? [[String: Any]]) ?? []).compactMap { c in
            guard let start = (c["start_time"] as? NSNumber)?.doubleValue else { return nil }
            return (start, (c["title"] as? String)?.collapsed.nilIfEmpty ?? "Chapter")
        }
        if chapters.count < 2 {
            let end = max(duration, segments.last?.start ?? 0)
            let step: Double = 600
            chapters = end <= 900 ? [(0, "Transcript")]
                : stride(from: 0, to: end, by: step).map { ($0, "\(clock($0)) – \(clock(min($0 + step, end)))") }
        }
        if let first = chapters.first, first.start > 1 { chapters.insert((0, "Introduction"), at: 0) }

        let cover = try? await URLSession.shared.data(from: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!).0
        try buildEPUB(id: id, title: title, channel: channel, lang: lang, chapters: chapters, segments: segments, cover: cover, in: work, to: out)
        return out
    }

    /// Manual captions in the video's language if there are any, otherwise the auto-generated original track.
    private static func captionLanguage(_ info: [String: Any]) -> String? {
        let manual = ((info["subtitles"] as? [String: Any]) ?? [:]).keys.filter { $0 != "live_chat" }
        let auto = Array(((info["automatic_captions"] as? [String: Any]) ?? [:]).keys)
        let spoken = info["language"] as? String
        func pick(_ keys: [String], _ want: String?) -> String? {
            guard let want else { return nil }
            let base = String(want.split(separator: "-").first ?? Substring(want))
            return keys.first { $0 == want } ?? keys.first { $0 == base } ?? keys.first { $0.hasPrefix(base + "-") }
        }
        if let m = pick(manual, spoken) ?? pick(manual, "en") ?? manual.sorted().first { return m }
        // Auto captions: the "-orig" tracks are speech recognition; the rest are machine translations of them.
        let origs = auto.filter { $0.hasSuffix("-orig") }.sorted()
        if let orig = pick(origs, spoken) ?? pick(origs, "en") ?? origs.first { return orig }
        return pick(auto, spoken) ?? pick(auto, "en") ?? nil
    }

    static func parseJSON3(_ data: Data) -> [Segment] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        var out: [Segment] = []
        for e in events {
            guard let start = (e["tStartMs"] as? NSNumber)?.doubleValue, let segs = e["segs"] as? [[String: Any]] else { continue }
            let text = segs.compactMap { $0["utf8"] as? String }.joined().collapsed
            guard !text.isEmpty else { continue }
            out.append(Segment(start: start / 1000, text: text))
        }
        return out
    }

    /// Groups caption fragments into readable paragraphs, each starting at a known time.
    static func paragraphs(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var current: Segment?
        var words = 0
        for (i, seg) in segments.enumerated() {
            if current == nil { current = Segment(start: seg.start, text: ""); words = 0 }
            current!.text += (current!.text.isEmpty ? "" : " ") + seg.text
            words += seg.text.split(separator: " ").count
            let endsSentence = seg.text.last.map { ".?!…".contains($0) } ?? false
            let pause = i + 1 < segments.count ? segments[i + 1].start - seg.start > 6 : true
            if words >= 130 || (words >= 60 && (endsSentence || pause)) {
                out.append(current!)
                current = nil
            }
        }
        if let current, !current.text.isEmpty { out.append(current) }
        return out
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func buildEPUB(id: String, title: String, channel: String, lang: String,
                                  chapters: [(start: Double, title: String)], segments: [Segment], cover: Data?,
                                  in work: URL, to out: URL) throws {
        let fm = FileManager.default
        let root = work.appendingPathComponent("epub", isDirectory: true)
        let oebps = root.appendingPathComponent("OEBPS", isDirectory: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)

        try Data("application/epub+zip".utf8).write(to: root.appendingPathComponent("mimetype"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))

        let code = String(lang.prefix(2))
        var files: [(name: String, title: String)] = []
        for (i, chapter) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].start : .greatestFiniteMagnitude
            let paras = paragraphs(segments.filter { $0.start >= chapter.start && $0.start < end })
            guard !paras.isEmpty else { continue }
            let name = String(format: "ch%03d.xhtml", i + 1)
            let body = paras.map { p in
                "<p><a class=\"ts\" href=\"https://www.youtube.com/watch?v=\(id)&amp;t=\(Int(p.start))s\">\(clock(p.start))</a> \(escape(p.text))</p>"
            }.joined(separator: "\n")
            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(code)" lang="\(code)">
            <head><meta charset="utf-8"/><title>\(escape(chapter.title))</title>
            <style>a.ts { font: 600 0.62em ui-monospace, Menlo, monospace; text-decoration: none; opacity: 0.6; margin-right: 0.5em; vertical-align: 0.15em; } a.ts:hover { opacity: 1; }</style>
            </head>
            <body><h2>\(escape(chapter.title))</h2>
            \(body)
            </body></html>
            """.utf8).write(to: oebps.appendingPathComponent(name))
            files.append((name, chapter.title))
        }
        guard !files.isEmpty else { throw ImportError(message: "The transcript for this video is empty.") }

        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>Contents</title></head>
        <body><nav epub:type="toc"><ol>
        \(files.map { "<li><a href=\"\($0.name)\">\(escape($0.title))</a></li>" }.joined(separator: "\n"))
        </ol></nav></body></html>
        """.utf8).write(to: oebps.appendingPathComponent("nav.xhtml"))

        if let cover { try cover.write(to: oebps.appendingPathComponent("cover.jpg")) }
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">youtube:\(id)</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:creator>\(escape(channel))</dc:creator>
            <dc:language>\(code)</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(cover != nil ? "<item id=\"cover\" href=\"cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>" : "")
            \(files.enumerated().map { "<item id=\"c\($0.offset)\" href=\"\($0.element.name)\" media-type=\"application/xhtml+xml\"/>" }.joined(separator: "\n    "))
          </manifest>
          <spine>
            \(files.indices.map { "<itemref idref=\"c\($0)\"/>" }.joined(separator: "\n    "))
          </spine>
        </package>
        """.utf8).write(to: oebps.appendingPathComponent("content.opf"))

        let staged = work.appendingPathComponent("\(id).epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-X", "-r", "-q", staged.path, "mimetype", "META-INF", "OEBPS"]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ImportError(message: "Couldn't package the transcript.") }
        try? fm.removeItem(at: out)
        try fm.moveItem(at: staged, to: out)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Processes

    private static func tool(_ name: String) -> URL? {
        for dir in (ClaudeCLI.environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    private static func lastLine(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)?.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "ERROR: ", with: "") }
    }

    private static func run(_ exe: URL, _ args: [String]) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        try await Task.detached(priority: .userInitiated) { try runBlocking(exe, args) }.value
    }

    private static func runBlocking(_ exe: URL, _ args: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = ClaudeCLI.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Drain both pipes at once so a chatty stderr can't block the process.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, stdout, errBox.data)
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
    #else
    static func importVideo(_ input: String, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        throw ImportError(message: "Videos are added in Folio on your Mac. They show up here through iCloud.")
    }
    #endif
}

// MARK: - Player

/// The video, embedded above its transcript. Timestamp links in the text seek it.
struct VideoPlayerView: PlatformViewRepresentable {
    let videoID: String
    let seek: VideoSeek

    final class Coordinator {
        var token = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.makeTransparent()
        context.coordinator.token = seek.token
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html, body { margin: 0; height: 100%; background: #000; overflow: hidden; } #p { width: 100%; height: 100%; }</style></head>
        <body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player, ready = false, pending = \(seek.startsThere ? String(seek.time) : "null");
        function onYouTubeIframeAPIReady() {
            player = new YT.Player('p', { videoId: '\(videoID)', width: '100%', height: '100%',
                playerVars: { playsinline: 1, rel: 0, origin: location.origin },
                events: { onReady: function () { ready = true; if (pending !== null) { seek(pending); pending = null; } } } });
        }
        function seek(t) {
            if (!ready) { pending = t; return; }
            player.seekTo(t, true); player.playVideo();
        }
        </script></body></html>
        """
        // An https base gives the embed the origin and referrer YouTube requires.
        webView.loadHTMLString(html, baseURL: URL(string: "https://folio.reader.app/"))
        return webView
    }

    func updateView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.token != seek.token else { return }
        context.coordinator.token = seek.token
        webView.evaluateJavaScript("seek(\(seek.time))", completionHandler: nil)
    }
}

// MARK: - Add sheet

/// Adds something from the web to the library: an article from any site, or a YouTube video's transcript.
struct AddLinkSheet: View {
    /// A YouTube link (or bare video id) imports the video; any other web link imports the article.
    static func isVideo(_ link: String) -> Bool {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTube.videoID(from: text) != nil else { return false }
        return text.lowercased().contains("youtu") || !text.contains(".")
    }

    static func isValid(_ link: String) -> Bool { isVideo(link) || Articles.link(from: link) != nil }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var status: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Link").font(.scaled(size: 18, weight: .semibold, design: .serif))
            Text(Platform.hasClaude
                 ? "Paste a link to an article or a YouTube video. Folio turns the article, or the video's transcript, into something you can read, highlight and study like a book."
                 : "Paste a link to an article. Folio turns it into something you can read and highlight like a book. Videos are added from your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…", text: $link)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(status != nil)
                .onSubmit(start)
            if let status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.scaled(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(status != nil || !Self.isValid(link))
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            focused = true
            #if os(macOS)
            // A link already on the clipboard is almost always the one being added.
            if link.isEmpty, let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.hasPrefix("http"), Self.isValid(clip) {
                link = clip
            }
            #endif
        }
    }

    private func start() {
        guard status == nil, Self.isValid(link) else { return }
        error = nil
        status = "Starting…"
        let input = link
        task = Task {
            do {
                let url: URL
                if Self.isVideo(input) {
                    url = try await YouTube.importVideo(input) { message in
                        Task { @MainActor in if status != nil { status = message } }
                    }
                } else {
                    url = try await Articles.importArticle(input) { message in if status != nil { status = message } }
                }
                guard !Task.isCancelled else { return }
                status = nil
                dismiss()
                app.open(url)
            } catch {
                status = nil
                self.error = error.localizedDescription
            }
        }
    }
}
