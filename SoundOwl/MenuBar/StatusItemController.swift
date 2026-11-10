import AppKit
import SwiftUI

/// The owl in the menu bar and its panel: SoundOwl's front door.
///
/// AppKit rather than `MenuBarExtra`, because the panel has to open by itself (on launch, when
/// SoundOwl is opened again) and the owl has to take dropped files.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination {
    private unowned let app: AppModel
    private let item: NSStatusItem
    private var panel: MenuPanel?
    private var hosting: NSHostingController<AnyView>?
    private var container: PanelContainer?
    /// The card's height, or where it is headed while it animates.
    private var cardTarget: CGFloat = 0
    /// Open, as far as the user is concerned (it may still be fading out).
    private var isOpen = false
    /// When the panel last closed: a click on the owl that closed it must not open it again.
    private var closedAt = Date.distantPast
    /// Each opening starts fresh: no hover left over from last time.
    private var openings = 0
    private var outsideClicks: Any?
    private var escape: Any?
    private var icon = OwlGlyph.State()

    var isShown: Bool { isOpen }

    init(app: AppModel) {
        self.app = app
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        // A name of its own: the old build's on-demand item saved itself as hidden under the
        // default one. The owl is SoundOwl's only way in, so it shows whenever SoundOwl runs.
        item.autosaveName = "SoundOwlOwl"
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            button.image = OwlGlyph.image(icon)
            button.setAccessibilityLabel("SoundOwl")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Files dragged onto the owl: the status bar window passes drags to its delegate.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        watchIcon()
    }

    // MARK: - The panel

    func show() {
        let panel = panel ?? makePanel()
        openings += 1
        hosting?.rootView = Self.content(openings)
        isOpen = true
        panel.alphaValue = 1
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        // No control starts focused: a ring on the first button reads as "press me".
        panel.makeFirstResponder(nil)
        item.button?.highlight(true)
        app.launchedForWork = false
        app.live.isWatched = true
        app.live.refresh()
        installMonitors()
    }

    func close() {
        guard let panel, isOpen else { return }
        isOpen = false
        closedAt = .now
        item.button?.highlight(false)
        app.live.isWatched = false
        app.live.expanded = nil
        removeMonitors()
        // Fades like a menu does.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    func toggle() {
        if isShown { close() } else { show() }
    }

    @objc private func clicked() {
        // Belt and braces: if something closed the panel during this very click, the click meant
        // "close" and doesn't open it again.
        if !isOpen, Date.now.timeIntervalSince(closedAt) < 0.3 { return }
        toggle()
    }

    private static func content(_ opening: Int) -> AnyView {
        AnyView(MenuBarPanel { height in AppModel.shared.menuBar.fit(height: height) }
            .environment(AppModel.shared)
            // Exactly the card's height, content pinned to its top. `minHeight: 0` matters: without
            // it the frame grows to fit taller content while the card catches up, the view is
            // centered in the card, and the top of the panel dips.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .id(opening))
    }

    /// The content's height changed: the card follows, animated with the same length and curve
    /// as the content (changes come from `withAnimation(PanelMetrics.resize)`).
    func fit(height: CGFloat) {
        guard let container, height >= 1, abs(height - cardTarget) >= 0.5 else { return }
        cardTarget = height
        if isOpen {
            container.animate(to: height)
        } else {
            container.show(height: height)
        }
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel()
        let hosting = NSHostingController(rootView: Self.content(openings))
        // SwiftUI doesn't size anything here: its own animated window resizing crashes in Auto
        // Layout with AppKit controls inside (macOS 27). The panel reports its height (`fit`).
        hosting.sizingOptions = []
        let container = PanelContainer(content: hosting.view)
        container.onOutsideClick = { AppModel.shared.menuBar.close() }
        panel.contentView = container
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting
        self.container = container
        return panel
    }

    /// Under the owl, inside the screen. The window is a column from the owl to the bottom of the
    /// screen and never resizes while open; only the card inside it does. (A window that resizes
    /// can show its old contents, bottom-aligned, for a frame: the top of the panel would twitch.)
    private func position(_ panel: MenuPanel) {
        let screen = item.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var owl = NSRect(x: screen.maxX - 200, y: screen.maxY, width: 0, height: 0)
        // The owl may be hidden (System Settings › Menu Bar, or behind the notch): then the panel
        // opens at the top right, where menu bar items are.
        if let button = item.button, let window = button.window, window.isVisible, window.screen != nil {
            owl = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        // The panel's own height, measured before it shows, so it opens at its size. (The view in
        // the window would answer "any height": it's pinned to the top of whatever it's given.)
        let size = NSHostingController(rootView: MenuBarPanel().environment(app))
            .sizeThatFits(in: NSSize(width: PanelMetrics.width, height: 10_000))
        let width = PanelMetrics.width
        let x = min(max(owl.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        let top = owl.minY - 6
        panel.setFrame(NSRect(x: x, y: screen.minY, width: width, height: max(1, top - screen.minY)), display: false)
        cardTarget = size.height
        container?.show(height: size.height)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, !isPointerOnOwl else { return }
        close()
    }

    /// A press on the owl itself: the owl's own click decides (it closes an open panel).
    private var isPointerOnOwl: Bool {
        guard NSEvent.pressedMouseButtons != 0, let button = item.button, let window = button.window else { return false }
        let owl = window.convertToScreen(button.convert(button.bounds, to: nil))
        return owl.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func installMonitors() {
        removeMonitors()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated {
                let menuBar = AppModel.shared.menuBar
                if !menuBar.isPointerOnOwl { menuBar.close() }
            }
        }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window is MenuPanel else { return event }
            MainActor.assumeIsolated { AppModel.shared.menuBar.close() }
            return nil
        }
    }

    private func removeMonitors() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let escape { NSEvent.removeMonitor(escape) }
        outsideClicks = nil
        escape = nil
    }

    // MARK: - Files dropped on the owl

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.urls(sender).isEmpty else { return [] }
        // Open the panel so the drop zone (and what happens next) can be seen.
        if !isShown { show() }
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.urls(sender)
        guard !urls.isEmpty else { return false }
        app.restore(urls)
        return true
    }

    private static func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: - The icon

    /// Redraws the owl when what it shows changes: Live restoring, files restoring.
    private func watchIcon() {
        let state = withObservationTracking {
            OwlGlyph.State(isLive: app.live.isRestoring, progress: Self.progress(app.service.jobs))
        } onChange: {
            Task { @MainActor in AppModel.shared.menuBar.watchIcon() }
        }
        guard state != icon else { return }
        icon = state
        item.button?.image = OwlGlyph.image(state)
        item.button?.setAccessibilityValue(state.isLive ? String(localized: "Live restoring") : nil)
    }

    /// Overall progress of the copies being made, nil when none are.
    private static func progress(_ jobs: [RestoreService.Job]) -> Double? {
        let active = jobs.filter { $0.previewID == nil }
        guard active.contains(where: { !$0.isFinished }) else { return nil }
        // Coarse steps keep the icon from redrawing on every chunk.
        let fraction = active.map(\.fraction).reduce(0, +) / Double(active.count)
        return (fraction * 12).rounded(.down) / 12
    }
}

/// The menu's own material with rounded corners and a hairline edge.
final class PanelBackground: NSVisualEffectView {
    private let edge = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.mask(radius: PanelMetrics.radius)
        wantsLayer = true
        edge.fillColor = nil
        edge.lineWidth = 1
        layer?.addSublayer(edge)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = bounds
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: PanelMetrics.radius - 0.5,
                           cornerHeight: PanelMetrics.radius - 0.5, transform: nil)
        edge.zPosition = 1000
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        edge.strokeColor = NSColor.separatorColor.cgColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Rounded corners for the material; stretches to any size.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The panel's window content: a transparent column holding the card at its top. Clicks in the
/// empty part close the panel, as clicking beside a menu does.
final class PanelContainer: NSView {
    var onOutsideClick: () -> Void = {}
    private let card = PanelCard()
    private let content: NSView
    private var link: CADisplayLink?
    private var animation: Resize?

    private struct Resize {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
    }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        let background = PanelBackground(frame: .zero)
        card.addSubview(background)
        card.addSubview(content)
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The card at `height`, at once.
    func show(height: CGFloat) {
        stop()
        setCard(height)
    }

    /// The card grows or shrinks to `height` over `PanelMetrics.resizeDuration`, on the same curve
    /// as SwiftUI's `.easeInOut`, one step per display refresh. The SwiftUI view inside is always
    /// the card's size; its content is pinned to the top, so only the bottom edge moves.
    func animate(to height: CGFloat) {
        // Started a frame back: the content's animation began when its layout changed, a frame
        // before the panel heard of it.
        animation = Resize(from: card.frame.height, to: height, start: CACurrentMediaTime() - 1.0 / 60)
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_: CADisplayLink) {
        guard let animation else { return }
        let t = min(1, (CACurrentMediaTime() - animation.start) / PanelMetrics.resizeDuration)
        setCard(animation.from + (animation.to - animation.from) * Self.easeInOut(t))
        guard t >= 1 else { return }
        stop()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        animation = nil
    }

    private func setCard(_ height: CGFloat) {
        let height = min(height, bounds.height)
        card.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        for view in card.subviews { view.frame = card.bounds }
        // The window's shadow follows what's drawn: the card.
        window?.invalidateShadow()
    }

    override func mouseDown(with _: NSEvent) {
        onOutsideClick()
    }

    /// cubic-bezier(0.42, 0, 0.58, 1): SwiftUI's and Core Animation's ease-in-out.
    static func easeInOut(_ x: Double) -> Double {
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<24 {
            let value = bezier(t, 0.42, 0.58)
            if abs(value - x) < 1e-5 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return bezier(t, 0, 1)
    }
}

/// The visible panel: rounded, clipping what's inside, top-down coordinates.
final class PanelCard: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PanelMetrics.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var isFlipped: Bool { true }
}

/// A borderless panel that can take key status (for the switches and Esc) without making
/// SoundOwl the active app.
final class MenuPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        identifier = NSUserInterfaceItemIdentifier("menu-bar-panel")
    }

    override var canBecomeKey: Bool { true }
}
