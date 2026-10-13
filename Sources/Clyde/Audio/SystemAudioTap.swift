import Foundation
import CoreAudio
import AVFAudio

/// Captures all system/meeting audio (Zoom, Google Meet in a browser tab, Teams — whatever is
/// currently playing) using a Core Audio process tap, NOT ScreenCaptureKit.
///
/// Why a tap instead of ScreenCaptureKit: taps are authorized under the lightweight "System
/// Audio Recording Only" TCC category (prompted via `NSAudioCaptureUsageDescription`), whereas
/// SCStream's `capturesAudio` requires the full Screen Recording grant — which macOS 15+
/// re-confirms with a monthly nag and would be a confusing, alarming permission for a meeting
/// copilot to ask for. Taps are also pure-audio: no video pipeline, no display enumeration.
///
/// Why a GLOBAL tap excluding our own process, rather than tapping Zoom/Chrome specifically:
/// meeting apps route audio through helper/renderer child processes whose PIDs are not stable,
/// so "tap everything except me" is far more robust than chasing a specific app's process tree.
///
/// This deliberately does NOT go through AVAudioEngine — setting the aggregate device as an
/// AVAudioEngine input silently keeps reading the real default input instead. The tap is read
/// directly via the low-level `AudioDeviceCreateIOProcIDWithBlock` IOProc.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    private let bufferHandler: (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let ioQueue = DispatchQueue(label: "com.clyde.copilot.system-audio-tap", qos: .userInteractive)

    /// Tap/aggregate-device lifecycle (create/destroy) runs here — deliberately NOT `ioQueue`.
    /// `stop()`/`start()` make several synchronous, potentially slow `AudioHardwareDestroy*` /
    /// `AudioHardwareCreate*` HAL calls. Previously the default-output-device change listener
    /// invoked those directly, dispatched onto `ioQueue` — the SAME serial queue as the
    /// real-time IOProc. Any device-change notification (unplugging Bluetooth headphones, or
    /// another app like Zoom/Meet negotiating its own audio session at launch) could then
    /// serialize a blocking teardown+rebuild against live real-time audio IO, which is a known
    /// way to hang `coreaudiod` itself — freezing every app using audio system-wide, not just
    /// Clyde. This matches exactly what was reported: toggling Bluetooth mid-meeting froze
    /// everything, and so did simply starting Zoom/Meet while the tap was active.
    private let lifecycleQueue = DispatchQueue(label: "com.clyde.copilot.system-audio-tap.lifecycle", qos: .utility)
    /// Coalesces rapid device-change notifications (a Bluetooth toggle fires several in quick
    /// succession) into one rebuild instead of racing multiple overlapping teardowns.
    private var pendingRebuildWorkItem: DispatchWorkItem?
    private var isListenerRegistered = false

    init(bufferHandler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.bufferHandler = bufferHandler
    }

    /// True once RMS above a small noise floor has been observed on at least one callback —
    /// TCC denial for taps is silent (every Core Audio call still returns noErr; you just get
    /// buffers of zeros), so this is the only reliable signal that capture is actually working.
    private(set) var hasObservedNonSilentAudio = false

    func start() throws {
        try buildTap()
        if !isListenerRegistered {
            observeDefaultOutputChanges()
            isListenerRegistered = true
        }
    }

    private func buildTap() throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [try ownProcessObjectID()])
        tapDescription.name = "Clyde System Audio Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr else { throw AudioTapError.coreAudio("AudioHardwareCreateProcessTap", status) }
        tapID = newTapID

        tapFormat = try readTapFormat(tapID: newTapID)

        let outputUID = try defaultOutputDeviceUID()
        let tapUID = tapDescription.uuid.uuidString

        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "com.clyde.copilot.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Clyde Aggregate",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ]
        ]

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &newAggregateID)
        guard status == noErr else { throw AudioTapError.coreAudio("AudioHardwareCreateAggregateDevice", status) }
        aggregateDeviceID = newAggregateID

        guard tapFormat != nil else { throw AudioTapError.missingFormat }

        var newIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
            guard let self else {
                Log.audio.error("SystemAudioTap IOProc fired but self was nil — the tap object was deallocated.")
                return
            }
            self.handle(inputData: inputData)
        }
        guard status == noErr, let ioProcID = newIOProcID else {
            throw AudioTapError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        self.ioProcID = ioProcID

        status = AudioDeviceStart(newAggregateID, ioProcID)
        guard status == noErr else { throw AudioTapError.coreAudio("AudioDeviceStart", status) }

        Log.audio.info("System audio tap started (format: \(self.tapFormat?.sampleRate ?? 0, privacy: .public)Hz, \(self.tapFormat?.channelCount ?? 0, privacy: .public)ch)")
    }

    /// Tears down just the tap/aggregate/IOProc — used both by the public `stop()` and by a
    /// device-change rebuild, which must NOT touch the property listener (see `rebuildTap`).
    private func teardownTap() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    /// Full shutdown — meeting ended, capture is stopping for good. Also removes the
    /// device-change listener; a rebuild mid-meeting (`rebuildTap`) leaves it in place.
    func stop() {
        pendingRebuildWorkItem?.cancel()
        pendingRebuildWorkItem = nil
        teardownTap()
        if isListenerRegistered {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if let block = defaultOutputListenerBlock {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, lifecycleQueue, block)
            }
            isListenerRegistered = false
        }
        defaultOutputListenerBlock = nil
    }

    // MARK: - IOProc

    private var didLogFormatRecovery = false
    private var didLogBufferConstructionFailure = false

    /// Once set, the aggregate delivers multiple separate `AudioBuffer`s per callback (rather
    /// than one unified interleaved buffer) and this is the index of the one that's actually
    /// the tap's own stream — see the comment below on why that happens and how it's picked.
    private var multiBufferTapIndex: Int?

    /// The tap's format as declared via `kAudioTapPropertyFormat` at `start()` time is not
    /// reliable once ANY `AVAudioEngine` elsewhere in the process enables voice processing.
    /// Confirmed by direct instrumentation: the aggregate device (real output sub-device + tap)
    /// can no longer combine both into one unified buffer once voice processing forces the real
    /// sub-device into a different operating format, so Core Audio instead delivers them as
    /// SEPARATE `AudioBuffer` entries within one `AudioBufferList` — e.g. buffer 0 = the real
    /// sub-device's own feed, buffer 1 = the tap's actual captured audio. This self-heals: on
    /// the first construction failure, it scans every buffer in the list for one whose channel
    /// count matches what the tap was originally declared with (falling back to the last buffer,
    /// since taps are configured after sub-devices in the aggregate's device list) and remembers
    /// that index for all subsequent callbacks.
    private func handle(inputData: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat else { return }

        var pcmBuffer: AVAudioPCMBuffer?

        if let multiBufferTapIndex {
            pcmBuffer = Self.extractSingleBuffer(from: inputData, index: multiBufferTapIndex, sampleRate: format.sampleRate)
        } else {
            pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData)
            if pcmBuffer == nil {
                let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                if ablPtr.count > 0 {
                    let chosenIndex = ablPtr.firstIndex { $0.mNumberChannels == format.channelCount } ?? (ablPtr.count - 1)
                    if let candidate = Self.extractSingleBuffer(from: inputData, index: chosenIndex, sampleRate: format.sampleRate) {
                        pcmBuffer = candidate
                        multiBufferTapIndex = chosenIndex
                        tapFormat = candidate.format
                        if !didLogFormatRecovery {
                            didLogFormatRecovery = true
                            Log.audio.info("System audio tap: aggregate now delivers \(ablPtr.count, privacy: .public) separate buffer(s); using buffer index \(chosenIndex, privacy: .public) (\(candidate.format.channelCount, privacy: .public)ch) as the tap feed.")
                        }
                    }
                }
            }
        }

        guard let pcmBuffer else {
            if !didLogBufferConstructionFailure {
                didLogBufferConstructionFailure = true
                let abl = inputData.pointee
                Log.audio.error("AVAudioPCMBuffer construction failed and could not be recovered. declared format: \(format.sampleRate, privacy: .public)Hz \(format.channelCount, privacy: .public)ch. actual ABL: mNumberBuffers=\(abl.mNumberBuffers, privacy: .public) buffer0(dataByteSize=\(abl.mBuffers.mDataByteSize, privacy: .public) numChannels=\(abl.mBuffers.mNumberChannels, privacy: .public))")
            }
            return
        }

        if !hasObservedNonSilentAudio, let channelData = pcmBuffer.floatChannelData {
            let frameCount = Int(pcmBuffer.frameLength)
            var sumOfSquares: Float = 0
            let samples = channelData[0]
            for i in 0..<frameCount { sumOfSquares += samples[i] * samples[i] }
            let rms = frameCount > 0 ? (sumOfSquares / Float(frameCount)).squareRoot() : 0
            if rms > 0.0001 { hasObservedNonSilentAudio = true }
        }

        let time = AVAudioTime(hostTime: mach_absolute_time())
        bufferHandler(pcmBuffer, time)
    }

    /// Wraps just ONE `AudioBuffer` from a (possibly multi-buffer) `AudioBufferList` in a
    /// synthetic single-buffer list and builds an `AVAudioPCMBuffer` from it, so a specific
    /// stream within a multi-stream aggregate callback can be captured on its own. Safe to use
    /// `bufferListNoCopy` here for the same reason it's safe on the original callback data: the
    /// result is only read synchronously within this same IOProc callback (converted into
    /// freshly-allocated buffers downstream before anything asynchronous touches it).
    private static func extractSingleBuffer(from inputData: UnsafePointer<AudioBufferList>, index: Int, sampleRate: Double) -> AVAudioPCMBuffer? {
        let ablPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard index >= 0, index < ablPtr.count else { return nil }
        var singleAudioBuffer = ablPtr[index]
        guard singleAudioBuffer.mNumberChannels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: singleAudioBuffer.mNumberChannels, interleaved: true) else {
            return nil
        }
        return withUnsafeMutablePointer(to: &singleAudioBuffer) { bufferPtr -> AVAudioPCMBuffer? in
            var singleList = AudioBufferList(mNumberBuffers: 1, mBuffers: bufferPtr.pointee)
            return withUnsafeMutablePointer(to: &singleList) { listPtr in
                AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: listPtr)
            }
        }
    }

    // MARK: - Setup helpers

    private func ownProcessObjectID() throws -> AudioObjectID {
        var pid = getpid()
        var objectID: AudioObjectID = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), pidPtr, &dataSize, &objectID)
        }
        guard status == noErr else { throw AudioTapError.coreAudio("TranslatePIDToProcessObject", status) }
        return objectID
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd)
        guard status == noErr else { throw AudioTapError.coreAudio("kAudioTapPropertyFormat", status) }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw AudioTapError.missingFormat }
        return format
    }

    private func defaultOutputDeviceUID() throws -> String {
        let deviceID = try defaultOutputDeviceID()
        var uid: CFString = "" as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, uidPtr)
        }
        guard status == noErr else { throw AudioTapError.coreAudio("DeviceUID", status) }
        return uid as String
    }

    private func defaultOutputDeviceID() throws -> AudioObjectID {
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr else { throw AudioTapError.coreAudio("DefaultOutputDevice", status) }
        return deviceID
    }

    /// The aggregate is built around a snapshot of the default output device. If the user plugs
    /// in headphones (or otherwise changes the default output) mid-meeting, that snapshot goes
    /// stale — rebuild the tap so capture doesn't silently die. Registered exactly once per
    /// `start()`/`stop()` lifecycle (see `isListenerRegistered`), on `lifecycleQueue` rather than
    /// the real-time `ioQueue` — see that property's doc comment for why.
    private func observeDefaultOutputChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild()
        }
        defaultOutputListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, lifecycleQueue, block)
    }

    /// Debounces bursts of device-change notifications (a single Bluetooth toggle fires several)
    /// into one rebuild, and only ever tears down/rebuilds the tap itself — never re-touches the
    /// listener, so repeated device changes can't accumulate duplicate listener registrations.
    private func scheduleRebuild() {
        pendingRebuildWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Log.audio.info("Default output device changed — rebuilding system audio tap.")
            self.teardownTap()
            do { try self.buildTap() } catch {
                Log.audio.error("Failed to rebuild system audio tap after output change: \(error.localizedDescription, privacy: .public)")
            }
        }
        pendingRebuildWorkItem = workItem
        lifecycleQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
}

enum AudioTapError: Error, CustomStringConvertible, LocalizedError {
    case coreAudio(String, OSStatus)
    case missingFormat

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .coreAudio(let call, let status): return "\(call) failed with OSStatus \(status)"
        case .missingFormat: return "Tap did not report a usable audio format"
        }
    }
}
