import DieterCore
import Foundation
import Network
import UIKit
import os

/// The device's network and power state for the core's folder sync policy: `NWPathMonitor` for the
/// network (unsatisfied, `isExpensive`, Low Data Mode as `isConstrained`), `UIDevice` for the
/// battery with monitoring enabled, and `ProcessInfo` for Low Power Mode. iOS has no roaming API,
/// so the core's cellular choice covers roaming.
public final class IOSDeviceConditions: NSObject, NativeDeviceConditions, @unchecked Sendable {
    private struct Battery {
        var charging = true
        /// 0...100; -1 when unknown (the simulator).
        var percent: Int32 = -1
    }

    private let monitor = NWPathMonitor()
    private let path: OSAllocatedUnfairLock<NWPath?> = OSAllocatedUnfairLock(initialState: nil)
    private let battery = OSAllocatedUnfairLock(initialState: Battery())
    /// Set once on the main actor when monitoring starts; removed when released.
    private var observers: [any NSObjectProtocol] = []

    private init(queue: DispatchQueue) {
        super.init()
        let path = self.path
        monitor.pathUpdateHandler = { update in path.withLock { $0 = update } }
        monitor.start(queue: queue)
    }

    /// Starts watching the network and the battery.
    @MainActor
    public static func start() -> IOSDeviceConditions {
        let conditions = IOSDeviceConditions(queue: DispatchQueue(label: "com.getdieter.ios.folders.network"))
        conditions.watchBattery()
        return conditions
    }

    @MainActor
    private func watchBattery() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        readBattery()
        let center = NotificationCenter.default
        let tokens = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readBattery() }
            }
        }
        observers = tokens
    }

    deinit {
        monitor.cancel()
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    @MainActor
    private func readBattery() {
        let device = UIDevice.current
        let state = device.batteryState
        let level = device.batteryLevel
        battery.withLock {
            // An unknown state (the simulator) never holds folder sync back.
            $0.charging = state == .charging || state == .full || state == .unknown
            $0.percent = level < 0 ? -1 : Int32((level * 100).rounded())
        }
    }

    public func current() -> NativeFolderConditions {
        let path = self.path.withLock { $0 } ?? monitor.currentPath
        let network: Int32 =
            switch path.status {
            case .satisfied: path.isExpensive ? 2 : 1
            default: 0
            }
        let battery = self.battery.withLock { $0 }
        return NativeFolderConditions(
            network: network, constrained: path.isConstrained, charging: battery.charging,
            batteryPercent: battery.percent, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
