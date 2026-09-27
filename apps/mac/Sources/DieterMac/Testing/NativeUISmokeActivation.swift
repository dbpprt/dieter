#if DIETER_UI_SMOKE
    import AppKit
    import DieterCore
    import Foundation

    /// A runner-owned launch advertises its exact PID only after the app scene is ready.
    /// Launch Services then foregrounds that existing application before journeys begin.
    @MainActor enum NativeUISmokeActivation {
        static func awaitForeground() async -> Bool {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--e2e-activation-ready"), flag + 1 < arguments.count else {
                return true
            }
            do {
                try String(ProcessInfo.processInfo.processIdentifier).write(
                    toFile: arguments[flag + 1], atomically: true, encoding: .utf8)
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                while !NSApp.isActive && ContinuousClock.now < deadline {
                    try await DieterTaskSleep.milliseconds(50)
                }
                guard NSApp.isActive else { throw ActivationError.foregroundUnavailable }
                NSApp.windows.first(where: { $0.identifier?.rawValue == "workspace" || $0.title == "Dieter" })?
                    .makeKeyAndOrderFront(nil)
                return true
            } catch {
                print("E2E foreground activation failed: \(error)")
                NSApp.terminate(nil)
                return false
            }
        }
        private enum ActivationError: Error { case foregroundUnavailable }
    }
#endif
