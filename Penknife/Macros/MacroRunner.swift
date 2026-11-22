import AppKit
import Carbon.HIToolbox
import Observation

/// Runs one macro at a time in the app in front, as if typed (R-35). Nothing runs, and nothing
/// is watched, while no macro runs. It stops at once if another app comes to the front, on a
/// click, or on Esc; the user's clipboard is put back when it ends.
@Observable
final class MacroRunner {
    static let shared = MacroRunner()

    enum State: Equatable {
        case idle
        case running(String)
        /// "Wait for me": paused until the shortcut is pressed again.
        case waiting(String)
    }

    private(set) var state = State.idle
    var isBusy: Bool { state != .idle }

    /// Why a run ended early, for the alert.
    enum StopReason { case appChanged, click, escape, permission, rowsRanOut, failed }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resume: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var appObserver: NSObjectProtocol?
    @ObservationIgnored private var stopReason: StopReason?
    @ObservationIgnored private var target: NSRunningApplication?
    @ObservationIgnored private var snapshot: [[NSPasteboard.PasteboardType: Data]]?
    @ObservationIgnored private var lastPaste = Date.distantPast

    /// What a run needs, gathered before it starts (answers asked, data row chosen).
    struct Plan {
        var macro: Macro
        var answers: [String: String]
        var columns: [String: String]
        var row: Int?
        /// Text of each pinned step, by step id (from the pin, or asked as plan B).
        var pinned: [UUID: String]
    }

    /// Called when a run ends (finished or stopped) with what to save back into the macro.
    var onFinish: ((Plan, _ completed: Bool) -> Void)?

    // MARK: Start, resume, stop

    func start(_ plan: Plan) {
        guard !isBusy else { return }
        guard Permissions.shared.ensureAccessibility() else {
            HUD.shared.showPermissionNeeded(.macros)
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return }
        target = front
        stopReason = nil
        state = .running(plan.macro.name)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForModifiersUp()
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            self.snapshot = Self.take(.general)
            self.watch()
            var context = MacroText.Context(counter: plan.macro.counter + 1, clipboard: clipboard,
                                            answers: plan.answers, columns: plan.columns)
            context.date = .now
            let completed = await self.perform(plan, context: context)
            await self.finish(plan, completed: completed)
        }
    }

    /// The shortcut was pressed while waiting: go on. Returns false when nothing was waiting.
    @discardableResult
    func continueIfWaiting() -> Bool {
        guard case .waiting = state, let resume else { return false }
        self.resume = nil
        resume.resume(returning: true)
        return true
    }

    func stop(_ reason: StopReason) {
        guard isBusy, stopReason == nil else { return }
        stopReason = reason
        task?.cancel()
        if let resume {
            self.resume = nil
            resume.resume(returning: false)
        }
    }

    private var stopped: Bool { stopReason != nil || Task.isCancelled }

    // MARK: Steps

    private func perform(_ plan: Plan, context: MacroText.Context) async -> Bool {
        let macro = plan.macro
        for step in macro.steps {
            guard !stopped else { return false }
            switch step.kind {
            case .text:
                await input(MacroText.expand(step.text, context), typing: macro.typesText)
            case .pinned:
                await input(plan.pinned[step.id] ?? "", typing: macro.typesText)
            case .key:
                guard let key = step.key else { continue }
                EventPoster.key(CGKeyCode(key.code), flags: key.cgFlags)
            case .wait:
                await sleep(ms: max(0, min(step.milliseconds, 60_000)))
            case .waitForMe:
                guard await waitForUser(macro.name) else { return false }
            case .file:
                guard let url = step.file else { continue }
                if step.fileMode == .paste {
                    await pasteFile(url)
                } else {
                    // Open dialogs: ⌘⇧G opens "Go to folder", the path goes in, Return opens it.
                    EventPoster.key(CGKeyCode(kVK_ANSI_G), flags: [.maskCommand, .maskShift])
                    await sleep(ms: 400)
                    await input(url.path, typing: macro.typesText)
                    await sleep(ms: 250)
                    EventPoster.key(CGKeyCode(kVK_Return))
                }
            }
            // A breath between steps, so web pages keep up (focus moves, fields appear).
            await sleep(ms: 40)
        }
        return !stopped
    }

    /// Pastes (default) or types the text. Paste goes through the clipboard, marked as temporary
    /// so Clipboard History skips it; the user's clipboard comes back at the end.
    private func input(_ text: String, typing: Bool) async {
        guard !text.isEmpty, !stopped else { return }
        if typing {
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if index > 0 { EventPoster.key(CGKeyCode(kVK_Return)) }
                EventPoster.type(line)
                await sleep(ms: 10)
            }
            return
        }
        await waitForLastPaste()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pressPaste()
    }

    private func pasteFile(_ url: URL) async {
        await waitForLastPaste()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pressPaste()
    }

    private func pressPaste() {
        EventPoster.key(EventPoster.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        lastPaste = .now
    }

    /// The app reads the clipboard when it handles ⌘V, a moment after it is sent: the next
    /// change waits, or it would paste the wrong text.
    private func waitForLastPaste() async {
        let left = 0.15 - Date.now.timeIntervalSince(lastPaste)
        if left > 0 { await sleep(ms: Int(left * 1000)) }
    }

    private func waitForUser(_ name: String) async -> Bool {
        state = .waiting(name)
        let goOn = await withCheckedContinuation { continuation in
            if stopped { continuation.resume(returning: false) } else { resume = continuation }
        }
        guard goOn, !stopped else { return false }
        // Going on only where it started: nothing is typed into another app.
        guard NSWorkspace.shared.frontmostApplication == target else {
            stop(.appChanged)
            return false
        }
        state = .running(name)
        await waitForModifiersUp()
        return true
    }

    private func sleep(ms: Int) async {
        guard ms > 0 else { return }
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// The shortcut that started it may still be held: ⌥ or ⌘ held down would change what is typed.
    private func waitForModifiersUp() async {
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            await sleep(ms: 25)
        }
    }

    // MARK: Watching while it runs

    private func watch() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, case .running = self.state, let pid, pid != self.target?.processIdentifier else { return }
                self.stop(.appChanged)
            }
        }
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            // While it waits for the user, clicking (a dropdown, a captcha) is the point.
            guard let self, case .running = self.state else { return }
            self.stop(.click)
        }) { monitors.append(clicks) }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Escape), !EventPoster.isOurs(event) else { return }
            self.stop(.escape)
        }) { monitors.append(keys) }
    }

    private func unwatch() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
    }

    private func finish(_ plan: Plan, completed: Bool) async {
        unwatch()
        // The last paste must be read before the user's clipboard comes back.
        let left = 0.3 - Date.now.timeIntervalSince(lastPaste)
        if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
        if let snapshot, lastPaste != .distantPast { Self.restore(snapshot, to: .general) }
        snapshot = nil
        lastPaste = .distantPast
        let reason = stopReason
        state = .idle
        task = nil
        target = nil
        onFinish?(plan, completed)
        if !completed, let reason { Self.announceStop(reason, name: plan.macro.name) }
    }

    static func announceStop(_ reason: StopReason, name: String) {
        let detail: String? = switch reason {
        case .appChanged: String(localized: "Another app came to the front")
        case .click: String(localized: "You clicked")
        case .escape, .failed, .permission: nil
        case .rowsRanOut: String(localized: "No rows left. Turn on “Repeat rows” or start again in the editor.")
        }
        HUD.shared.show(reason == .rowsRanOut ? String(localized: "\(name) didn't run") : String(localized: "Macro stopped"),
                        detail: detail, symbol: reason == .rowsRanOut ? "tablecells" : "stop.fill",
                        kind: .off, category: .macros)
    }

    // MARK: The user's clipboard

    static func take(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { data[type] = item.data(forType: type) }
            return data
        }
    }

    static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.compactMap { entries -> NSPasteboardItem? in
            guard !entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
