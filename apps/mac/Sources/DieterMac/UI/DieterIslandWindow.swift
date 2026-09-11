import AppKit
import ColorSync
import Observation
import QuartzCore
import SwiftUI

enum DieterIslandEdge: String {
    case left, right

    func pushed(horizontal: CGFloat, vertical: CGFloat) -> Self {
        guard abs(horizontal) >= 40, abs(horizontal) > abs(vertical) else { return self }
        return horizontal < 0 ? .left : .right
    }
}

struct DieterIslandDisplay: Equatable, Identifiable {
    let id: String
    let name: String
    let geometry: DieterIslandDisplayGeometry
    let isBuiltin: Bool

    static func selected(
        preferredID: String?, displays: [Self], mainDisplayID: String?
    ) -> Self? {
        displays.first { $0.id == preferredID }
            ?? displays.first { $0.isBuiltin && $0.geometry.hasPhysicalNotch }
            ?? displays.first { $0.id == mainDisplayID }
            ?? displays.first
    }

    static func containing(_ point: CGPoint, in displays: [Self]) -> Self? {
        displays.first { $0.geometry.screenFrame.contains(point) }
    }

    static func titles(for displays: [Self]) -> [String: String] {
        let counts = Dictionary(grouping: displays, by: \.name).mapValues(\.count)
        return Dictionary(
            uniqueKeysWithValues: displays.enumerated().map { index, display in
                (
                    display.id,
                    counts[display.name, default: 0] > 1 ? "\(display.name) · Display \(index + 1)" : display.name
                )
            })
    }
}

struct DieterIslandDrag {
    let displayID: String
    let frame: CGRect
    let pointer: CGPoint

    func frame(at point: CGPoint) -> CGRect {
        frame.offsetBy(dx: point.x - pointer.x, dy: point.y - pointer.y)
    }

    func translation(to point: CGPoint) -> CGSize {
        CGSize(width: point.x - pointer.x, height: pointer.y - point.y)
    }
}

/// Keep the native panel exactly as tall as the SwiftUI sections it contains.
enum DieterIslandLayout {
    static let expandedWidth: CGFloat = 600
    static let horizontalInset: CGFloat = 20
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 54
    static let separatorHeight: CGFloat = 1
    static let activityVerticalInset: CGFloat = 12
    static let activityHeadingHeight: CGFloat = 20
    static let rowHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 8
    static let emptyActivityHeight: CGFloat = 136
    static let maximumVisibleRows = 4

    static func activityHeight(itemCount: Int) -> CGFloat {
        let count = min(max(itemCount, 0), maximumVisibleRows)
        guard count > 0 else { return emptyActivityHeight }
        return activityVerticalInset * 2 + activityHeadingHeight
            + CGFloat(count) * (rowHeight + rowSpacing)
    }

    static func expandedSize(itemCount: Int) -> CGSize {
        CGSize(
            width: expandedWidth,
            height: headerHeight + footerHeight + separatorHeight * 2 + activityHeight(itemCount: itemCount)
        )
    }
}

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
        DieterIslandLayout.expandedSize(itemCount: itemCount)
    }

    func windowFrame(expanded: Bool, activityItemCount: Int = 4, edge: DieterIslandEdge = .right) -> CGRect {
        let size = expanded ? expandedSize(itemCount: activityItemCount) : collapsedSize
        let x: CGFloat
        let y: CGFloat
        if hasPhysicalNotch {
            x = screenFrame.midX - size.width / 2
            y = screenFrame.maxY - size.height
        } else {
            x = edge == .left ? visibleFrame.minX + 12 : visibleFrame.maxX - size.width - 12
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
    }
}

@MainActor
final class DieterIslandController: NSObject {
    private let store: DieterStore
    private let defaults: UserDefaults
    private let presentation = DieterIslandPresentation()
    private lazy var captureTask = CaptureTaskController(store: store)
    private var panel: DieterIslandPanel?
    private var geometry: DieterIslandDisplayGeometry?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var closeTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var edge: DieterIslandEdge
    private var dragging = false
    private var drag: DieterIslandDrag?
    private var choosingDisplay = false
    private var enabled = false
    private var started = false
    #if DIETER_UI_SMOKE
        private let automaticHoverEnabled = !ProcessInfo.processInfo.arguments.contains("--island-ui-smoke")
    #else
        private let automaticHoverEnabled = true
    #endif

    init(store: DieterStore, defaults: UserDefaults = DieterAppearance.applicationDefaults()) {
        self.store = store
        self.defaults = defaults
        edge = DieterIslandEdge(rawValue: defaults.string(forKey: "DieterIslandEdge") ?? "right") ?? .right
    }

    #if DIETER_UI_SMOKE
        func installCaptureFixture(file: URL, browser: CaptureBrowserContext) {
            captureTask.fixtureCapture = (file, browser)
        }
    #endif

    var islandWindow: NSWindow? { panel }
    var isVisible: Bool { panel?.isVisible == true }
    var isExpanded: Bool { presentation.expanded }
    var currentDisplayID: String? { presentation.currentDisplayID }
    var availableDisplays: [DieterIslandDisplay] { attachedDisplays() }

    func moveToDisplay(_ id: String?) {
        guard id == nil || attachedDisplays().contains(where: { $0.id == id }) else { return }
        DieterIslandPreferences.setDisplayID(id, in: defaults)
        cancelDrag()
        closeTask?.cancel()
        closeTask = nil
        configurePanelIfNeeded(forceLayout: true)
    }

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
        cancelDrag()
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
        guard automaticHoverEnabled, enabled, !dragging, !choosingDisplay, let panel else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -5, dy: -5).contains(point) {
            closeTask?.cancel()
            closeTask = nil
            if !presentation.expanded { setExpanded(true) }
        } else if presentation.expanded, closeTask == nil {
            closeTask = Task { @MainActor [weak self] in
                try? await DieterTaskSleep.milliseconds(360)
                guard !Task.isCancelled, let self, let panel = self.panel,
                    !panel.frame.insetBy(dx: -5, dy: -5).contains(NSEvent.mouseLocation)
                else { return }
                self.closeTask = nil
                self.setExpanded(false)
            }
        }
    }

    private func updateVisibility() {
        guard !captureTask.capturing else { return }
        guard enabled else {
            closeTask?.cancel()
            cancelDrag()
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
        cancelDrag()
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
        guard enabled, !dragging, presentation.expanded, let panel, let geometry else { return }
        let frame = targetFrame(expanded: true, geometry: geometry)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func configurePanelIfNeeded(forceLayout: Bool = false) {
        let displays = attachedDisplays()
        let preferredID = DieterIslandPreferences.displayID(in: defaults)
        guard
            let display = DieterIslandDisplay.selected(
                preferredID: preferredID, displays: displays, mainDisplayID: NSScreen.main.flatMap(displayID)
            )
        else { return }
        let newGeometry = display.geometry
        geometry = newGeometry
        presentation.hasPhysicalNotch = newGeometry.hasPhysicalNotch
        presentation.displays = displays
        presentation.preferredDisplayID = preferredID
        presentation.currentDisplayID = display.id
        if panel == nil {
            let panel = DieterIslandPanel(frame: newGeometry.windowFrame(expanded: false, edge: edge))
            panel.contentView = NSHostingView(
                rootView: DieterIslandThemeRoot(store: store) {
                    DieterIslandView(
                        presentation: presentation,
                        onRequestExpansion: { [weak self] expanded in self?.setExpanded(expanded) },
                        onDragChanged: { [weak self] translation in self?.dragIsland(translation) },
                        onDragEnded: { [weak self] in self?.finishDrag() },
                        onSelectDisplay: { [weak self] id in self?.moveToDisplay(id) },
                        onDisplayPickerChanged: { [weak self] presented in
                            guard let self else { return }
                            self.choosingDisplay = presented
                            self.closeTask?.cancel()
                            self.closeTask = nil
                            if !presented { self.checkPointerLocation() }
                        },
                        onCaptureTask: { [weak self] in
                            guard let self else { return }
                            self.captureTask.capture(
                                hideIsland: {
                                    self.cancelDrag()
                                    self.closeTask?.cancel()
                                    self.removePointerMonitors()
                                    self.panel?.orderOut(nil)
                                },
                                restoreIsland: { [weak self] in
                                    self?.setExpanded(false, animated: false)
                                    self?.updateVisibility()
                                })
                        }
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

    private func displayID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func attachedDisplays() -> [DieterIslandDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(screen),
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return DieterIslandDisplay(
                id: id, name: screen.localizedName,
                geometry: .resolve(
                    screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                    safeAreaTop: screen.safeAreaInsets.top,
                    auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
                    auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width
                ),
                isBuiltin: CGDisplayIsBuiltin(number) != 0
            )
        }
    }

    private func targetFrame(expanded: Bool, geometry: DieterIslandDisplayGeometry) -> CGRect {
        geometry.windowFrame(
            expanded: expanded,
            activityItemCount: store.islandActivity.items.count, edge: edge
        )
    }

    private func dragIsland(_ translation: CGSize) {
        guard enabled, !choosingDisplay, let panel, let displayID = presentation.currentDisplayID else { return }
        let point = NSEvent.mouseLocation
        if drag == nil {
            drag = DieterIslandDrag(
                displayID: displayID, frame: panel.frame,
                pointer: CGPoint(x: point.x - translation.width, y: point.y + translation.height)
            )
            dragging = true
            closeTask?.cancel()
            closeTask = nil
        }
        if let drag { panel.setFrameOrigin(drag.frame(at: point).origin) }
    }

    private func finishDrag() {
        guard let drag, let panel else { return }
        let point = NSEvent.mouseLocation
        let translation = drag.translation(to: point)
        cancelDrag()
        if let destination = DieterIslandDisplay.containing(point, in: attachedDisplays()),
            destination.id != drag.displayID
        {
            edge = point.x < destination.geometry.screenFrame.midX ? .left : .right
            defaults.set(edge.rawValue, forKey: "DieterIslandEdge")
            presentation.expanded = false
            panel.ignoresMouseEvents = true
            moveToDisplay(destination.id)
        } else if let geometry, geometry.hasPhysicalNotch {
            panel.setFrame(targetFrame(expanded: presentation.expanded, geometry: geometry), display: true)
            checkPointerLocation()
        } else {
            pushIsland(translation)
        }
    }

    private func cancelDrag() {
        drag = nil
        dragging = false
    }

    private func pushIsland(_ translation: CGSize) {
        dragging = false
        guard let geometry, !geometry.hasPhysicalNotch, let panel else { return }
        let destination = edge.pushed(horizontal: translation.width, vertical: translation.height)
        guard destination != edge else {
            panel.setFrame(targetFrame(expanded: presentation.expanded, geometry: geometry), display: true)
            checkPointerLocation()
            return
        }
        edge = destination
        defaults.set(edge.rawValue, forKey: "DieterIslandEdge")
        closeTask?.cancel()
        closeTask = nil
        presentation.expanded = false
        panel.ignoresMouseEvents = true
        let frame = targetFrame(expanded: false, geometry: geometry)
        dragging = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.drag == nil else { return }
                self.dragging = false
            }
        }
    }

    private func installPointerMonitors() {
        guard automaticHoverEnabled, globalPointerMonitor == nil, localPointerMonitor == nil else { return }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPointerLocation() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) {
            [weak self] event in
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
