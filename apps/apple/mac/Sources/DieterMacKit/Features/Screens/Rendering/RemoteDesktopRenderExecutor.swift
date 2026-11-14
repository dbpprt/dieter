import Foundation

// A private run loop services both Metal display-link callbacks and immediate
// draws. No AppKit calls or synchronous hops back to the UI thread are allowed.
final class RemoteDesktopRenderExecutor: @unchecked Sendable {
    private let loop: CFRunLoop
    init() {
        let ready = RunLoopReady()
        let thread = Thread {
            autoreleasepool {
                let port = Port()
                RunLoop.current.add(port, forMode: .default)
                ready.publish(CFRunLoopGetCurrent())
                CFRunLoopRun()
                port.invalidate()
            }
        }
        thread.name = "Dieter screen rendering"
        thread.qualityOfService = .userInteractive
        thread.start()
        loop = ready.wait()
    }

    func perform(_ work: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            autoreleasepool(invoking: work)
        }
        CFRunLoopWakeUp(loop)
    }

    func stop() { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    deinit { stop() }
}

private final class RunLoopReady: @unchecked Sendable {
    private let condition = NSCondition()
    private var loop: CFRunLoop?
    func publish(_ value: CFRunLoop) {
        condition.lock(); loop = value; condition.signal(); condition.unlock()
    }
    func wait() -> CFRunLoop {
        condition.lock(); defer { condition.unlock() }
        while loop == nil { condition.wait() }
        return loop!
    }
}
