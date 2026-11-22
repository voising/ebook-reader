import AVFoundation
import CryptoKit
import NaturalLanguage
import PDFKit
import SwiftUI

/// One stretch of audio: a paragraph (or part of a long one) made of whole sentences.
struct ListenClip: Equatable {
    /// The paragraph (EPUB) or page (PDF) the text comes from.
    let block: Int
    /// What is spoken.
    let text: String
    /// Where each sentence sits in the block's text (UTF-16), for the moving highlight.
    let sentences: [NSRange]
}

enum ListenText {
    /// Splits a block into clips of whole sentences, each short enough to voice in one go.
    static func clips(block: Int, text: String, limit: Int = 900) -> [ListenClip] {
        let ns = text as NSString
        var sentences: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            // A run with no sentence breaks (a table, a list of names) is cut into pieces of a workable size.
            var rest = range
            while rest.length > limit * 2 {
                sentences.append(NSRange(location: rest.location, length: limit))
                rest = NSRange(location: rest.location + limit, length: rest.length - limit)
            }
            sentences.append(rest)
        }
        var out: [ListenClip] = []
        var group: [NSRange] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let spoken = Self.spoken(ns.substring(with: NSRange(location: first.location, length: NSMaxRange(last) - first.location)))
            if spoken.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                out.append(ListenClip(block: block, text: spoken, sentences: group))
            }
            group = []
        }
        var length = 0
        for sentence in sentences {
            if length > 0, length + sentence.length > limit { flush(); length = 0 }
            group.append(sentence)
            length += sentence.length
        }
        flush()
        return out
    }

    /// Tidies text for speech: rejoins words hyphenated across a line break and flattens line breaks.
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: "-\n", with: "").collapsed
    }
}

struct ListenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The OpenAI key for the natural voice, kept in this device's Keychain and nowhere else.
enum Secrets {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.voz.folio",
        kSecAttrAccount as String: "openai-api-key",
    ]

    static var openAIKey: String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfEmpty
    }

    @discardableResult
    static func setOpenAIKey(_ key: String?) -> Bool {
        SecItemDelete(item as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return true }
        var add = item
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Voices text with OpenAI's speech model. Each clip is cached on disk, so hearing a chapter again costs nothing.
enum OpenAISpeech {
    static let voice = "cedar"
    static let direction = """
    A warm, clear narrator reading a book aloud to a friend. Natural conversational pace, unhurried and easy to \
    follow. Not an advert: no hype, no dramatic pauses, no whispering.
    """

    private static let cache: URL = {
        let dir = AppPaths.caches.appendingPathComponent("Listen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func audio(for text: String, key: String) async throws -> Data {
        let name = SHA256.hash(data: Data("gpt-4o-mini-tts|\(voice)|\(direction)|\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
        let file = cache.appendingPathComponent("\(name).mp3")
        if let cached = try? Data(contentsOf: file), !cached.isEmpty { return cached }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts", "voice": voice, "input": text, "instructions": direction, "response_format": "mp3",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }.flatMap { $0["message"] as? String }
            switch status {
            case 401: throw ListenError(message: "OpenAI didn't accept the key. Check it in the voice settings.")
            case 429: throw ListenError(message: "OpenAI turned the request down: the account is out of credit or over its rate limit.")
            default: throw ListenError(message: detail ?? "OpenAI couldn't voice this part (status \(status)).")
            }
        }
        try? data.write(to: file, options: .atomic)
        return data
    }
}

/// Reads the current chapter aloud, moving a highlight over the sentence being spoken.
@Observable @MainActor
final class ListenModel {
    enum State { case idle, preparing, playing, paused }

    private(set) var state = State.idle
    private(set) var clips: [ListenClip] = []
    private(set) var index = 0
    /// True while the next stretch of audio is still being fetched.
    private(set) var isBuffering = false
    private(set) var error: String?
    private(set) var usingOpenAI = false
    var speed = UserDefaults.standard.object(forKey: "listenSpeed") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "listenSpeed")
            player?.rate = playerRate
        }
    }

    @ObservationIgnored weak var reader: ReaderModel?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let relay = Relay()
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var pending: [Int: Task<Data, Error>] = [:]
    @ObservationIgnored private var sentence = -1
    @ObservationIgnored private var voiceCode = "en-US"
    /// Bumped whenever playback moves, so callbacks from an earlier clip are ignored.
    @ObservationIgnored private var generation = 0

    var isActive: Bool { state != .idle }
    var isVisible: Bool { isActive || error != nil }

    /// The approved near-natural tempo for this voice, times the listener's own speed.
    private var playerRate: Float { Float(speed * 1.04) }

    init() {
        synthesizer.delegate = relay
        relay.finished = { [weak self] token in self?.clipFinished(token) }
        relay.spoke = { [weak self] token, fraction in self?.progress(token, fraction) }
    }

    // MARK: Controls

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard let reader, state == .idle else { return }
        error = nil
        state = .preparing
        key = Secrets.openAIKey
        usingOpenAI = key != nil
        generation += 1
        let token = generation
        Task {
            let (clips, first) = await reader.listenClips()
            guard token == generation, state == .preparing else { return }
            guard !clips.isEmpty else {
                state = .idle
                error = "There is no text to read here."
                return
            }
            self.clips = clips
            voiceCode = WordStore.voiceLanguage(for: clips.prefix(4).map(\.text).joined(separator: " "))
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            play(at: first)
        }
    }

    func stop() {
        halt()
        pending.values.forEach { $0.cancel() }
        pending = [:]
        if state != .idle { reader?.listenClear() }
        state = .idle
        clips = []
        index = 0
    }

    func dismissError() { error = nil }

    func pauseOrResume() {
        switch state {
        case .playing:
            if usingOpenAI { player?.pause() } else { synthesizer.pauseSpeaking(at: .word) }
            state = .paused
        case .paused:
            if usingOpenAI { player?.play() } else { synthesizer.continueSpeaking() }
            state = .playing
        default: break
        }
    }

    func skip(_ step: Int) {
        guard isActive, !clips.isEmpty else { return }
        play(at: max(0, min(index + step, clips.count - 1)))
    }

    // MARK: Playback

    /// Silences whatever is playing and invalidates its callbacks.
    private func halt() {
        generation += 1
        run?.cancel()
        ticker?.cancel()
        player?.stop()
        player = nil
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        isBuffering = false
    }

    private func play(at i: Int) {
        halt()
        guard clips.indices.contains(i) else { stop(); return }
        index = i
        state = .playing
        sentence = -1
        mark(0)
        let token = generation
        let clip = clips[i]
        if let key {
            isBuffering = true
            run = Task {
                do {
                    let data = try await audio(i, key: key).value
                    guard token == generation else { return }
                    isBuffering = false
                    // Fetch one clip ahead, so the next paragraph starts without a gap.
                    if clips.indices.contains(i + 1) { _ = audio(i + 1, key: key) }
                    let player = try AVAudioPlayer(data: data)
                    player.delegate = relay
                    player.enableRate = true
                    player.rate = playerRate
                    relay.token = token
                    self.player = player
                    player.play()
                    follow(player, token: token)
                } catch {
                    guard token == generation else { return }
                    // No retry and no silent change of voice: stop and say why.
                    let message = (error as? ListenError)?.message ?? "Couldn't get the audio: \(error.localizedDescription)"
                    stop()
                    self.error = message
                }
            }
        } else {
            let utterance = AVSpeechUtterance(string: clip.text)
            utterance.voice = AVSpeechSynthesisVoice(language: voiceCode)
                ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(String(voiceCode.prefix(2))) }
            utterance.rate = Float(min(0.62, max(0.35, Double(AVSpeechUtteranceDefaultSpeechRate) + (speed - 1) * 0.12)))
            relay.token = token
            synthesizer.speak(utterance)
        }
    }

    private func audio(_ i: Int, key: String) -> Task<Data, Error> {
        if let task = pending[i] { return task }
        let text = clips[i].text
        let task = Task.detached(priority: .userInitiated) { try await OpenAISpeech.audio(for: text, key: key) }
        pending[i] = task
        return task
    }

    /// Moves the highlight along with the recording, by how far through the clip it is.
    private func follow(_ player: AVAudioPlayer, token: Int) {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, token == self.generation, player.duration > 0 else { return }
                self.progress(token, player.currentTime / player.duration)
            }
        }
    }

    private func progress(_ token: Int, _ fraction: Double) {
        guard token == generation, clips.indices.contains(index) else { return }
        let ranges = clips[index].sentences
        let total = ranges.reduce(0) { $0 + $1.length }
        guard total > 0 else { return }
        var covered = 0.0
        for (k, range) in ranges.enumerated() {
            covered += Double(range.length) / Double(total)
            if fraction < covered || k == ranges.count - 1 { mark(k); return }
        }
    }

    private func mark(_ k: Int) {
        guard k != sentence, clips.indices.contains(index), clips[index].sentences.indices.contains(k) else { return }
        sentence = k
        reader?.listenMark(block: clips[index].block, range: clips[index].sentences[k])
    }

    private func clipFinished(_ token: Int) {
        guard token == generation, state == .playing else { return }
        if index + 1 < clips.count { play(at: index + 1) } else { stop() }
    }
}

/// Forwards the audio engines' callbacks to the main thread, tagged with the clip they belong to.
private final class Relay: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var token = 0
    var finished: (@MainActor (Int) -> Void)?
    var spoke: (@MainActor (Int, Double) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let token = token
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished?(token) } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let token = token
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finished?(token) } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let token = token
        let length = (utterance.speechString as NSString).length
        guard length > 0 else { return }
        let fraction = Double(characterRange.location) / Double(length)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.spoke?(token, fraction) } }
    }
}

// MARK: - Reader side

extension ReaderModel {
    /// The text to read, from where the reader is now to the end of the chapter (EPUB) or onwards page by page (PDF).
    func listenClips() async -> (clips: [ListenClip], first: Int) {
        if kind == .epub {
            struct Blocks: Decodable { let first: Int; let texts: [String] }
            guard let webView,
                  let raw = try? await webView.evaluateJavaScript("folio.listenStart()") as? String,
                  let blocks = try? JSONDecoder().decode(Blocks.self, from: Data(raw.utf8)) else { return ([], 0) }
            let clips = blocks.texts.enumerated().flatMap { ListenText.clips(block: $0.offset, text: $0.element) }
            return (clips, clips.firstIndex { $0.block >= blocks.first } ?? 0)
        }
        guard let pdf else { return ([], 0) }
        var clips: [ListenClip] = []
        for page in pageIndex..<min(pdf.pageCount, pageIndex + 80) {
            if let text = pdf.page(at: page)?.string { clips += ListenText.clips(block: page, text: text) }
        }
        return (clips, 0)
    }

    func listenMark(block: Int, range: NSRange) {
        if kind == .epub {
            webView?.evaluateJavaScript("folio.listenAt(\(block), \(range.location), \(NSMaxRange(range)))", completionHandler: nil)
        } else if let page = pdf?.page(at: block), let selection = page.selection(for: range) {
            selection.color = PlatformColor.systemBlue.withAlphaComponent(0.28)
            pdfView?.highlightedSelections = [selection]
            pdfView?.go(to: selection)
        }
    }

    func listenClear() {
        if kind == .epub {
            webView?.evaluateJavaScript("window.folio && folio.listenClear()", completionHandler: nil)
        } else {
            pdfView?.highlightedSelections = nil
            // Search marks share that layer; put them back if a search is showing.
            if search.isActive { searchDidUpdate() }
        }
    }
}

// MARK: - Controls

struct ListenBar: View {
    @Bindable var listen: ListenModel
    @State private var showVoice = false

    private static let speeds: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75]

    var body: some View {
        HStack(spacing: 14) {
            if listen.isActive {
                HStack(spacing: 12) {
                    Button { listen.skip(-1) } label: { Image(systemName: "backward.fill") }.help("Back one paragraph").accessibilityLabel("Back one paragraph")
                    Button { listen.pauseOrResume() } label: {
                        Image(systemName: listen.state == .paused ? "play.fill" : "pause.fill").font(.scaled(size: 17)).frame(width: 18)
                    }
                    .help(listen.state == .paused ? "Resume" : "Pause")
                    .accessibilityLabel(listen.state == .paused ? "Resume" : "Pause")
                    Button { listen.skip(1) } label: { Image(systemName: "forward.fill") }.help("Forward one paragraph").accessibilityLabel("Forward one paragraph")
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let error = listen.error {
                    Text(error).font(.scaled(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        if listen.state == .preparing || listen.isBuffering { ProgressView().controlSize(.small) }
                        Text(listen.state == .preparing ? "Getting ready…" : "Part \(listen.index + 1) of \(listen.clips.count)")
                            .font(.scaled(size: 12, weight: .medium)).monospacedDigit()
                    }
                    Text(listen.usingOpenAI ? "OpenAI voice · Cedar" : "System voice")
                        .font(.scaled(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 110, maxWidth: 300, alignment: .leading)
            if listen.isActive {
                Menu {
                    ForEach(Self.speeds, id: \.self) { s in
                        Button { listen.speed = s } label: {
                            if s == listen.speed { Label(Self.label(s), systemImage: "checkmark") } else { Text(Self.label(s)) }
                        }
                    }
                } label: {
                    Text(Self.label(listen.speed)).font(.scaled(size: 12, weight: .medium)).monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Speed")
                .accessibilityLabel("Speed")
            }
            Button { showVoice = true } label: { Image(systemName: "waveform") }
                .buttonStyle(.plain)
                .help("Voice")
                .accessibilityLabel("Voice")
                .popover(isPresented: $showVoice, arrowEdge: .top) { VoiceSettings(listen: listen) }
            Button { listen.stop(); listen.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Stop listening")
                .accessibilityLabel("Stop listening")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }

    private static func label(_ speed: Double) -> String {
        (speed == speed.rounded() ? String(format: "%.0f", speed) : String(speed)) + "×"
    }
}

/// Where the OpenAI key for the natural voice is added or removed.
private struct VoiceSettings: View {
    let listen: ListenModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = Secrets.openAIKey != nil
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice").font(.scaled(size: 15, weight: .semibold, design: .serif))
            Text(hasKey
                 ? "Folio reads with OpenAI's Cedar voice, using the key saved in this device's Keychain."
                 : "Folio is reading with the built-in system voice. Add an OpenAI API key to use the more natural Cedar voice.")
                .font(.scaled(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("With the OpenAI voice, the text being read is sent to OpenAI and the audio is billed to your OpenAI account. Each passage is fetched only as you reach it, and kept on this device so replaying it is free.")
                .font(.scaled(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(hasKey ? "Replace the saved key" : "OpenAI API key", text: $key)
                .textFieldStyle(.roundedBorder)
            if failed {
                Text("The key couldn't be saved to the Keychain.").font(.scaled(size: 11)).foregroundStyle(.red)
            }
            HStack {
                if hasKey {
                    Button("Remove Key", role: .destructive) {
                        Secrets.setOpenAIKey(nil)
                        hasKey = false
                        listen.stop()
                    }
                }
                Spacer()
                Button("Save") {
                    failed = !Secrets.setOpenAIKey(key)
                    if !failed {
                        listen.stop()
                        dismiss()
                    }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            Text("A change takes effect the next time you start listening.").font(.scaled(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 330)
    }
}
