import CoreGraphics
import Foundation
import Testing
@testable import Clyde

/// CRIT-39: a screen that stays the same (one slide, one document) and keeps being captured
/// successfully must stay attached to chat/suggestions past the 120 s freshness cutoff.
@MainActor
@Suite(.serialized) struct ScreenWatcherFreshnessTests {

    @Test func unchangedScreenStaysAvailableBeyondTwoMinutes() async throws {
        let system = FakeScreenSystem()
        system.now = Date().addingTimeInterval(-300)      // first frame captured 5 minutes ago
        let watcher = ScreenWatcher(environment: system.environment())

        watcher.start()
        #expect(await waitUntil { watcher.latest != nil })
        let firstCaptures = system.captureCount
        system.now = Date()                               // same slide, observed again now
        #expect(await waitUntil { system.captureCount >= firstCaptures + 3 })

        #expect(watcher.changeGeneration == 1, "unchanged polls must not count as a change")
        let snapshot = try #require(watcher.latest)
        #expect(Date().timeIntervalSince(snapshot.capturedAt) < 120, "a successful unchanged capture refreshes freshness")
        let message = ProactiveAnalyzer.userMessage(text: "where is this?", screen: snapshot)
        #expect(message.content.contains { if case .image = $0 { return true } else { return false } },
                "a screen observed seconds ago must still be attached")
        watcher.stop()
    }

    @Test func failingCapturesDoNotKeepAFrameFresh() async throws {
        let system = FakeScreenSystem()
        let start = Date().addingTimeInterval(-300)
        system.now = start
        let failing = FailSwitch()
        let watcher = ScreenWatcher(environment: {
            var env = system.environment()
            let capture = env.captureDisplayUnderMouse
            env.captureDisplayUnderMouse = { width in
                if failing.on { throw CaptureFailure() }
                return try await capture(width)
            }
            return env
        }())

        watcher.start()
        #expect(await waitUntil { watcher.latest != nil })
        failing.on = true
        system.now = Date()
        #expect(await waitUntil { watcher.lastError != nil })
        try await Task.sleep(for: .milliseconds(30))

        #expect(watcher.latest?.capturedAt == start, "an unobserved screen must age out normally")
        watcher.stop()
    }
}

struct CaptureFailure: Error {}

@MainActor
final class FailSwitch {
    var on = false
}
