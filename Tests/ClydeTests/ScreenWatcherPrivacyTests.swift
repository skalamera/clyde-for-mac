import CoreGraphics
import Foundation
import Testing
@testable import Clyde

/// CRIT-40: the password-manager pause must hold at capture time, and must not leave the last
/// pre-pause frame pinned (where the analyzer would pick it up once it "settles").
@MainActor
@Suite(.serialized) struct ScreenWatcherPrivacyTests {

    @Test func switchingToPasswordManagerDuringCaptureDiscardsTheFrame() async throws {
        let system = FakeScreenSystem()
        // The user Cmd-Tabs to 1Password while the capture awaits are suspended.
        system.duringCapture = { [unowned system] in
            system.frontmostBundleID = "com.1password.1password"
            system.frontmostName = "1Password"
        }
        let watcher = ScreenWatcher(environment: system.environment())

        watcher.start()
        #expect(await waitUntil { system.captureCount >= 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(watcher.latest == nil, "a frame grabbed while a vault came to the front must not be kept")
        #expect(watcher.changeGeneration == 0)
        #expect(watcher.isPausedForPrivacy)
        watcher.stop()
    }

    @Test func privacyPauseDropsTheLastFrameInsteadOfPinningIt() async throws {
        let system = FakeScreenSystem()
        let watcher = ScreenWatcher(environment: system.environment())

        watcher.start()
        #expect(await waitUntil { watcher.latest != nil })
        system.frontmostBundleID = "com.bitwarden.desktop"
        system.frontmostName = "Bitwarden"
        #expect(await waitUntil { watcher.isPausedForPrivacy })
        try await Task.sleep(for: .milliseconds(30))

        #expect(watcher.latest == nil, "the pre-pause frame must not outlive the pause")
        watcher.stop()
    }

    @Test func watchingResumesWithAFreshFrameAfterThePause() async throws {
        let system = FakeScreenSystem()
        let watcher = ScreenWatcher(environment: system.environment())

        watcher.start()
        #expect(await waitUntil { watcher.latest != nil })
        system.frontmostBundleID = "com.apple.Passwords"
        #expect(await waitUntil { watcher.isPausedForPrivacy })
        system.frontmostBundleID = "com.apple.Safari"   // back to the same, unchanged page
        #expect(await waitUntil { watcher.latest != nil && !watcher.isPausedForPrivacy },
                "the same screen must be picked up again after the pause, not treated as unchanged")
        watcher.stop()
    }
}

@Suite struct ScreenCaptureFilterTests {
    @Test func captureFilterExcludesPasswordManagersAndClyde() {
        let own: pid_t = 4242
        #expect(ScreenWatcher.isExcludedFromCapture(bundleIdentifier: "com.1password.1password", processID: 10, ownPID: own))
        #expect(ScreenWatcher.isExcludedFromCapture(bundleIdentifier: "com.apple.Passwords", processID: 11, ownPID: own))
        #expect(ScreenWatcher.isExcludedFromCapture(bundleIdentifier: "com.clyde.copilot", processID: own, ownPID: own))
        #expect(!ScreenWatcher.isExcludedFromCapture(bundleIdentifier: "com.apple.Safari", processID: 12, ownPID: own))
    }
}
