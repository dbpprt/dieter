import Foundation
import IOKit.pwr_mgt

typealias RemoteUserActivityDeclaration = (
    CFString, IOPMUserActiveType, UnsafeMutablePointer<IOPMAssertionID>
) -> IOReturn
typealias DisplaySleepAssertionCreation = (UnsafeMutablePointer<IOPMAssertionID>) -> IOReturn
typealias DisplaySleepAssertionRelease = (IOPMAssertionID) -> IOReturn

/// Reports a remote viewer as user activity so macOS powers on the display
/// before ScreenCaptureKit starts serving it. Reusing the assertion identifier
/// lets IOKit extend the activity window without accumulating assertions.
final class RemoteDisplayActivity {
    private let lock = NSLock()
    private var assertionID = IOPMAssertionID(0)
    private var keepAwakeID: IOPMAssertionID?
    private let create: DisplaySleepAssertionCreation
    private let release: DisplaySleepAssertionRelease
    private let declare: RemoteUserActivityDeclaration

    init(
        create: @escaping DisplaySleepAssertionCreation = {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Dieter remote desktop capture" as CFString, $0)
        },
        release: @escaping DisplaySleepAssertionRelease = { IOPMAssertionRelease($0) },
        declare: @escaping RemoteUserActivityDeclaration = {
            IOPMAssertionDeclareUserActivity($0, $1, $2)
        }
    ) {
        self.create = create
        self.release = release
        self.declare = declare
    }

    deinit { endCapture() }

    func wake() throws {
        try lock.withLock { try wakeLocked() }
    }

    /// Acquire before waking: an idle-sleep assertion alone does not power on
    /// an already sleeping display. Each capture rendition owns one assertion,
    /// so stopping a viewer cannot let another active rendition fall asleep.
    func beginCapture() throws {
        try lock.withLock {
            if keepAwakeID == nil {
                var id = IOPMAssertionID(0)
                let result = create(&id)
                guard result == kIOReturnSuccess else {
                    throw DisplaySleepAssertionError(operation: "keep awake", status: result)
                }
                keepAwakeID = id
            }
            do {
                try wakeLocked()
            } catch {
                endCaptureLocked()
                throw error
            }
        }
    }

    func endCapture() {
        lock.withLock { endCaptureLocked() }
    }

    private func endCaptureLocked() {
        guard let id = keepAwakeID else { return }
        let result = release(id)
        if result == kIOReturnSuccess {
            keepAwakeID = nil
        } else {
            // Keep ownership so a later cleanup/deinit can retry. Process exit
            // also releases any assertion if the helper is lost altogether.
            writeDiagnostic(
                DisplaySleepAssertionError(operation: "release keep-awake", status: result).localizedDescription)
        }
    }

    private func wakeLocked() throws {
        let result = declare(
            "Dieter remote desktop connection" as CFString, kIOPMUserActiveRemote, &assertionID)
        guard result == kIOReturnSuccess else {
            throw RemoteDisplayActivityError(status: result)
        }
    }
}

private struct DisplaySleepAssertionError: LocalizedError {
    let operation: String
    let status: IOReturn
    var errorDescription: String? {
        "Unable to \(operation) the macOS display (IOKit status \(status))"
    }
}

private struct RemoteDisplayActivityError: LocalizedError {
    let status: IOReturn
    var errorDescription: String? {
        "Unable to wake the macOS display (IOKit status \(status))"
    }
}
