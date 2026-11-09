import CoreGraphics
import Foundation
import Testing
@testable import Clyde

/// Regression tests for ScreenWatcher's stop/start lifecycle. All capture/OCR is injected
/// (FakeScreenSystem); nothing reads the real screen or needs screen-recording access.
@MainActor
@Suite(.serialized) struct ScreenWatcherLifecycleTests {

    // MARK: CRIT-38: a cancelled tick must not publish after stop()

    @Test func stopDuringOCRDoesNotRestoreSnapshot() async throws {
        let system = FakeScreenSystem()
        let ocrGate = Gate()
        let watcher = ScreenWatcher(environment: system.environment(recognizeText: { _ in
            await ocrGate.pass()
            return "previous meeting's screen"
        }))

        watcher.start()
        #expect(await waitUntil { await ocrGate.arrivals == 1 })
        watcher.stop()                      // meeting ends while OCR is in flight
        await ocrGate.open()                // OCR finishes afterwards
        try await Task.sleep(for: .milliseconds(100))

        #expect(watcher.isWatching == false)
        #expect(watcher.latest == nil, "stop() cleared the snapshot; the resumed tick must not restore it")
        #expect(watcher.changeGeneration == 0)
    }

    @Test func stopDuringCaptureDoesNotRestoreSnapshot() async throws {
        let system = FakeScreenSystem()
        let captureGate = Gate()
        system.duringCapture = { await captureGate.pass() }
        let watcher = ScreenWatcher(environment: system.environment())

        watcher.start()
        #expect(await waitUntil { await captureGate.arrivals == 1 })
        watcher.stop()
        await captureGate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(watcher.latest == nil)
        #expect(watcher.changeGeneration == 0)
    }
}

actor OCRCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
