import AppKit
import Observation
import QuartzCore
import SwiftUI

struct DieterIslandDisplayGeometry: Equatable {
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let hasPhysicalNotch: Bool
    let notchWidth: CGFloat

    static func resolve(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?
    ) -> Self {
        let hasNotch = safeAreaTop > 0
        let calculatedWidth: CGFloat
        if hasNotch, let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth, left > 0, right > 0 {
            calculatedWidth = max(150, screenFrame.width - left - right + 4)
        } else {
            calculatedWidth = 180
        }
        return Self(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hasPhysicalNotch: hasNotch,
            notchWidth: calculatedWidth
        )
    }

    var collapsedSize: CGSize {
        hasPhysicalNotch
            ? CGSize(width: max(300, notchWidth + 132), height: 42)
            : CGSize(width: 270, height: 38)
    }

    func expandedSize(itemCount: Int) -> CGSize {
        let visibleRows = min(max(itemCount, 0), 4)
        let populatedBodyHeight = CGFloat(visibleRows * 62) + 48
        let bodyHeight = visibleRows == 0 ? 190 : max(168, populatedBodyHeight)
        return CGSize(width: 600, height: 68 + 1 + bodyHeight + 1 + 64)
    }

    func windowFrame(expanded: Bool, activityItemCount: Int = 4) -> CGRect {
        let size = expanded ? expandedSize(itemCount: activityItemCount) : collapsedSize
        let x: CGFloat
        let y: CGFloat
        if hasPhysicalNotch {
            x = screenFrame.midX - size.width / 2
            y = screenFrame.maxY - size.height
        } else {
            x = visibleFrame.maxX - size.width - 12
            y = visibleFrame.maxY - size.height - 8
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

final class DieterIslandPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .mainMenu + 2
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct DieterIslandThemeRoot<Content: View>: View {
    let store: DieterStore
    let content: Content

    init(store: DieterStore, @ViewBuilder content: () -> Content) {
        self.store = store
        self.content = content()
    }

    var body: some View {
        content
            .dieterThemeRoot(
                palette: store.themeSelection.palette,
                appearance: store.themeSelection.appearance
            )
            .preferredColorScheme(store.themeSelection.appearance.colorScheme)
    }
}

@MainActor
final class DieterIslandController: NSObject {
    private let store: DieterStore
    private let presentation = DieterIslandPresentation()
    private var panel: DieterIslandPanel?
    private var geometry: DieterIslandDisplayGeometry?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var closeTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var enabled = false
    private var started = false
    private let automaticHoverEnabled = !ProcessInfo.processInfo.arguments.contains("--island-ui-smoke")

    init(store: DieterStore) {
        self.store = store
    }

    var islandWindow: NSWindow? { panel }
    var isVisible: Bool { panel?.isVisible == true }
    var isExpanded: Bool { presentation.expanded }

    func start(enabled: Bool) {
        self.enabled = enabled
        guard !started else { updateVisibility(); return }
        started = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screenConfigurationChanged() }
        }
        observeActivityProjection()
        updateVisibility()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        updateVisibility()
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard enabled, let panel, let geometry, presentation.expanded != expanded else { return }
        closeTask?.cancel()
        closeTask = nil
        presentation.expanded = expanded
        panel.ignoresMouseEvents = !expanded
        let frame = targetFrame(expanded: expanded, geometry: geometry)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded ? 0.28 : 0.24
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: expanded ? 0.2 : 0.4,
                    expanded ? 0.86 : 0,
                    expanded ? 0.24 : 0.2,
                    1
                )
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func checkPointerLocation() {
        guard automaticHoverEnabled, enabled, let panel else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -5, dy: -5).contains(point) {
            closeTask?.cancel()
            closeTask = nil
            if !presentation.expanded { setExpanded(true) }
        } else if presentation.expanded, closeTask == nil {
            closeTask = Task { @MainActor [weak self] in
                try? await DieterTaskSleep.milliseconds(360)
                guard !Task.isCancelled, let self, let panel = self.panel,
                      !panel.frame.insetBy(dx: -5, dy: -5).contains(NSEvent.mouseLocation) else { return }
                self.closeTask = nil
                self.setExpanded(false)
            }
        }
    }

    private func updateVisibility() {
        guard enabled else {
            closeTask?.cancel()
            presentation.expanded = false
            removePointerMonitors()
            panel?.orderOut(nil)
            return
        }
        configurePanelIfNeeded()
        installPointerMonitors()
        panel?.orderFrontRegardless()
    }

    private func screenConfigurationChanged() {
        guard enabled else { return }
        geometry = nil
        configurePanelIfNeeded(forceLayout: true)
    }

    private func observeActivityProjection() {
        guard started else { return }
        withObservationTracking {
            _ = store.islandActivity.items.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.activityProjectionChanged() }
        }
    }

    private func activityProjectionChanged() {
        defer { observeActivityProjection() }
        guard enabled, presentation.expanded, let panel, let geometry else { return }
        let frame = targetFrame(expanded: true, geometry: geometry)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func configurePanelIfNeeded(forceLayout: Bool = false) {
        guard let screen = selectedScreen() else { return }
        let newGeometry = DieterIslandDisplayGeometry.resolve(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width
        )
        geometry = newGeometry
        presentation.hasPhysicalNotch = newGeometry.hasPhysicalNotch
        if panel == nil {
            let panel = DieterIslandPanel(frame: newGeometry.windowFrame(expanded: false))
            panel.contentView = NSHostingView(
                rootView: DieterIslandThemeRoot(store: store) {
                    DieterIslandView(
                        presentation: presentation,
                        onRequestExpansion: { [weak self] expanded in self?.setExpanded(expanded) }
                    )
                        .environment(store)
                }
            )
            panel.ignoresMouseEvents = true
            self.panel = panel
        } else {
            let frame = targetFrame(expanded: presentation.expanded, geometry: newGeometry)
            if forceLayout || panel?.frame != frame { panel?.setFrame(frame, display: true) }
        }
    }

    private func selectedScreen() -> NSScreen? {
        NSScreen.screens.first(where: { screen in
            guard screen.safeAreaInsets.top > 0,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func targetFrame(expanded: Bool, geometry: DieterIslandDisplayGeometry) -> CGRect {
        geometry.windowFrame(
            expanded: expanded,
            activityItemCount: store.islandActivity.items.count
        )
    }

    private func installPointerMonitors() {
        guard automaticHoverEnabled, globalPointerMonitor == nil, localPointerMonitor == nil else { return }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPointerLocation() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.checkPointerLocation()
            return event
        }
        checkPointerLocation()
    }

    private func removePointerMonitors() {
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        globalPointerMonitor = nil
        localPointerMonitor = nil
    }
}
