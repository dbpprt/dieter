// The screen key map and clipboard content the capture helper (native/macos)
// shares with the clients, available wherever the transport is imported.
@_exported import RemoteDesktopProtocol

/// The remote-desktop framing revision the clients speak (the
/// `dieter-session-v<number>` data channel and the input protocol version).
public enum DieterRemoteDesktopProtocol {
    public static let version = "3"
    public static let number: UInt32 = 3
}
