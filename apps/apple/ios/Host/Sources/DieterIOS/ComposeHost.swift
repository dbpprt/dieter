import DieterCore
import DieterIdentity
import DieterPlatform
import Foundation
import Metal
import UIKit

/// Hosts the shared Compose UI with the Apple platform adapters the Mac app also uses.
@MainActor
public final class ComposeHost {
    private let shared: DieterShared
    private let mobile: MobileHost
    public let rootController: ShellController
    private var observation: MobileObservation?

    public init(version: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Dieter/core", directoryHint: .isDirectory)
        let media = CoreScreenMedia {
            MTLCreateSystemDefaultDevice() == nil ? "Metal is unavailable on this device." : nil
        }
        // This install's roster key: in the Secure Enclave where the device has
        // one (never on a simulator), kept in a device-only Keychain item.
        let deviceKeys = CoreDeviceKeys(store: DeviceKeyKeychain(), platform: "ios", deviceName: UIDevice.current.name)
        shared = DieterShared(
            configuration: SharedConfiguration(
                stateDirectory: directory.path, clientVersion: version,
                oauthRedirectUri: "\(DistributionIdentity.iosURLScheme)://oauth/callback", clientIdPrefix: "ios",
                includeLoopbackRoutes: false, compactTranscripts: true,
                screenClientName: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                desktopScreens: false),
            extensions: SharedExtensions(
                rpc: CoreRpcBridge(deviceKeys: deviceKeys), tunnels: CoreRelayTunnels(), deviceKeys: deviceKeys,
                secureStore: CoreKeychainSecureStore(),
                settings: CoreDefaultsSettings(defaults: .standard), http: CoreURLSessionHttp(),
                signatures: CoreCryptoKitSignatures(),
                logger: CoreOSLogger(subsystem: DistributionIdentity.iosBundleID), notifications: nil,
                controlChannels: CoreControlChannels(),
                screenMedia: media, clipboard: CoreUIPasteboardClipboard(), screenFixture: nil))
        mobile = MobileHost(shared: shared, nativeViews: ComposeNativeViews(media: media))
        rootController = ShellController(host: mobile)
        observation = mobile.observeNavigation(
            observer: NavigationObserver { [weak rootController] navigation in rootController?.apply(navigation) })
        shared.start()
    }
    public func completeSignIn(url: String) { mobile.completeSignIn(url: url) }
    public func reconnect() { mobile.reconnect() }
    public func setForeground(_ active: Bool) {
        mobile.setForeground(active: active)
        if active { receiveShare() }
    }
    /// Items the share extension staged reach the shared UI when the app becomes active.
    private func receiveShare() {
        guard let container = ShareInbox.container(), let request = ShareInbox.pendingRequest(in: container)
        else { return }
        let staged = ShareInbox.consume(request, in: container)
        mobile.share(message: staged.message, destination: request.destination, problem: staged.problem)
    }
    /// Debug builds: the isolated E2E gateway's session and the pairing code its machine approves.
    public func adoptFixture(url: String, token: String, pairingCode: String) {
        mobile.adoptFixture(url: url, token: token, pairingCode: pairingCode)
    }
    /// Debug builds: replays shared navigation steps for screenshots.
    public func runDebugScript(_ script: String) { mobile.runDebugScript(script: script) }
    public func close() { observation?.close(); mobile.close() }
}

private final class NavigationObserver: NSObject, MobileNavigationObserver, Sendable {
    private let update: @MainActor @Sendable (NativeNavigation) -> Void
    init(_ update: @escaping @MainActor @Sendable (NativeNavigation) -> Void) { self.update = update }
    func changed(navigation: NativeNavigation) {
        // Kotlin delivers navigation on the main thread; the snapshot is immutable.
        nonisolated(unsafe) let snapshot = navigation
        MainActor.assumeIsolated { update(snapshot) }
    }
}

/// Native tab bar, navigation stacks and modal presentation driven by the shared navigation state.
/// Each route is a Compose view controller; its bar contents come from the shared screen chrome.
/// Regular width gives every tab a split view: lists on the left, conversations and tools beside them.
@MainActor
public final class ShellController: UIViewController, UINavigationControllerDelegate, UITabBarControllerDelegate,
    UITabBarController.Sidebar.Delegate, UIAdaptivePresentationControllerDelegate
{
    private let host: MobileHost
    private let tabs = UITabBarController()
    private var containers: [TabContainer] = []
    private var signIn: UIViewController?
    private var modal: UINavigationController?
    private var modalKey: String?
    private var current: NativeNavigation?
    private var applying = false
    /// The shared visible tabs' IDs, in order; the tab bar is rebuilt only when they change.
    private var tabIDs: [String] = []

    init(host: MobileHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        tabs.mode = .tabSidebar
        tabs.delegate = self
        tabs.sidebar.delegate = self
        tabs.view.accessibilityIdentifier = "shell-tabs"
        embed(tabs)
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _: UITraitCollection) in
            self.layoutChanged()
        }
        layoutChanged()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let current {
            applyAppearance(current.appearance)
            view.window?.tintColor = Self.tint(current.accent)
        }
    }

    private var regular: Bool { traitCollection.horizontalSizeClass == .regular }

    private func layoutChanged() {
        applying = true
        for container in containers { container.configure(regular: regular) }
        applying = false
        if let current { apply(current) }
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    /// Shows [shown] in the shared order. Tabs that stay keep their container, stack and UITab;
    /// a tab that goes takes its stack with it. Every layout shows the same four tabs, so UIKit's
    /// own More list never appears and tab indices always match the shared ones.
    private func rebuildTabs(_ shown: [NativeTab]) {
        let ids = shown.map(\.key)
        guard ids != tabIDs else { return }
        let existing = Dictionary(uniqueKeysWithValues: zip(tabIDs, zip(containers, tabs.tabs)))
        var nextContainers: [TabContainer] = []
        var nextTabs: [UITab] = []
        for (index, tab) in shown.enumerated() {
            if case let (container, item)? = existing[tab.key] {
                container.index = index
                nextContainers.append(container)
                nextTabs.append(item)
                continue
            }
            let container = TabContainer(index: index, delegate: self)
            container.settle = { [weak self] in self?.resync() }
            container.configure(regular: regular)
            let item = UITab(title: tab.title, image: UIImage(systemName: tab.symbol), identifier: "tab-\(tab.key)") {
                _ in container
            }
            nextContainers.append(container)
            nextTabs.append(item)
        }
        containers = nextContainers
        tabIDs = ids
        tabs.tabs = nextTabs
    }

    /// Inbox attention; More counts unread mail and channel messages.
    private static func badge(_ id: String, _ navigation: NativeNavigation) -> String? {
        switch id {
        case "inbox": navigation.attention > 0 ? "\(navigation.attention)" : nil
        case "more": navigation.moreUnread.isEmpty ? nil : navigation.moreUnread
        default: nil
        }
    }

    private func remove(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }

    func apply(_ navigation: NativeNavigation) {
        loadViewIfNeeded()
        current = navigation
        applyAppearance(navigation.appearance)
        view.window?.tintColor = Self.tint(navigation.accent)
        if !navigation.signedIn {
            if signIn == nil {
                let controller = host.signInController()
                signIn = controller
                embed(controller)
            }
            return
        } else if let controller = signIn {
            remove(controller)
            signIn = nil
        }
        applying = true
        rebuildTabs(navigation.tabs)
        let selected = Int(navigation.tab)
        let visible = tabs.tabs.firstIndex { $0 == tabs.selectedTab } ?? 0
        for (index, stack) in navigation.stacks.enumerated() where index < containers.count {
            containers[index].sync(
                routes: stack, host: host, animated: index == selected && index == visible && view.window != nil)
        }
        if visible != selected, selected < tabs.tabs.count { tabs.selectedTab = tabs.tabs[selected] }
        for (id, tab) in zip(tabIDs, tabs.tabs) {
            let badge = Self.badge(id, navigation)
            if tab.badgeValue != badge { tab.badgeValue = badge }
        }
        if selected < containers.count {
            updateTabBar(for: containers[selected].visibleController, animated: view.window != nil)
        }
        applying = false
        syncModal(navigation.modal)
    }

    /// Monochrome follows the label color, as the Dieter brand does on every platform.
    static func tint(_ accent: Int64) -> UIColor {
        guard accent != 0 else { return .label }
        let value = UInt32(truncatingIfNeeded: accent)
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private func applyAppearance(_ appearance: String) {
        let style: UIUserInterfaceStyle =
            appearance == "dark" ? .dark : appearance == "light" ? .light : .unspecified
        if view.window?.overrideUserInterfaceStyle != style { view.window?.overrideUserInterfaceStyle = style }
    }

    private func syncModal(_ route: MobileRouteHandle?) {
        guard let route else {
            if let modal {
                self.modal = nil
                modalKey = nil
                modal.dismiss(animated: true)
            }
            return
        }
        guard route.key != modalKey else { return }
        modal?.dismiss(animated: false)
        let controller = UINavigationController(rootViewController: RouteController(host: host, route: route))
        controller.modalPresentationStyle = regular ? .formSheet : .pageSheet
        controller.presentationController?.delegate = self
        modal = controller
        modalKey = route.key
        topPresenter.present(controller, animated: true)
    }

    private var topPresenter: UIViewController {
        var controller: UIViewController = self
        while let next = controller.presentedViewController, next !== modal { controller = next }
        return controller
    }

    // MARK: Native navigation reports back to the shared state.

    /// Conversations, terminals and screens use the full height on phones, as Messages does.
    private func updateTabBar(for controller: UIViewController?, animated: Bool) {
        let immersive = !regular && ((controller as? RouteController)?.immersive ?? false)
        if tabs.isTabBarHidden != immersive { tabs.setTabBarHidden(immersive, animated: animated) }
    }

    public func navigationController(
        _ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool
    ) {
        let selected = tabs.tabs.firstIndex { $0 == tabs.selectedTab } ?? 0
        guard selected < containers.count, containers[selected].owns(navigationController) else { return }
        updateTabBar(for: viewController, animated: animated)
    }

    public func navigationController(
        _ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool
    ) {
        guard !applying else { return }
        for container in containers {
            if let depth = container.poppedDepth(navigationController) {
                host.popTo(tab: Int32(container.index), depth: Int32(depth))
                break
            }
        }
        resync()
    }

    /// Applies changes that arrived while a stack was animating, now that pops are recorded.
    private func resync() {
        guard containers.contains(where: { $0.deferred }) else { return }
        containers.forEach { $0.deferred = false }
        apply(host.navigation())
    }

    /// Monochrome tints with the label color, which would put white text on a white pill in dark mode.
    /// The transformer resolves against the live tint and traits, so it never needs reconfiguring.
    public func tabBarController(
        _ tabBarController: UITabBarController, sidebar: UITabBarController.Sidebar, update item: UITabSidebarItem
    ) {
        var background = item.defaultBackgroundConfiguration()
        background.backgroundColorTransformer = UIConfigurationColorTransformer { color in
            UIColor { traits in
                let resolved = color.resolvedColor(with: traits)
                var white: CGFloat = 0
                var alpha: CGFloat = 0
                guard traits.userInterfaceStyle == .dark, resolved.getWhite(&white, alpha: &alpha),
                    white > 0.9, alpha > 0.9
                else { return resolved }
                return UIColor(white: 1, alpha: 0.18)
            }
        }
        item.backgroundConfiguration = background
    }

    /// Tapping the selected tab again returns it to its first page, as the system apps do; More
    /// then shows its list of places again.
    public func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if !applying, tab == tabBarController.selectedTab, let index = tabs.tabs.firstIndex(of: tab) {
            host.selectTab(index: Int32(index))
        }
        return true
    }

    public func tabBarController(
        _ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?
    ) {
        guard !applying, let index = tabs.tabs.firstIndex(of: selectedTab) else { return }
        if selectedTab != previousTab { host.selectTab(index: Int32(index)) }
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        modal = nil
        modalKey = nil
        host.dismissModal()
    }
}

/// One tab's content: a navigation stack, or on regular width a list column beside a detail column.
@MainActor
final class TabContainer: UIViewController {
    /// The tab's position among the visible tabs; it moves when a tab before it shows or hides.
    var index: Int
    private weak var delegate: (any UINavigationControllerDelegate)?
    private var navigators: [UINavigationController] = []
    private var keys: [[String]] = []
    private var split: UISplitViewController?
    private let placeholder = PlaceholderController()
    /// The list the placeholder last described; its wording follows the list beside it.
    private var placeholderList: String?
    /// Set when a change waited for a transition; `settle` reapplies the latest navigation.
    var deferred = false
    var settle: (() -> Void)?
    private(set) var regular = false
    private var configured = false

    init(index: Int, delegate: any UINavigationControllerDelegate) {
        self.index = index
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    func configure(regular: Bool) {
        guard !configured || regular != self.regular else { return }
        configured = true
        self.regular = regular
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        split = nil
        let count = regular ? 2 : 1
        navigators = (0..<count).map { _ in
            let navigator = UINavigationController()
            navigator.delegate = delegate
            return navigator
        }
        keys = Array(repeating: [], count: count)
        let content: UIViewController
        if regular {
            let split = UISplitViewController(style: .doubleColumn)
            split.preferredDisplayMode = .oneBesideSecondary
            split.preferredSplitBehavior = .tile
            split.presentsWithGesture = false
            split.minimumPrimaryColumnWidth = 340
            split.maximumPrimaryColumnWidth = 440
            split.preferredPrimaryColumnWidthFraction = 0.4
            split.setViewController(navigators[0], for: .primary)
            split.setViewController(navigators[1], for: .secondary)
            navigators[1].setViewControllers([placeholder], animated: false)
            self.split = split
            content = split
        } else {
            content = navigators[0]
        }
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    func sync(routes: [MobileRouteHandle], host: MobileHost, animated: Bool) {
        loadViewIfNeeded()
        // Routes that list things stay in the primary column on regular width.
        let boundary = routes.lastIndex { $0.list } ?? 0
        let list = routes.indices.contains(boundary) ? routes[boundary].key : ""
        if placeholderList != list {
            placeholder.show(host.emptyDetail(tab: Int32(index)))
            placeholderList = list
        }
        if !regular {
            sync(0, routes: routes, host: host, animated: animated)
            return
        }
        sync(0, routes: Array(routes[...boundary]), host: host, animated: animated)
        sync(1, routes: Array(routes[(boundary + 1)...]), host: host, animated: animated)
    }

    private func sync(_ column: Int, routes: [MobileRouteHandle], host: MobileHost, animated: Bool) {
        let navigator = navigators[column]
        // The store learns about a pop only when it lands; syncing mid-transition would push it back.
        if let coordinator = navigator.transitionCoordinator {
            deferred = true
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if context.isCancelled {
                    self?.settle?()
                } else {
                    // Nothing else may follow to apply the change that waited for this transition.
                    // Pops are recorded by then; `settle` only acts while a change is deferred.
                    DispatchQueue.main.async { self?.settle?() }
                }
            }
            return
        }
        let desired = routes.map(\.key)
        let existing = keys[column]
        let controllers = navigator.viewControllers.compactMap { $0 as? RouteController }
        if desired == existing && controllers.count == desired.count { return }
        var prefix = 0
        while prefix < min(desired.count, existing.count, controllers.count), desired[prefix] == existing[prefix] {
            prefix += 1
        }
        var next: [UIViewController] = Array(controllers.prefix(prefix))
        for route in routes.dropFirst(prefix) { next.append(RouteController(host: host, route: route)) }
        if column == 1 {
            // Detail routes start their own stack; the first one has no back button.
            next.first?.navigationItem.hidesBackButton = true
            if next.isEmpty { next = [placeholder] }
        }
        keys[column] = desired
        navigator.setViewControllers(next, animated: animated && !(column == 1 && prefix == 0))
    }

    func owns(_ navigator: UINavigationController) -> Bool { navigators.contains(navigator) }

    var visibleController: UIViewController? { navigators.last?.topViewController }

    /// The remaining shared stack depth after a native pop in one of this tab's columns.
    func poppedDepth(_ navigator: UINavigationController) -> Int? {
        guard let column = navigators.firstIndex(of: navigator) else { return nil }
        let depth = navigator.viewControllers.compactMap { $0 as? RouteController }.count
        guard depth < keys[column].count else { return nil }
        keys[column] = Array(keys[column].prefix(depth))
        if column == 0 { return max(depth, 1) }
        return keys[0].count + depth
    }
}

/// The empty detail column on iPad; its wording comes from the shared tab.
@MainActor
final class PlaceholderController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
    }

    func show(_ detail: NativeEmptyDetail) {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: detail.symbol)
        configuration.text = detail.title
        configuration.secondaryText = detail.message
        contentUnavailableConfiguration = configuration
    }
}

/// Hosts one Compose route and applies its chrome to the navigation item.
@MainActor
final class RouteController: UIViewController {
    let key: String
    let immersive: Bool
    private let content: UIViewController
    private let chrome: RouteChrome

    init(host: MobileHost, route: MobileRouteHandle) {
        key = route.key
        immersive = route.immersive
        chrome = RouteChrome()
        content = host.controller(route: route, chrome: chrome)
        super.init(nibName: nil, bundle: nil)
        chrome.item = navigationItem
        chrome.bar = { [weak self] in self?.navigationController?.navigationBar }
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .never
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
        view.accessibilityIdentifier = "route-\(key)"
    }
}

/// Builds bar buttons and menus from the shared chrome description.
@MainActor
final class RouteChrome: NSObject, @preconcurrency NativeChromeSink {
    weak var item: UINavigationItem?
    var bar: () -> UINavigationBar? = { nil }
    private var title = ""
    private var large = false
    private var collapsed = true

    func apply(chrome: NativeChrome) {
        guard let item else { return }
        title = chrome.title
        large = chrome.large
        updateTitle(animated: false)
        if #available(iOS 26.0, *) {
            item.subtitle = chrome.large || chrome.subtitle.isEmpty ? nil : chrome.subtitle
        } else {
            item.prompt = nil
        }
        var right: [UIBarButtonItem] = []
        if let confirm = chrome.confirm { right.append(Self.confirmItem(confirm)) }
        if let primary = chrome.primary {
            right.append(Self.barItem(primary))
            if !chrome.actions.isEmpty { right.append(.fixedSpace(0)) }
        }
        right.append(contentsOf: chrome.actions.reversed().map(Self.barItem))
        item.setRightBarButtonItems(right, animated: false)
        if let cancel = chrome.cancel {
            let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in cancel.perform() })
            close.accessibilityIdentifier = "chrome-\(cancel.identifier)"
            item.leftBarButtonItems = [close]
        } else {
            item.leftBarButtonItems = nil
        }
    }

    func setTitleCollapsed(collapsed: Bool) {
        self.collapsed = collapsed
        updateTitle(animated: true)
    }

    private func updateTitle(animated: Bool) {
        let shown = !large || collapsed ? title : ""
        guard item?.title != shown else { return }
        if animated, let bar = bar() {
            UIView.transition(with: bar, duration: 0.18, options: .transitionCrossDissolve) { self.item?.title = shown }
        } else {
            item?.title = shown
        }
    }

    static func symbol(_ name: String) -> UIImage? { name.isEmpty ? nil : UIImage(systemName: name) }

    static func barItem(_ action: NativeAction) -> UIBarButtonItem {
        let item: UIBarButtonItem
        if !action.sections.isEmpty {
            item = UIBarButtonItem(
                title: action.title, image: symbol(action.symbol), primaryAction: nil, menu: menu(action.sections))
        } else {
            item = UIBarButtonItem(
                title: action.title, image: symbol(action.symbol),
                primaryAction: UIAction(title: action.title) { _ in action.perform() }, menu: nil)
        }
        item.isEnabled = action.enabled
        item.accessibilityLabel = action.title
        item.accessibilityIdentifier = "chrome-\(action.identifier)"
        return item
    }

    static func confirmItem(_ action: NativeAction) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: action.title, image: symbol(action.symbol),
            primaryAction: UIAction(title: action.title) { _ in action.perform() }, menu: nil)
        if #available(iOS 26.0, *) { item.style = .prominent } else { item.style = .done }
        item.isEnabled = action.enabled
        item.accessibilityLabel = action.title
        item.accessibilityIdentifier = "chrome-\(action.identifier)"
        return item
    }

    static func menu(_ sections: [NativeMenuSection]) -> UIMenu {
        UIMenu(
            children: sections.map { section in
                let children = section.actions.map(Self.element)
                if section.inline_ || section.title.isEmpty {
                    return UIMenu(title: section.title, options: .displayInline, children: children)
                }
                return UIMenu(title: section.title, image: symbol(section.symbol), children: children)
            })
    }

    static func element(_ action: NativeAction) -> UIMenuElement {
        if !action.sections.isEmpty {
            return UIMenu(
                title: action.title, subtitle: action.subtitle.isEmpty ? nil : action.subtitle,
                image: symbol(action.symbol),
                children: action.sections.map { section in
                    UIMenu(title: section.title, options: .displayInline, children: section.actions.map(Self.element))
                })
        }
        var attributes: UIMenuElement.Attributes = []
        if action.destructive { attributes.insert(.destructive) }
        if !action.enabled { attributes.insert(.disabled) }
        let leaf = UIAction(
            title: action.title, subtitle: action.subtitle.isEmpty ? nil : action.subtitle,
            image: symbol(action.symbol), identifier: UIAction.Identifier(action.identifier), attributes: attributes,
            state: action.checked ? .on : .off
        ) { _ in action.perform() }
        leaf.accessibilityIdentifier = "menu-\(action.identifier)"
        return leaf
    }
}
