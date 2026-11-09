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

    // MARK: CRIT-46: a stale tick must not publish into a later watching session

    @Test func staleOCRFromStoppedSessionIsNotPublishedIntoNextSession() async throws {
        let system = FakeScreenSystem()
        let firstOCRGate = Gate()
        let ocrCalls = OCRCounter()
        let watcher = ScreenWatcher(environment: system.environment(recognizeText: { _ in
            if await ocrCalls.next() == 1 {
                await firstOCRGate.pass()   // the first session's OCR is slow
                return "OLD SESSION"
            }
            return "new session"
        }))

        watcher.start()
        #expect(await waitUntil { await firstOCRGate.arrivals == 1 })
        watcher.stop()
        watcher.start()                     // next meeting starts before the old OCR returns
        #expect(await waitUntil { watcher.latest?.ocrText == "new session" })
        await firstOCRGate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(watcher.isWatching)
        #expect(watcher.latest?.ocrText == "new session", "the stopped session's frame must not overwrite the new one")
        watcher.stop()
    }
}

actor OCRCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
