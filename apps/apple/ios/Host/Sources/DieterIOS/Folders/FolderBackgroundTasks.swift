import BackgroundTasks
import DieterCore
import Foundation
import UIKit
import os

// The Kotlin façade confines its work to the core's dispatcher; its entry points may be called
// from any thread.
extension DieterShared: @unchecked @retroactive Sendable {}

/// Synced folders' background hosts on BGTaskScheduler. Each run calls the core's
/// `folderSyncWindow`, which decides what may run (network, power, storage) and persists after
/// every durable step, so a run the system ends early resumes in the next one.
///
/// - `<bundle>.folders.refresh`, a `BGAppRefreshTask` (about 30 s), exchanges the index and moves
///   small files; its earliest begin date is the preferred interval and the core reschedules it
///   after every window.
/// - `<bundle>.folders.transfer`, a `BGProcessingTask`, takes larger backlogs; it requires a
///   network, and external power when the person syncs only while charging.
/// - Sync now that leaves work uses a `BGContinuedProcessingTask` on iOS 26 and later, which shows
///   system progress; earlier releases queue the processing task.
/// - When Dieter goes to the background, `beginBackgroundTask` lets the current work finish
///   (about 30 s) before the system suspends the app.
///
/// No background `URLSession`: calls run as roster-pinned mutual TLS inside relay tunnels or
/// WebRTC channels, which only the app process can run.
public final class FolderBackgroundTasks: NSObject, NativeFolderScheduler, @unchecked Sendable {
    public static let shared = FolderBackgroundTasks()

    private struct State {
        var window: (@Sendable (Double, String, Int32) async -> Bool)?
        var requiresCharging = false
        /// The core asked for a periodic window; cancel() clears it.
        var scheduled = false
        /// Registering an identifier twice raises an exception.
        var registered = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.getdieter.ios", category: "folders")
    private let bundle = Bundle.main.bundleIdentifier ?? "com.getdieter.ios"
    var refreshIdentifier: String { "\(bundle).folders.refresh" }
    var transferIdentifier: String { "\(bundle).folders.transfer" }
    /// Info.plist permits `<bundle>.folders.sync.*`; each Sync now submits its own identifier.
    var continuedPrefix: String { "\(bundle).folders.sync." }

    /// Triggers as `DieterShared.folderSyncWindow` takes them (`FolderTrigger` ordinals).
    enum Trigger {
        static let background: Int32 = 0
        static let localChange: Int32 = 2
        static let manual: Int32 = 4
    }

    private static let refreshSeconds = 25.0
    private static let processingSeconds = 10 * 60.0
    private static let continuedRoundSeconds = 2 * 60.0
    private static let continuedRounds = 15

    /// Registers the launch handlers. Call once, before the app finishes launching.
    @MainActor
    public func register() {
        guard
            !state.withLock({ state in
                defer { state.registered = true }
                return state.registered
            })
        else { return }
        let scheduler = BGTaskScheduler.shared
        let refresh = scheduler.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            FolderBackgroundTasks.shared.run(task, seconds: Self.refreshSeconds, trigger: Trigger.background)
        }
        let transfer = scheduler.register(forTaskWithIdentifier: transferIdentifier, using: nil) { task in
            FolderBackgroundTasks.shared.run(task, seconds: Self.processingSeconds, trigger: Trigger.background)
        }
        if !refresh || !transfer { log.error("folder background tasks are not permitted by Info.plist") }
    }

    /// Connects the core once it exists; runs that fire before then end at once.
    func connect(_ shared: DieterShared) {
        state.withLock {
            $0.window = { seconds, folderId, trigger in
                do {
                    return try await shared.folderSyncWindow(seconds: seconds, folderId: folderId, trigger: trigger)
                        .boolValue
                } catch {
                    return true
                }
            }
        }
    }

    private var window: (@Sendable (Double, String, Int32) async -> Bool)? { state.withLock { $0.window } }

    // MARK: NativeFolderScheduler (called on the core's thread)

    public func schedule(intervalSeconds: Int64, unmeteredOnly: Bool, requiresCharging: Bool) {
        state.withLock {
            $0.requiresCharging = requiresCharging
            $0.scheduled = true
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(intervalSeconds, 60)))
        do {
            // A request with the same identifier replaces the pending one.
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("folder refresh could not be scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func requestLongRun(userInitiated: Bool) {
        if userInitiated, #available(iOS 26.0, *) {
            Task { @MainActor in
                // A continued task starts from what the person did, while Dieter is on screen.
                if UIApplication.shared.applicationState == .active, self.submitContinued() { return }
                self.submitProcessing()
            }
            return
        }
        submitProcessing()
    }

    public func cancel() {
        state.withLock { $0.scheduled = false }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: transferIdentifier)
    }

    private func submitProcessing() {
        let request = BGProcessingTaskRequest(identifier: transferIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = state.withLock { $0.requiresCharging }
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("folder transfer could not be scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Runs

    /// Completes a task exactly once, from the run or from its expiration.
    private final class Completion: @unchecked Sendable {
        private let done = OSAllocatedUnfairLock(initialState: false)
        private let task: BGTask

        init(_ task: BGTask) { self.task = task }

        func finish(success: Bool) {
            guard
                done.withLock({ done in
                    defer { done = true }
                    return !done
                })
            else { return }
            task.setTaskCompleted(success: success)
        }
    }

    private func run(_ task: BGTask, seconds: Double, trigger: Int32) {
        let completion = Completion(task)
        guard let window else {
            completion.finish(success: false)
            return
        }
        // The core stops at its own deadline and persists every durable step, so an expiration
        // only has to report the task done before the system suspends the app.
        task.expirationHandler = { completion.finish(success: false) }
        Task {
            _ = await window(seconds, "", trigger)
            completion.finish(success: true)
        }
    }

    @available(iOS 26.0, *)
    @MainActor
    private func submitContinued() -> Bool {
        let identifier = continuedPrefix + UUID().uuidString.lowercased()
        // Continued processing tasks may register after launch, one identifier per request.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            FolderBackgroundTasks.shared.runContinued(task)
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Syncing folders", subtitle: "Dieter is moving your files.")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            log.info("folder sync cannot continue in the background: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Windows of a few minutes until nothing remains, with system progress after each one.
    @available(iOS 26.0, *)
    private func runContinued(_ task: BGContinuedProcessingTask) {
        let completion = Completion(task)
        guard let window else {
            completion.finish(success: false)
            return
        }
        let expired = OSAllocatedUnfairLock(initialState: false)
        task.expirationHandler = {
            expired.withLock { $0 = true }
            completion.finish(success: false)
        }
        let progress = task.progress
        progress.totalUnitCount = Int64(Self.continuedRounds)
        progress.completedUnitCount = 0
        Task {
            var round = 0
            var remains = true
            while remains, round < Self.continuedRounds, !expired.withLock({ $0 }) {
                remains = await window(Self.continuedRoundSeconds, "", Trigger.manual)
                round += 1
                progress.completedUnitCount = remains ? Int64(round) : Int64(Self.continuedRounds)
            }
            completion.finish(success: !remains)
        }
    }

    /// Dieter went to the background: finish what is under way for as long as iOS allows, then
    /// leave the rest to the scheduled tasks (the core queues a processing task when work remains).
    @MainActor
    public func enteredBackground() {
        guard let window, state.withLock({ $0.scheduled }) else { return }
        let application = UIApplication.shared
        let background = BackgroundTask()
        background.identifier = application.beginBackgroundTask(withName: "Folder sync") {
            MainActor.assumeIsolated { background.end() }
        }
        guard background.identifier != .invalid else { return }
        let seconds = max(5, min(application.backgroundTimeRemaining - 5, Self.refreshSeconds))
        Task { @MainActor in
            _ = await window(seconds, "", Trigger.localChange)
            background.end()
        }
    }
}

/// One `beginBackgroundTask` assertion, ended once.
@MainActor
private final class BackgroundTask {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
