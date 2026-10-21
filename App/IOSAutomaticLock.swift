#if os(iOS)
import SwiftUI
import UIKit

/// Observe input in the ledger's window, including sheets, without consuming gestures.
struct IOSAutomaticLock: UIViewRepresentable {
    let unlocked: Bool
    let lock: () -> Void

    func makeUIView(context: Context) -> ActivityView { ActivityView() }

    func updateUIView(_ view: ActivityView, context: Context) {
        view.lock = lock
        view.setUnlocked(unlocked)
    }

    static func dismantleUIView(_ view: ActivityView, coordinator: ()) {
        view.stop()
    }

    final class ActivityView: UIView, UIGestureRecognizerDelegate {
        var lock: (() -> Void)?
        private var deadline = InactivityDeadline()
        private var unlocked = false
        private var timer: Timer?
        private var observers: [NSObjectProtocol] = []
        private var activityGesture: ActivityGesture?

        func setUnlocked(_ value: Bool) {
            guard value != unlocked else { return }
            unlocked = value
            deadline.setUnlocked(value, now: ProcessInfo.processInfo.systemUptime)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard let window else { return }
            let gesture = ActivityGesture()
            gesture.activity = { [weak self] in self?.recordActivity() }
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            window.addGestureRecognizer(gesture)
            activityGesture = gesture
            for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] notification in
                    let input = notification.object as? UIView
                    MainActor.assumeIsolated {
                        guard let self, let input,
                              input.window === self.window else { return }
                        self.recordActivity()
                    }
                })
            }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.expireIfNeeded() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stop() {
            if let activityGesture { activityGesture.view?.removeGestureRecognizer(activityGesture) }
            activityGesture = nil
            timer?.invalidate()
            timer = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        func recordActivity() {
            guard !expireIfNeeded() else { return }
            deadline.recordActivity(now: ProcessInfo.processInfo.systemUptime)
        }

        private func expireIfNeeded() -> Bool {
            guard deadline.hasExpired(now: ProcessInfo.processInfo.systemUptime) else { return false }
            setUnlocked(false)
            lock?()
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }

    final class ActivityGesture: UIGestureRecognizer {
        var activity: (() -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { activity?() }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { activity?() }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            activity?()
            state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) { activity?() }
        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) { activity?() }
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            activity?()
            state = .failed
        }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .failed }
    }
}
#endif
