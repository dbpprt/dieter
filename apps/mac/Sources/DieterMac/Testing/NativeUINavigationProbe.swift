import SwiftUI

#if DIETER_UI_SMOKE
import AppKit

/// Diagnostic only: observes a native destination drawing callback after a
/// queued click. Drawing is not proof of compositor presentation.
@MainActor final class NativeUINavigationProbe {
    static weak var active: NativeUINavigationProbe?
    private let window: NSWindow
    private let marker: String
    private var startTime = 0.0
    private var lastTick = 0.0
    private var eventMonitor: Any?
    private var timer: Timer?
    private(set) var firstDrawMS: Double?
    private(set) var mouseDownMS: Double?
    private(set) var maximumMainLoopGapMS = 0.0

    init(window: NSWindow, section: AppSection) {
        self.window = window
        marker = section.rawValue
    }

    func start() {
        startTime = ProcessInfo.processInfo.systemUptime
        lastTick = startTime
        Self.active = self
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.windowNumber == self.window.windowNumber, self.mouseDownMS == nil {
                    self.mouseDownMS = self.elapsedMS
                }
            }
            return event
        }
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.maximumMainLoopGapMS = max(self.maximumMainLoopGapMS, (now - self.lastTick) * 1_000)
                self.lastTick = now
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        timer?.invalidate()
        eventMonitor = nil; timer = nil
        if Self.active === self { Self.active = nil }
    }

    private var elapsedMS: Double { (ProcessInfo.processInfo.systemUptime - startTime) * 1_000 }

    func destinationDrawn(_ section: String, in view: NSView) {
        guard firstDrawMS == nil, mouseDownMS != nil, section == marker,
              view.window === window, view.bounds.width > 0, view.bounds.height > 0 else { return }
        firstDrawMS = elapsedMS
    }
}

private struct NavigationSmokeDestination: NSViewRepresentable {
    let section: AppSection
    final class Anchor: NSView {
        var section = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NativeUINavigationProbe.active?.destinationDrawn(section, in: self)
        }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        view.section = section.rawValue
        view.needsDisplay = true
    }
}
#endif

extension View {
    @ViewBuilder func navigationSmokeDestination(_ section: AppSection) -> some View {
#if DIETER_UI_SMOKE
        if NativeUISmokeTargets.enabled { background(NavigationSmokeDestination(section: section)) }
        else { self }
#else
        self
#endif
    }
}
