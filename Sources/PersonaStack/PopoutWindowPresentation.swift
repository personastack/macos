import AppKit
import WebKit

enum PopoutWindowKind: String, CaseIterable {
    case chat, stackStream, personaActivity

    var fallbackTitle: String {
        switch self {
        case .chat: "Persona Chat"
        case .stackStream: "Stack Stream"
        case .personaActivity: "Live Console"
        }
    }
}

/// Only three local frame records; never keyed by a hosted identity or URL.
struct PopoutGeometryStore {
    let defaults: UserDefaults
    static func key(_ kind: PopoutWindowKind) -> String { "popout.expandedFrame.\(kind.rawValue)" }

    func read(_ kind: PopoutWindowKind) -> NSRect? {
        guard let values = defaults.array(forKey: Self.key(kind)) as? [Double], values.count == 4 else { return nil }
        let frame = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        return Self.valid(frame) ? frame : nil
    }

    func save(_ frame: NSRect, kind: PopoutWindowKind, collapsed: Bool, fullscreen: Bool) {
        guard !collapsed, !fullscreen, Self.valid(frame) else { return }
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
        // Unified keeps the title and controls together in the native ~52pt row.
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isOpaque = true
        window.backgroundColor = Self.backgroundColor
        window.hasShadow = true
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        pinButton.setButtonType(.toggle)
        pinButton.bezelStyle = .texturedRounded
        pinButton.imagePosition = .imageOnly
        pinButton.setAccessibilityLabel("Always on top")
        pinButton.toolTip = "Always on top"
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        setPinned(false)
        pinButton.sizeToFit()
        window.toolbar = toolbar
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
        window.toolbar = value ? nil : toolbar
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

    @objc func willEnterFullscreen() { recordGeometry(); fullscreenTransition = true }
    @objc func willExitFullscreen() { fullscreenTransition = true }
    @objc func didEnterFullscreen() { fullscreenTransition = false }
    @objc func didExitFullscreen() { fullscreenTransition = false }

    func fullscreenTransitionFailed() {
        fullscreenTransition = false
        recordGeometry()
    }

    func invalidate() {
        guard !invalidated else { return }
        recordGeometry()
        invalidated = true
        titleObservation = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc func togglePin() { setPinned(window.level != .floating) }

    private func setPinned(_ pinned: Bool) {
        window.level = pinned ? .floating : .normal
        pinButton.state = pinned ? .on : .off
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.setAccessibilityValue(pinned ? 1 : 0)
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
