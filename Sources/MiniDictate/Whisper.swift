import Foundation
import WhisperKit

/// The Whisper models offered in Settings. Raw values are folder names in WhisperKit's model repository.
enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small_216MB"
    case largeTurbo = "openai_whisper-large-v3-v20240930_626MB"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largeTurbo: return "Large v3 Turbo"
        }
    }

    var size: String {
        switch self {
        case .tiny: return "77 MB"
        case .base: return "145 MB"
        case .small: return "217 MB"
        case .largeTurbo: return "627 MB"
        }
    }

    var summary: String {
        switch self {
        case .tiny: return "fastest, most mistakes"
        case .base: return "fast, good for clear speech"
        case .small: return "more accurate, a little slower"
        case .largeTurbo: return "most accurate, slowest"
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
        modelsDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
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
        let folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: directory) {
            progress($0.fractionCompleted)
        }
        let kit = try await WhisperKit(WhisperKitConfig(model: model.rawValue, downloadBase: directory,
                                                        modelFolder: folder.path, verbose: false,
                                                        logLevel: .error, download: false))
        // Warm-up pass so the first real dictation isn't slowed by one-time model setup.
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 16000))
        return kit
    }

    /// `wav` is 16 kHz mono 16-bit PCM with a 44-byte header, as produced by Recorder.
    func transcribe(wav: Data, language: String?) async throws -> String {
        guard let kit else { throw DictationError("Whisper model is not loaded") }
        let samples: [Float] = Data(wav.dropFirst(44)).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
        }
        let code = language.map { String($0.prefix(2)).lowercased() }
        let options = DecodingOptions(language: code, detectLanguage: code == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper labels silence with markers such as "[BLANK_AUDIO]" or "(silence)".
        let isMarker = (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
        return isMarker ? "" : text
    }
}
