import Foundation
import WhisperKit

/// On-device Whisper (multilingual "base") via WhisperKit. The model is downloaded once, on first launch,
/// into ~/Library/Application Support/MiniDictate/models.
final class WhisperEngine {
    enum State: Equatable { case loading, ready, failed(String) }

    static let modelName = "base"
    private(set) var state = State.loading
    private var kit: WhisperKit?

    func load() {
        Task {
            do {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MiniDictate/models")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                log("whisper: loading model \(Self.modelName)")
                let kit = try await WhisperKit(WhisperKitConfig(model: Self.modelName, downloadBase: directory,
                                                                verbose: false, logLevel: .error))
                // Warm-up pass so the first real dictation isn't slowed by one-time model setup.
                _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 16000))
                await MainActor.run {
                    self.kit = kit
                    self.state = .ready
                    log("whisper: model ready")
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                    log("whisper: load failed: \(error)")
                }
            }
        }
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
