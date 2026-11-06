import Foundation
import IOKit.pwr_mgt

typealias RemoteUserActivityDeclaration = (
    CFString, IOPMUserActiveType, UnsafeMutablePointer<IOPMAssertionID>
) -> IOReturn

/// Reports a remote viewer as user activity so macOS powers on the display
/// before ScreenCaptureKit starts serving it. Reusing the assertion identifier
/// lets IOKit extend the activity window without accumulating assertions.
final class RemoteDisplayActivity {
    private var assertionID = IOPMAssertionID(0)
    private let declare: RemoteUserActivityDeclaration

    init(
        declare: @escaping RemoteUserActivityDeclaration = {
            IOPMAssertionDeclareUserActivity($0, $1, $2)
        }
    ) {
        self.declare = declare
    }

    func wake() throws {
        let result = declare(
            "Dieter remote desktop connection" as CFString, kIOPMUserActiveRemote, &assertionID)
        guard result == kIOReturnSuccess else {
            throw RemoteDisplayActivityError(status: result)
        }
    }
}

private struct RemoteDisplayActivityError: LocalizedError {
    let status: IOReturn
    var errorDescription: String? {
        "Unable to wake the macOS display (IOKit status \(status))"
    }
}
