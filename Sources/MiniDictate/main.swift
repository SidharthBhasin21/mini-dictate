import AppKit
import AVFoundation
import Speech

// Hold the hotkey to record, release to transcribe and paste into the focused app.
// Core.swift: recording, transcription, paste. UI.swift: hub window and dictation pill.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var tap: CFMachPort?
    private let model = AppModel(demo: demoPage != nil)
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var tapTimer: Timer?
    private var pillClear: DispatchWorkItem?
    private var hub: HubWindow!
    private var pill: PillPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = appIcon()
        NSApp.mainMenu = mainMenu()
        if let demoPage { return startDemo(demoPage) }
        hub = HubWindow(model: model)
        pill = PillPanel(model: model)
        hub.show()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Window", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem(title: "Quit MiniDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        set(.idle, "Starting…")

        log("launched, accessibility trusted=\(AXIsProcessTrusted())")
        AVCaptureDevice.requestAccess(for: .audio) { granted in log("microphone granted=\(granted)") }
        model.onTest = { [weak self] in self?.toggleTest() }
        transcriber.whisper.load(model.whisperModel)
        model.onModelChange = { [weak self] in self?.transcriber.whisper.load($0) }
        recorder.onLevel = { [weak self] level in
            guard let self, self.model.phase == .recording else { return }
            self.model.meter.push(level)
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        installTap()
    }

    /// Sample-data windows for screenshots: no microphone, hotkey, model download or real history.
    private func startDemo(_ page: String) {
        model.accessibility = true
        model.keyListener = true
        model.microphone = true
        model.speech = "On"
        model.engine = "Whisper \(model.whisperModel.title), on-device"
        model.status = "Hold \(model.hotkey.name) to dictate"
        model.demoPage = page == "settings" ? "Settings" : "Home"
        hub = HubWindow(model: model)
        hub.show(activate: false)
        pill = PillPanel(model: model, backdrop: NSColor(white: 0.55, alpha: 1))
        guard page == "recording" else { return }
        model.phase = .recording
        var tick = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            tick += 1
            let level = 0.5 + 0.32 * sin(tick * 0.9) + 0.18 * sin(tick * 2.3)
            self?.model.meter.push(Float(max(0.08, min(1, level))))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        hub.show()
        return true
    }

    @objc func showWindow() { hub.show() }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(), editItem = NSMenuItem(), windowItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MiniDictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Show MiniDictate", action: #selector(showWindow), keyEquivalent: "0").target = self
        appItem.submenu = appMenu; editItem.submenu = editMenu; windowItem.submenu = windowMenu
        [appItem, editItem, windowItem].forEach(main.addItem)
        return main
    }

    private func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let tile = rect.insetBy(dx: 20, dy: 20)
            NSColor(red: 0.11, green: 0.11, blue: 0.10, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 50, yRadius: 50).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 110, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                glyph.draw(in: NSRect(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            }
            return true
        }
    }

    // MARK: Hotkey listener

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                       eventsOfInterest: mask, callback: tapCallback, userInfo: nil) {
            self.tap = tap
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            tapTimer?.invalidate()
            log("key listener installed")
        } else if tapTimer == nil {
            log("key listener failed, accessibility trusted=\(AXIsProcessTrusted())")
            tapTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.installTap() }
        }
        refresh()
    }

    private var idleMessage: String {
        if tap != nil { return "Hold \(model.hotkey.name) to dictate" }
        return AXIsProcessTrusted() ? "Accessibility is on but the key listener failed. Quit and reopen MiniDictate."
                                    : "Grant Accessibility in System Settings, then wait…"
    }

    /// Syncs permission state into the model. Assigns only on change so the window isn't redrawn every tick,
    /// and never touches `phase`, so it cannot interrupt a recording.
    private func refresh() {
        func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
            if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
        }
        update(\.accessibility, AXIsProcessTrusted())
        update(\.keyListener, tap != nil)
        update(\.microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: update(\.speech, "On")
        case .notDetermined: update(\.speech, "Asked on first dictation")
        default: update(\.speech, "Off")
        }
        update(\.activeWhisper, transcriber.whisper.active)
        update(\.loadingWhisper, transcriber.whisper.loading)
        let config = loadConfig()
        if !(config.apiKey ?? "").isEmpty {
            update(\.engine, "Hosted (\(config.model ?? "whisper-1"))")
        } else {
            let whisper = transcriber.whisper
            let current = whisper.active.map { "Whisper \($0.title), on-device" } ?? "Apple's recognizer"
            if let loading = whisper.loading {
                let percent = Int(whisper.progress * 100)
                update(\.engine, "Getting \(loading.title): \(percent < 100 ? "\(percent)%" : "loading…") (using \(current) meanwhile)")
            } else if whisper.failure != nil {
                update(\.engine, "Couldn't load \(model.whisperModel.title); using \(current)")
            } else {
                update(\.engine, current)
            }
        }
        if model.phase == .idle, model.pillMessage == nil {
            update(\.status, idleMessage)
            statusLine.title = idleMessage
        }
        pill.reposition()
    }

    // MARK: Dictation

    /// Runs the same record → transcribe path as the hotkey, from the window's button.
    private func toggleTest() {
        log("test button, phase=\(model.phase)")
        hotkey(down: model.phase == .idle)
    }

    func hotkey(down: Bool) {
        log("hotkey down=\(down) phase=\(model.phase)")
        if down, model.phase == .idle {
            do {
                model.meter.reset()
                try recorder.start()
                set(.recording, "Recording…")
            } catch {
                log("mic error: \(error)")
                set(.idle, "Mic error: \(error.localizedDescription)", pill: "Microphone error")
            }
        } else if !down, model.phase == .recording {
            let (wav, seconds) = recorder.stop()
            log(String(format: "recorded %.1fs", seconds))
            guard seconds >= 0.3 else { return set(.idle, idleMessage) }
            set(.transcribing, "Transcribing…")
            transcriber.transcribe(wav: wav, config: loadConfig()) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    log("transcribed \(trimmed.count) characters, pasting=\(!trimmed.isEmpty)")
                    guard !trimmed.isEmpty else { return self.set(.idle, "Heard nothing", pill: "Heard nothing") }
                    // One or two words have nothing to clean and aren't worth the delay.
                    guard Cleanup.isOn, trimmed.split(whereSeparator: \.isWhitespace).count >= 3 else {
                        return self.finish(trimmed, seconds: seconds)
                    }
                    self.set(.transcribing, "Polishing…")
                    Task { @MainActor in
                        let outcome = await Cleanup.run(trimmed)
                        self.model.cleanupNote = outcome.note
                        self.finish(outcome.text, seconds: seconds)
                    }
                case .failure(let error):
                    log("transcription error: \(error)")
                    self.set(.idle, "Error: \(error.localizedDescription)", pill: "Couldn't transcribe")
                }
            }
        }
    }

    private func finish(_ text: String, seconds: Double) {
        paste(text)
        model.add(text: text, seconds: seconds)
        set(.idle, idleMessage)
    }

    /// `pill` is a short message shown in the pill for a few seconds (errors only).
    private func set(_ phase: AppModel.Phase, _ status: String, pill message: String? = nil) {
        pill.reposition()
        model.phase = phase
        model.status = status
        model.pillMessage = message
        statusLine.title = status
        let symbol = [AppModel.Phase.idle: "mic", .recording: "mic.fill", .transcribing: "ellipsis.circle"][phase]!
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MiniDictate")
        statusItem.button?.contentTintColor = phase == .recording ? .systemRed : nil

        pillClear?.cancel()
        if message != nil {
            let work = DispatchWorkItem { [weak self] in self?.model.pillMessage = nil }
            pillClear = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }
}

/// `MiniDictate --demo home|settings|recording` opens the app with sample data, for screenshots.
let demoPage: String? = CommandLine.arguments.firstIndex(of: "--demo").map { index in
    CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "home"
}

let delegate = AppDelegate()

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = delegate.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    } else if type == .flagsChanged {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        log("modifier key code=\(code)")
        guard code == activeHotkey.keyCode else { return Unmanaged.passUnretained(event) }
        delegate.hotkey(down: event.flags.contains(activeHotkey.flag))
    }
    return Unmanaged.passUnretained(event)
}

// Developer check: `MiniDictate --cleanup-probe anthropic|openAI` sends one request with a placeholder key,
// to confirm the request reaches the provider and that a failure falls back to the raw text.
if let flag = CommandLine.arguments.firstIndex(of: "--cleanup-probe"), CommandLine.arguments.count > flag + 1,
   let provider = CleanupProvider(rawValue: CommandLine.arguments[flag + 1]) {
    Task {
        let outcome = await Cleanup.run("um so this is uh a test sentence", provider: provider, key: "placeholder-key",
                                        model: provider.defaultModel, baseURL: Preferences.defaultOpenAIBaseURL)
        print("text: \(outcome.text)\nnote: \(outcome.note)")
        exit(0)
    }
    RunLoop.main.run()
}

// Developer check: `MiniDictate --transcribe file.wav` runs Whisper on a 16 kHz mono 16-bit WAV and prints the text.
if let flag = CommandLine.arguments.firstIndex(of: "--transcribe"), CommandLine.arguments.count > flag + 1 {
    // An optional third argument picks the model by name: tiny, base, small, largeTurbo or hinglish.
    let name = CommandLine.arguments.count > flag + 2 ? CommandLine.arguments[flag + 2] : "base"
    let chosen = WhisperModel.allCases.first { "\($0)" == name } ?? .base
    let engine = WhisperEngine()
    engine.load(chosen)
    while engine.loading != nil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    guard engine.active == chosen, let wav = FileManager.default.contents(atPath: CommandLine.arguments[flag + 1]) else {
        print("failed: \(engine.failure ?? "unknown")")
        exit(1)
    }
    print("model: \(chosen.title)")
    Task {
        let started = Date()
        do { print(try await engine.transcribe(wav: wav, language: nil)) } catch { print("failed: \(error)") }
        print(String(format: "(%.2fs)", Date().timeIntervalSince(started)))
        exit(0)
    }
    RunLoop.main.run()
}

let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
