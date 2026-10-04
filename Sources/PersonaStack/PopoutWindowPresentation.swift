import AppKit
import WebKit

enum PopoutWindowKind: String, CaseIterable {
    case chat, stackStream, personaActivity, stackGraph

    var usesTitlebarAccessory: Bool { self == .chat || self == .stackGraph }

    var fallbackTitle: String {
        switch self {
        case .chat: "Persona Chat"
        case .stackStream: "Stack Stream"
        case .personaActivity: "Live Console"
        case .stackGraph: "Stack Graph"
        }
    }
}

/// Only three local frame records; never keyed by a hosted identity or URL.
struct PopoutGeometryStore {
    let defaults: UserDefaults
    static func key(_ kind: PopoutWindowKind) -> String { "popout.expandedFrame.\(kind.rawValue)" }

    func read(_ kind: PopoutWindowKind) -> NSRect? {
        guard kind != .stackGraph else { return nil }
        guard let values = defaults.array(forKey: Self.key(kind)) as? [Double], values.count == 4 else { return nil }
        let frame = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        return Self.valid(frame) ? frame : nil
    }

    func save(_ frame: NSRect, kind: PopoutWindowKind, collapsed: Bool, fullscreen: Bool) {
        guard kind != .stackGraph, !collapsed, !fullscreen, Self.valid(frame) else { return }
        defaults.set([frame.minX, frame.minY, frame.width, frame.height], forKey: Self.key(kind))
    }

    static func valid(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
            && abs(frame.minX) <= 100_000 && abs(frame.minY) <= 100_000
            && frame.width >= 200 && frame.height >= 200 && frame.width <= 16_384 && frame.height <= 16_384
    }

    static func clamp(_ frame: NSRect, screens: [NSRect], minimum: NSSize) -> NSRect {
        guard let screen = screens.max(by: { area(frame.intersection($0)) < area(frame.intersection($1)) }) else { return frame }
        let size = NSSize(width: min(screen.width, max(minimum.width, frame.width)),
                          height: min(screen.height, max(minimum.height, frame.height)))
        return NSRect(x: max(screen.minX, min(frame.minX, screen.maxX - size.width)),
                      y: max(screen.minY, min(frame.minY, screen.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

/// A native single-row toolbar, above the ordinary WebView content rect.
@MainActor
final class PopoutWindowPresentation: NSObject, NSToolbarDelegate {
    static let capabilityScript = "window.personastackNativeWindowChrome = true;"
    static let backgroundColor = NSColor(srgbRed: 18.0 / 255, green: 18.0 / 255, blue: 42.0 / 255, alpha: 1)
    private static let pinIdentifier = NSToolbarItem.Identifier("popout.pin")
    let toolbar = NSToolbar(identifier: "PersonaStack.Popout")
    let pinButton = NSButton()
    private let pinAccessory = NSTitlebarAccessoryViewController()
    private var pinAccessoryConstraints: [NSLayoutConstraint] = []
    private(set) var graphOverlay: GraphPinOverlayView?
    private var graphStyle: NSWindow.StyleMask = []
    private let window: NSWindow
    private let kind: PopoutWindowKind
    private let geometry: PopoutGeometryStore
    private var titleObservation: NSKeyValueObservation?
    private var collapsed = false
    private var resizingPresentation = false
    private var fullscreenTransition = false
    private var invalidated = false

    static func advertise(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: capabilityScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    init(window: NSWindow, webView: WKWebView, kind: PopoutWindowKind, defaults: UserDefaults = .standard) {
        self.window = window
        self.kind = kind
        geometry = PopoutGeometryStore(defaults: defaults)
        super.init()
        window.styleMask.remove(.fullSizeContentView)
        window.title = kind.fallbackTitle
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        // Hosted pop-outs use a dark canvas independently of the system theme.
        // Keep native active/inactive toolbar materials in that same appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.toolbarStyle = kind.usesTitlebarAccessory ? .automatic : .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isOpaque = true
        window.backgroundColor = Self.backgroundColor
        window.hasShadow = true
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        pinButton.setButtonType(.toggle)
        pinButton.bezelStyle = kind.usesTitlebarAccessory ? .accessoryBarAction : .texturedRounded
        if kind.usesTitlebarAccessory { pinButton.controlSize = .small }
        pinButton.imagePosition = .imageOnly
        pinButton.setAccessibilityLabel("Always on top")
        pinButton.toolTip = "Always on top"
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        setPinned(false)
        pinButton.sizeToFit()
        if kind.usesTitlebarAccessory {
            let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 24))
            pinButton.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.addSubview(pinButton)
            pinAccessoryConstraints = [
                pinButton.centerXAnchor.constraint(equalTo: accessoryView.centerXAnchor),
                pinButton.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
                pinButton.widthAnchor.constraint(equalToConstant: 24),
                pinButton.heightAnchor.constraint(equalToConstant: 24),
            ]
            NSLayoutConstraint.activate(pinAccessoryConstraints)
            pinAccessory.view = accessoryView
            pinAccessory.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(pinAccessory)
        } else {
            window.toolbar = toolbar
        }
        if kind == .stackGraph { installGraphOverlay(webView: webView) }
        window.center()
        let initialFrame = geometry.read(kind) ?? window.frame
        window.setFrame(PopoutGeometryStore.clamp(initialFrame, screens: NSScreen.screens.map(\.visibleFrame), minimum: window.minSize), display: false)
        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.updateTitle(view.title) }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(recordGeometry), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterFullscreen), name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(willExitFullscreen), name: NSWindow.willExitFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(didExitFullscreen), name: NSWindow.didExitFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterFullscreen), name: NSWindow.didEnterFullScreenNotification, object: window)
    }

    func updateTitle(_ title: String?) {
        guard !invalidated else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        window.title = !trimmed.isEmpty && trimmed.utf8.count <= 1024
            && trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            ? trimmed : kind.fallbackTitle
    }

    var canCollapse: Bool { !fullscreenTransition && !window.styleMask.contains(.fullScreen) }

    func setCollapsed(_ value: Bool) {
        if value { recordGeometry() }
        resizingPresentation = true
        collapsed = value
        var behavior = window.collectionBehavior
        behavior.remove([.fullScreenPrimary, .fullScreenNone])
        behavior.insert(value ? .fullScreenNone : .fullScreenPrimary)
        window.collectionBehavior = behavior
        if kind == .chat {
            if value {
                if let index = window.titlebarAccessoryViewControllers.firstIndex(of: pinAccessory) {
                    window.removeTitlebarAccessoryViewController(at: index)
                }
            } else if !window.titlebarAccessoryViewControllers.contains(pinAccessory) {
                window.addTitlebarAccessoryViewController(pinAccessory)
            }
        } else {
            window.toolbar = value ? nil : toolbar
        }
    }

    func finishResize() {
        resizingPresentation = false
        recordGeometry()
    }

    @objc func recordGeometry() {
        guard !invalidated, !resizingPresentation else { return }
        geometry.save(window.frame, kind: kind, collapsed: collapsed,
                      fullscreen: fullscreenTransition || window.styleMask.contains(.fullScreen))
    }

    @objc func willEnterFullscreen() { recordGeometry(); fullscreenTransition = true; updatePinAvailability() }
    @objc func willExitFullscreen() { fullscreenTransition = true; updatePinAvailability() }
    @objc func didEnterFullscreen() { fullscreenTransition = false; updatePinAvailability() }
    @objc func didExitFullscreen() { fullscreenTransition = false; updatePinAvailability() }

    func fullscreenTransitionFailed() {
        fullscreenTransition = false
        updatePinAvailability()
        recordGeometry()
    }

    func invalidate() {
        guard !invalidated else { return }
        recordGeometry()
        invalidated = true
        titleObservation = nil
        graphOverlay?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func togglePin() {
        guard !invalidated, kind != .stackGraph || canCollapse else { return }
        setPinned(window.level != .floating)
        if kind == .stackGraph { setGraphPinned(window.level == .floating) }
    }

    private func setPinned(_ pinned: Bool) {
        window.level = pinned ? .floating : .normal
        pinButton.state = pinned ? .on : .off
        let image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.image = kind.usesTitlebarAccessory
            ? image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular, scale: .small))
            : image
        pinButton.setAccessibilityValue(pinned ? 1 : 0)
        if kind == .stackGraph {
            let label = pinned ? "Unpin graph" : "Pin graph"
            pinButton.setAccessibilityLabel(label)
            pinButton.toolTip = label
        }
    }

    private func updatePinAvailability() {
        if kind == .stackGraph { pinButton.isEnabled = canCollapse }
    }

    private func installGraphOverlay(webView: WKWebView) {
        graphStyle = window.styleMask
        let host = NSView(frame: webView.frame)
        let overlay = GraphPinOverlayView(frame: webView.bounds)
        window.contentView = host
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        overlay.pinButton = pinButton
        overlay.onHover = { [weak self] inside in
            guard let self, !self.invalidated, self.window.level == .floating else { return }
            self.pinButton.isHidden = !inside
        }
        host.addSubview(overlay)
        graphOverlay = overlay
    }

    private func setGraphPinned(_ pinned: Bool) {
        guard let overlay = graphOverlay else { return }
        let contentRect = window.convertToScreen(window.contentLayoutRect)
        let minimum = window.contentRect(forFrameRect: NSRect(origin: .zero, size: window.minSize)).size
        if pinned {
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: pinAccessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            NSLayoutConstraint.deactivate(pinAccessoryConstraints)
        }
        pinButton.removeFromSuperview()
        window.styleMask = pinned ? [.borderless, .resizable] : graphStyle
        window.isOpaque = !pinned
        window.backgroundColor = pinned ? .clear : Self.backgroundColor
        window.hasShadow = !pinned
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenNone])
        window.collectionBehavior.insert(pinned ? .fullScreenNone : .fullScreenPrimary)
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
        if pinned {
            overlay.addSubview(pinButton)
            NSLayoutConstraint.activate([
                pinButton.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -6),
                pinButton.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 6),
                pinButton.widthAnchor.constraint(equalToConstant: 24),
                pinButton.heightAnchor.constraint(equalToConstant: 24),
            ])
        } else {
            pinAccessory.view.addSubview(pinButton)
            NSLayoutConstraint.activate(pinAccessoryConstraints)
            window.addTitlebarAccessoryViewController(pinAccessory)
        }
        overlay.isHidden = !pinned
        pinButton.bezelStyle = pinned ? .rounded : .accessoryBarAction
        window.setFrame(window.frameRect(forContentRect: contentRect), display: true)
        overlay.refreshPointerPresence()
        pinButton.isHidden = pinned && !overlay.pointerInside
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.pinIdentifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.pinIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Pin"
        item.view = pinButton
        item.isNavigational = false
        return item
    }
}

/// Tracks hover across the clear canvas without taking WebKit input.
@MainActor
final class GraphPinOverlayView: NSView {
    weak var pinButton: NSButton?
    var onHover: ((Bool) -> Void)?
    private(set) var pointerInside = false
    private var hoverArea: NSTrackingArea?
    private var invalidated = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !invalidated else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        refreshPointerPresence()
    }

    func refreshPointerPresence() {
        let inside = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        setPointerInside(inside)
    }

    func setPointerInside(_ inside: Bool) {
        pointerInside = inside
        onHover?(inside)
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let button = pinButton, !button.isHidden else { return nil }
        let local = convert(point, from: superview)
        guard button.frame.contains(local) else { return nil }
        return button.hitTest(convert(local, to: button.superview))
    }

    func invalidate() {
        invalidated = true
        onHover = nil
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        isHidden = true
    }
}
