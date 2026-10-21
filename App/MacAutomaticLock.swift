import Foundation

/// Monotonic time prevents wall-clock adjustments from extending an unlocked session.
struct InactivityDeadline {
    static let interval: TimeInterval = 60
    private(set) var deadline: TimeInterval?

    mutating func setUnlocked(_ unlocked: Bool, now: TimeInterval) {
        deadline = unlocked ? now + Self.interval : nil
    }

    mutating func recordActivity(now: TimeInterval) {
        guard let deadline, now < deadline else { return }
        self.deadline = now + Self.interval
    }

    func hasExpired(now: TimeInterval) -> Bool {
        deadline.map { now >= $0 } ?? false
    }
}

#if os(macOS)
import AppKit

/// Only observes this app's input; no global keyboard monitoring or permissions.
@MainActor
final class MacAutomaticLock {
    enum Reason { case inactivity, inactive, sleep }
    private var deadline = InactivityDeadline()
    private var monitor: Any?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lock: ((Reason) -> Void)?

    func start(unlocked: Bool, lock: @escaping (Reason) -> Void) {
        stop()
        self.lock = lock
        setUnlocked(unlocked)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel
        ]) { [weak self] event in
            let expired = MainActor.assumeIsolated {
                guard let self else { return false }
                // A late timer must not let the first returning keystroke revive the session.
                if self.expireIfNeeded() { return true }
                self.deadline.recordActivity(now: ProcessInfo.processInfo.systemUptime)
                return false
            }
            return expired ? nil : event
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.expireIfNeeded() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        observe(.default, NSApplication.didResignActiveNotification, reason: .inactive)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, reason: .sleep)
        observe(workspace, NSWorkspace.screensDidSleepNotification, reason: .sleep)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, reason: .sleep)
    }

    func setUnlocked(_ unlocked: Bool) {
        deadline.setUnlocked(unlocked, now: ProcessInfo.processInfo.systemUptime)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        lock = nil
        setUnlocked(false)
    }

    @discardableResult
    private func expireIfNeeded() -> Bool {
        guard deadline.hasExpired(now: ProcessInfo.processInfo.systemUptime) else { return false }
        requestLock(.inactivity)
        return true
    }

    private func requestLock(_ reason: Reason) {
        guard deadline.deadline != nil else { return }
        setUnlocked(false)
        lock?(reason)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: Reason) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestLock(reason) }
        }
        observers.append((center, token))
    }
}
#endif
