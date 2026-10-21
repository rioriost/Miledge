import Foundation
#if os(macOS)
import AppKit
#endif
import XCTest
@testable import MiledgeApp

@MainActor
final class AutomaticLockTests: XCTestCase {
    func testIdleDeadlineAndReturningInputCannotExtendExpiredSession() {
        var policy = InactivityDeadline()
        XCTAssertFalse(policy.hasExpired(now: 1_000))
        policy.setUnlocked(true, now: 100)
        XCTAssertFalse(policy.hasExpired(now: 159.999))
        XCTAssertTrue(policy.hasExpired(now: 160))
        policy.recordActivity(now: 161)
        XCTAssertTrue(policy.hasExpired(now: 161))
        policy.setUnlocked(false, now: 162)
        policy.recordActivity(now: 163)
        XCTAssertNil(policy.deadline)
    }

    func testActivityAndFreshUnlockStartFullInterval() {
        var policy = InactivityDeadline()
        policy.setUnlocked(true, now: 100)
        policy.recordActivity(now: 140)
        XCTAssertFalse(policy.hasExpired(now: 199))
        XCTAssertTrue(policy.hasExpired(now: 200))
        policy.setUnlocked(false, now: 201)
        policy.setUnlocked(true, now: 300)
        XCTAssertFalse(policy.hasExpired(now: 359))
        XCTAssertTrue(policy.hasExpired(now: 360))
    }

    #if os(macOS)
    func testResigningAndSleepLockOnceAndStopRemovesObservers() {
        let monitor = MacAutomaticLock()
        var reasons: [MacAutomaticLock.Reason] = []
        monitor.start(unlocked: false) { reasons.append($0) }
        defer { monitor.stop() }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertTrue(reasons.isEmpty, "Authentication must not be interrupted by its system prompt.")
        monitor.setUnlocked(true)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(reasons, [.inactive])
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            monitor.setUnlocked(true)
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
        }
        XCTAssertEqual(reasons, [.inactive, .sleep, .sleep, .sleep])
        monitor.stop()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(reasons.count, 4)
    }
    #endif
}
