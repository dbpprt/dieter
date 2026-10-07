import Foundation
import IOKit.hid

protocol PrivacyHIDDriver: AnyObject {
    func availability() throws
    func acquire() throws
    func audit() throws -> Int
    func release() throws
}

// The lease is global, but belongs to the authenticated acquiring login user.
// Its lifetime is unrelated to a transport connection or viewer session.
final class PrivacyHIDLease {
    let driver: any PrivacyHIDDriver
    private(set) var owner: uid_t?
    let generation = UUID().uuidString
    init(driver: any PrivacyHIDDriver) { self.driver = driver }

    func perform(_ action: String, uid: uid_t) -> PrivacyHIDStatus {
        guard owner == nil || owner == uid else {
            return .init(reason: "Privacy input protection belongs to another login user")
        }
        do {
            if action != "off" { try driver.availability() }
            if action == "on" && owner == nil {
                // Retain ownership after a partial acquisition failure. Only
                // its owner can restore successfully seized devices.
                owner = uid
                try driver.acquire()
            } else if action == "off" {
                try driver.release()
                owner = nil
            }
            let count = owner == nil ? 0 : try driver.audit()
            return .init(available: true, active: owner != nil, deviceCount: count, generation: generation)
        } catch {
            return .init(generation: generation, reason: String(error.localizedDescription.prefix(1024)))
        }
    }
}

final class SystemPrivacyHIDDriver: PrivacyHIDDriver {
    private var manager: IOHIDManager?
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var rejected: [UInt64: IOReturn] = [:]
    private var overflow = false

    private static func identity(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private func seize(_ device: IOHIDDevice) {
        let id = Self.identity(device)
        guard devices[id] == nil else { return }
        guard id != 0, devices.count + rejected.count < 128 else { overflow = true; return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result == kIOReturnSuccess {
            devices[id] = device; rejected.removeValue(forKey: id)
        } else {
            rejected[id] = result
        }
    }

    func availability() throws {
        guard geteuid() == 0 else {
            throw PrivacyHIDError("Privacy input protection requires the approved privileged helper")
        }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw PrivacyHIDError("Grant Input Monitoring to Dieter Daemon on this Mac")
        }
    }

    func acquire() throws {
        try availability()
        guard manager == nil else { return }
        // The manager must not auto-open devices non-exclusively before our
        // seizure attempt: opening an already-open reference is not an upgrade.
        let next = IOHIDManagerCreate(
            kCFAllocatorDefault, IOOptionBits(IOHIDManagerOptions.independentDevices.rawValue))
        manager = next
        // Include consumer keys, digitizers and composite HID devices. Never
        // exclude a device merely because it reports a virtual transport.
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 1],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 4],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 5],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 7],
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 8],
            [kIOHIDDeviceUsagePageKey: 12], [kIOHIDDeviceUsagePageKey: 13],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(next, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            next,
            { context, _, _, device in
                Unmanaged<SystemPrivacyHIDDriver>.fromOpaque(context!).takeUnretainedValue().seize(device)
            }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            next,
            { context, _, _, device in
                let owner = Unmanaged<SystemPrivacyHIDDriver>.fromOpaque(context!).takeUnretainedValue()
                let id = SystemPrivacyHIDDriver.identity(device)
                if owner.devices.removeValue(forKey: id) != nil { _ = IOHIDDeviceClose(device, 0) }
                owner.rejected.removeValue(forKey: id)
            }, context)
        IOHIDManagerScheduleWithRunLoop(next, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(next, 0)
        guard result == kIOReturnSuccess else {
            throw PrivacyHIDError("Cannot enumerate privacy input devices (\(result))")
        }
        if let found = IOHIDManagerCopyDevices(next) as? Set<IOHIDDevice> {
            for device in found { seize(device) }
        }
        _ = try audit()
    }

    func audit() throws -> Int {
        guard let manager, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw PrivacyHIDError("Privacy input protection lost Input Monitoring permission")
        }
        // Rescan after sleep/wake as well as reacting immediately to hot-plug.
        if let found = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in found { seize(device) }
        }
        guard !overflow else { throw PrivacyHIDError("Too many input devices to verify privacy protection") }
        guard rejected.isEmpty else {
            throw PrivacyHIDError(
                "macOS refused exclusive access to \(rejected.count) input device(s); protection is incomplete")
        }
        return devices.count
    }

    func release() throws {
        for (id, device) in devices {
            let result = IOHIDDeviceClose(device, 0)
            guard result == kIOReturnSuccess || result == kIOReturnNotOpen || result == kIOReturnNoDevice else {
                throw PrivacyHIDError("Cannot restore an input device (\(result)); retry unlock")
            }
            devices.removeValue(forKey: id)
        }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDManagerClose(manager, 0)
        }
        manager = nil; rejected = [:]; overflow = false
    }
}
