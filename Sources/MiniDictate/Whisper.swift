import CryptoKit
import Foundation
import WhisperKit

/// The Whisper models offered in Settings. Raw values are folder names in WhisperKit's model repository.
enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small_216MB"
    case largeTurbo = "openai_whisper-large-v3-v20240930_626MB"
    /// Oriserve's Whisper-Hindi2Hinglish-Swift (a fine-tune of Whisper base, Apache 2.0), converted to Core ML.
    /// It writes mixed Hindi-English speech in Roman script.
    case hinglish = "Oriserve_Whisper-Hindi2Hinglish-Swift"

    var id: String { rawValue }

    /// Where a model that WhisperKit's own repository doesn't carry is downloaded from, as a zip of its folder.
    var hostedZip: (url: URL, sha256: String)? {
        guard self == .hinglish else { return nil }
        return (URL(string: "https://github.com/SidharthBhasin21/mini-dictate/releases/download/models-v1/Whisper-Hindi2Hinglish-Swift-coreml.zip")!, "b8b2749d5730fb524ec4cfaca52110b5a43916cf1b6fc026eeeb5eef0a6e83e9")
    }

    /// The language to decode as, when the model must not detect it. The Hinglish model is trained to be run as English.
    var fixedLanguage: String? { self == .hinglish ? "en" : nil }

    var title: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largeTurbo: return "Large v3 Turbo"
        case .hinglish: return "Hinglish"
        }
    }

    var size: String {
        switch self {
        case .tiny: return "77 MB"
        case .base: return "145 MB"
        case .small: return "217 MB"
        case .largeTurbo: return "627 MB"
        case .hinglish: return "140 MB"
        }
    }

    var summary: String {
        switch self {
        case .tiny: return "fastest, most mistakes"
        case .base: return "fast, good for clear speech"
        case .small: return "more accurate, a little slower"
        case .largeTurbo: return "most accurate, slowest"
        case .hinglish: return "Hindi + English, Roman script"
        }
    }
}

/// On-device Whisper via WhisperKit. Models are downloaded on first use into
/// ~/Library/Application Support/MiniDictate/models. While a newly chosen model downloads,
/// the previously loaded one keeps answering dictations.
final class WhisperEngine {
    /// The model currently answering dictations.
    private(set) var active: WhisperModel?
    /// The model being downloaded or loaded, if any, and how far the download is (0...1).
    private(set) var loading: WhisperModel?
    private(set) var progress = 0.0
    private(set) var failure: String?
    private var kit: WhisperKit?
    private var generation = 0

    var isReady: Bool { kit != nil }

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniDictate/models")
    }

    private static func folder(for model: WhisperModel) -> URL {
        let parent = model.hostedZip == nil ? "models/argmaxinc/whisperkit-coreml" : "custom"
        return modelsDirectory.appendingPathComponent("\(parent)/\(model.rawValue)")
    }

    /// Models that have files on disk, with the space each one takes.
    static func downloaded() -> [(model: WhisperModel, bytes: Int64)] {
        WhisperModel.allCases.compactMap { model in
            guard let files = FileManager.default.enumerator(at: folder(for: model), includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
            var bytes: Int64 = 0
            for case let file as URL in files {
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return bytes > 0 ? (model, bytes) : nil
        }
    }

    /// Deletes a model's files. The caller must not pass the model in use.
    static func remove(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: folder(for: model))
        if Preferences.lastLoadedWhisperModel == model { Preferences.lastLoadedWhisperModel = nil }
        log("whisper: removed \(model.title) from disk")
    }

    func load(_ model: WhisperModel) {
        generation += 1
        let generation = generation
        failure = nil
        // Choosing the model that is already loaded just cancels any switch in progress.
        guard model != active else { return loading = nil }
        loading = model
        progress = 0
        Task {
            do {
                let directory = Self.modelsDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // At launch nothing is loaded yet. If the chosen model still has to download, bring up the last
                // model that worked first, so dictation doesn't wait on a large download.
                if let interim = Preferences.lastLoadedWhisperModel, interim != model,
                   let kit = try? await Self.make(interim, in: directory, progress: { _ in }) {
                    await MainActor.run {
                        guard self.generation == generation, self.kit == nil else { return }
                        self.kit = kit
                        self.active = interim
                        log("whisper: using \(interim.title) until \(model.title) is ready")
                    }
                }
                log("whisper: loading model \(model.title)")
                let kit = try await Self.make(model, in: directory) { fraction in
                    DispatchQueue.main.async {
                        if self.generation == generation { self.progress = fraction }
                    }
                }
                await MainActor.run {
                    guard self.generation == generation else { return }
                    self.kit = kit
                    self.active = model
                    self.loading = nil
                    Preferences.lastLoadedWhisperModel = model
                    log("whisper: model ready (\(model.title))")
                }
            } catch {
                await MainActor.run {
                    guard self.generation == generation else { return }
                    self.loading = nil
                    self.failure = error.localizedDescription
                    log("whisper: load failed (\(model.title)): \(error)")
                }
            }
        }
    }

    /// Downloads the model if needed, loads it, and runs a warm-up pass.
    private static func make(_ model: WhisperModel, in directory: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKit {
        let folder: URL
        if let hosted = model.hostedZip {
            folder = Self.folder(for: model)
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path) {
                try await fetch(hosted.url, sha256: hosted.sha256, into: folder.deletingLastPathComponent(), progress: progress)
            }
        } else {
            folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: directory) {
                progress($0.fractionCompleted)
            }
        }
        let kit = try await WhisperKit(WhisperKitConfig(model: model.rawValue, downloadBase: directory,
                                                        modelFolder: folder.path, verbose: false,
                                                        logLevel: .error, download: false))
        // Warm-up pass so the first real dictation isn't slowed by one-time model setup.
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 16000))
        return kit
    }

    /// Downloads a zip, checks it against the expected SHA-256, and unpacks it into `directory`.
    private static func fetch(_ url: URL, sha256: String, into directory: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let zip: URL = try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                observation?.invalidate()
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let file, error == nil, status == 200 else {
                    return continuation.resume(throwing: error ?? DictationError("Model download failed (HTTP \(status))"))
                }
                // The temporary file is deleted when this handler returns, so move it first.
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("minidictate-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: file, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
            task.resume()
        }
        defer { try? FileManager.default.removeItem(at: zip) }

        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw DictationError("Downloaded model failed its integrity check")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, directory.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw DictationError("Could not unpack the model") }
    }

    /// `wav` is 16 kHz mono 16-bit PCM with a 44-byte header, as produced by Recorder.
    func transcribe(wav: Data, language: String?) async throws -> String {
        guard let kit else { throw DictationError("Whisper model is not loaded") }
        let samples: [Float] = Data(wav.dropFirst(44)).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
        }
        let code = active?.fixedLanguage ?? language.map { String($0.prefix(2)).lowercased() }
        let options = DecodingOptions(language: code, detectLanguage: code == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper labels silence with markers such as "[BLANK_AUDIO]" or "(silence)".
        let isMarker = (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
        return isMarker ? "" : text
    }
}
