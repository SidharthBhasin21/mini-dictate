import AppKit
import SwiftUI

// MARK: - Model

struct Entry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let text: String
    let seconds: Double
}

/// Rolling loudness history for the waveform. Kept separate from AppModel so that
/// level updates redraw only the pill, not the whole window.
final class LevelMeter: ObservableObject {
    static let barCount = 13
    @Published var levels = [CGFloat](repeating: 0, count: barCount)

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(level))
    }

    func reset() { levels = [CGFloat](repeating: 0, count: Self.barCount) }
}

final class AppModel: ObservableObject {
    enum Phase { case idle, recording, transcribing }

    @Published var phase = Phase.idle
    @Published var status = ""
    @Published var pillMessage: String?
    @Published var history: [Entry] = []
    @Published var accessibility = false
    @Published var keyListener = false
    @Published var microphone = false
    @Published var speech = "Asked on first dictation"
    @Published var engine = ""
    let meter = LevelMeter()
    var onTest: () -> Void = {}

    // Dictation history is stored locally as plain text.
    private let historyURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniDictate")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }()

    /// Demo mode shows sample data and never reads or writes the real history (used for screenshots).
    let demo: Bool
    var demoPage = "Home"

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            let samples: [(hoursAgo: Double, seconds: Double, text: String)] = [
                (0.2, 7, "Can we move the design review to Thursday afternoon? I should have the new mockups ready by then."),
                (1.5, 5, "Thanks for the quick turnaround, this looks great."),
                (3.0, 9, "Add a note to the release checklist: update the changelog and tag the build before publishing."),
                (26, 6, "Remind me to book the train tickets for next weekend."),
                (28, 8, "The second paragraph is too long. Split it in two and lead with the customer quote."),
            ]
            history = samples.map { Entry(date: Date().addingTimeInterval(-$0.hoursAgo * 3600), text: $0.text, seconds: $0.seconds) }
            return
        }
        if let data = try? Data(contentsOf: historyURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            history = saved
        }
    }

    func add(text: String, seconds: Double) {
        history.insert(Entry(date: Date(), text: text, seconds: seconds), at: 0)
        history = Array(history.prefix(200))
        save()
    }

    func clearHistory() {
        history = []
        save()
    }

    private func save() {
        guard !demo else { return }
        try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    }

    var totalWords: Int {
        history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    var wordsPerMinute: Int {
        let minutes = history.reduce(0) { $0 + $1.seconds } / 60
        return minutes > 0 ? Int(Double(totalWords) / minutes) : 0
    }

    /// Consecutive days with at least one dictation, ending today.
    var streak: Int {
        let calendar = Calendar.current
        let days = Set(history.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: Date()), count = 0
        while days.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }
}

enum Theme {
    static let cream = Color(red: 0.965, green: 0.953, blue: 0.925)
    static let banner = Color(red: 1.0, green: 0.957, blue: 0.82)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let line = Color.black.opacity(0.09)
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

// MARK: - Hub window

struct HubView: View {
    @ObservedObject var model: AppModel
    @State private var page: String

    init(model: AppModel) {
        self.model = model
        _page = State(initialValue: model.demoPage)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                if page == "Home" { HomePage(model: model) } else { SettingsPage(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            .padding([.top, .trailing, .bottom], 10)
        }
        .background(Theme.cream)
        .foregroundColor(Theme.ink)
        .frame(minWidth: 860, minHeight: 580)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 16, weight: .bold))
                Text("MiniDictate").font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 46).padding(.horizontal, 10).padding(.bottom, 16)
            navItem("Home", "square.grid.2x2")
            navItem("Settings", "gearshape")
            Spacer()
            Text(model.status)
                .font(.system(size: 11))
                .foregroundColor(Theme.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10).padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .frame(width: 214, alignment: .leading)
    }

    private func navItem(_ title: String, _ symbol: String) -> some View {
        Button { page = title } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(page == title ? Color.black.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DarkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.ink))
        }
        .buttonStyle(.plain)
    }
}

struct HomePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Welcome back, \(firstName)")
                        .font(.system(size: 26, weight: .medium, design: .serif))
                    Spacer()
                    HStack(spacing: 16) {
                        stat("🔥", "\(model.streak) day\(model.streak == 1 ? "" : "s")")
                        stat("🚀", "\(model.totalWords.formatted()) words")
                        stat("🏆", "\(model.wordsPerMinute) WPM")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
                banner
                historyList
            }
            .padding(32)
        }
    }

    private var firstName: String {
        if model.demo { return "Sam" }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }

    private func stat(_ emoji: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(emoji).font(.system(size: 13))
            Text(value).font(.system(size: 13, weight: .medium))
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.keyListener ? "Hold right ⌥ to dictate anywhere" : "Finish setup to dictate anywhere")
                .font(.system(size: 25, weight: .medium, design: .serif))
            Text(model.keyListener
                 ? "Click into any text field, hold right Option, speak, and release. Your words are pasted at the cursor."
                 : "MiniDictate needs Accessibility permission to detect the right Option key and paste text for you.")
                .font(.system(size: 14))
                .foregroundColor(Theme.ink.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if !model.keyListener {
                    DarkButton(title: "Open Accessibility Settings", action: openAccessibilitySettings)
                }
                DarkButton(title: model.phase == .recording ? "Stop test recording" : "Start test recording") {
                    model.onTest()
                }
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.banner))
    }

    private var groups: [(day: Date, entries: [Entry])] {
        Dictionary(grouping: model.history) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }

    @ViewBuilder private var historyList: some View {
        if model.history.isEmpty {
            Text("Your dictations will appear here.")
                .font(.system(size: 14))
                .foregroundColor(Theme.ink.opacity(0.5))
        } else {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(title(for: group.day))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.ink.opacity(0.5))
                    VStack(spacing: 0) {
                        ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                            row(entry)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                }
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13))
                .foregroundColor(Theme.ink.opacity(0.5))
                .frame(width: 76, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.ink.opacity(0.45))
            .help("Copy")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct SettingsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings").font(.system(size: 26, weight: .medium, design: .serif))

                section("PERMISSIONS") {
                    check("Accessibility", model.accessibility, "Detect the hotkey and paste text")
                    divider
                    check("Key listener", model.keyListener,
                          model.accessibility && !model.keyListener ? "Quit and reopen MiniDictate" : "Listening for right Option")
                    divider
                    check("Microphone", model.microphone, "Record while the key is held")
                    divider
                    line("Speech Recognition", model.speech)
                }
                if !model.keyListener {
                    DarkButton(title: "Open Accessibility Settings", action: openAccessibilitySettings)
                }

                section("DICTATION") {
                    line("Hotkey", "Hold right Option (⌥)")
                    divider
                    line("Transcription", model.engine)
                    divider
                    line("Config file", "~/.minidictate.json")
                }

                section("DATA") {
                    line("History", "\(model.history.count) dictations, stored on this Mac")
                    divider
                    line("Log", "~/Library/Logs/MiniDictate.log")
                }
                DarkButton(title: "Clear history") { model.clearHistory() }
            }
            .padding(32)
        }
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.5))
            VStack(spacing: 0, content: content)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func check(_ label: String, _ ok: Bool, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 9, height: 9)
            Text(label).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(ok ? detail : "Off").font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

final class HubWindow {
    private let window: NSWindow

    init(model: AppModel) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "MiniDictate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: HubView(model: model))
    }

    func show(activate: Bool = true) {
        if !window.isVisible, let screen = screenUnderMouse()?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2,
                                          y: screen.midY - window.frame.height / 2))
        }
        guard activate else { return window.orderFront(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The display the pointer is on, so UI appears where the user is looking.
func screenUnderMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
}

// MARK: - Dictation pill (bottom of the screen)

struct PillView: View {
    @ObservedObject var model: AppModel

    private var resting: Bool { model.phase == .idle && model.pillMessage == nil }

    var body: some View {
        content
            .frame(minWidth: resting ? 42 : 96)
            .frame(height: resting ? 9 : 32)
            .background(Capsule().fill(Color.black.opacity(resting ? 0.55 : 0.94)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: model.phase)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: model.pillMessage)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if model.phase == .recording {
            LiveBars(meter: model.meter)
        } else if model.phase == .transcribing {
            ThinkingBars()
        } else if let message = model.pillMessage {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 16)
        } else {
            Color.clear.frame(width: 42)
        }
    }
}

/// Waveform driven by the live microphone level.
struct LiveBars: View {
    @ObservedObject var meter: LevelMeter

    var body: some View {
        HStack(spacing: 3) {
            ForEach(meter.levels.indices, id: \.self) { index in
                Capsule().fill(Color.white).frame(width: 3, height: 3 + meter.levels[index] * 20)
            }
        }
        .animation(.linear(duration: 0.07), value: meter.levels)
        .padding(.horizontal, 18)
    }
}

/// Travelling wave shown while the transcript is being produced.
struct ThinkingBars: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<LevelMeter.barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 3, height: 4 + 6 * (1 + sin(time * 7 - Double(index) * 0.6)))
                }
            }
            .padding(.horizontal, 18)
        }
    }
}

final class PillPanel {
    private let panel: NSPanel
    private let size = NSSize(width: 460, height: 64)

    /// `backdrop` fills the normally transparent panel, so the pill is visible in a screenshot.
    init(model: AppModel, backdrop: NSColor? = nil) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = backdrop ?? .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        reposition()
        panel.orderFrontRegardless()
    }

    /// Keeps the pill at the bottom centre of the display the pointer is on.
    func reposition() {
        guard let screen = screenUnderMouse()?.visibleFrame else { return }
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.minY)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}
