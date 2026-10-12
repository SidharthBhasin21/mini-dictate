import AppKit
import AVFoundation
import Speech


let vKeyCode: CGKeyCode = 9

// MARK: - Config (~/.minidictate.json, optional)

struct Config: Decodable {
    var apiKey: String?    // if set, use a hosted OpenAI-compatible transcription API
    var endpoint: String?  // default: https://api.openai.com/v1/audio/transcriptions
    var model: String?     // default: whisper-1
    var language: String?  // e.g. "en"; default: detected per dictation
}

func loadConfig() -> Config {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".minidictate.json")
    guard let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
    return config
}

// MARK: - Log (~/Library/Logs/MiniDictate.log; never contains transcript text)

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MiniDictate.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

struct DictationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Recording (16 kHz mono 16-bit PCM)

final class Recorder {
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                          channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let lock = NSLock()
    /// Called on the main queue with the loudness of each captured chunk, 0...1.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        lock.lock(); pcm.removeAll(); lock.unlock()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw DictationError("No usable microphone")
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let chunk = Data(bytes: channel[0], count: Int(out.frameLength) * 2)
        lock.lock(); pcm.append(chunk); lock.unlock()

        var sum: Float = 0
        for i in 0..<Int(out.frameLength) { let s = Float(channel[0][i]) / 32768; sum += s * s }
        let decibels = 10 * log10(max(sum / Float(out.frameLength), 1e-10))
        let level = min(max((decibels + 52) / 40, 0), 1)  // -52 dB...-12 dB mapped to 0...1
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    func stop() -> (wav: Data, seconds: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let data = pcm; lock.unlock()
        return (wavFile(pcm: data), Double(data.count) / 32000)
    }

    private func wavFile(pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

// MARK: - Transcription

final class Transcriber {
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    let whisper = WhisperEngine()

    func transcribe(wav: Data, config: Config, completion: @escaping (Result<String, Error>) -> Void) {
        let finish: (Result<String, Error>) -> Void = { result in DispatchQueue.main.async { completion(result) } }
        if let key = config.apiKey, !key.isEmpty {
            log("engine: hosted")
            hosted(wav: wav, key: key, config: config, completion: finish)
        } else if whisper.isReady {
            log("engine: whisper \(whisper.active?.title ?? "")")
            Task {
                do { finish(.success(try await whisper.transcribe(wav: wav, language: config.language))) }
                catch { finish(.failure(error)) }
            }
        } else {
            // Whisper is still downloading or failed to load; Apple's recognizer covers the gap.
            log("engine: apple")
            onDevice(wav: wav, config: config, completion: finish)
        }
    }

    private func hosted(wav: Data, key: String, config: Config, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: config.endpoint ?? "https://api.openai.com/v1/audio/transcriptions") else {
            return completion(.failure(DictationError("Bad endpoint in ~/.minidictate.json")))
        }
        let boundary = "minidictate-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", config.model ?? "whisper-1")
        field("response_format", "json")
        if let language = config.language { field("language", language) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            if let error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                let detail = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200) ?? ""
                return completion(.failure(DictationError("Transcription API returned \(status) \(detail)")))
            }
            completion(.success(text))
        }.resume()
    }

    private func onDevice(wav: Data, config: Config, completion: @escaping (Result<String, Error>) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    return completion(.failure(DictationError("Speech Recognition permission denied")))
                }
                let locale = config.language.map(Locale.init(identifier:)) ?? Locale.current
                guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
                      recognizer.isAvailable else {
                    return completion(.failure(DictationError("Speech recognizer unavailable")))
                }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("minidictate-\(UUID().uuidString).wav")
                do { try wav.write(to: file) } catch { return completion(.failure(error)) }

                let request = SFSpeechURLRecognitionRequest(url: file)
                request.shouldReportPartialResults = false
                request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
                if #available(macOS 13, *) { request.addsPunctuation = true }

                var done = false
                self.recognizer = recognizer
                self.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !done else { return }
                    if let result, result.isFinal {
                        done = true
                        completion(.success(result.bestTranscription.formattedString))
                    } else if let error {
                        done = true
                        completion(.failure(error))
                    } else {
                        return
                    }
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}

// MARK: - Insert into the focused app (clipboard + Cmd+V, then restore the clipboard)

func paste(_ text: String) {
    let pasteboard = NSPasteboard.general
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: keyDown)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        pasteboard.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
