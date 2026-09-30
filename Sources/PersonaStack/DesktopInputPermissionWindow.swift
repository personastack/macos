import AppKit
import Darwin
import PersonaStackCore

@MainActor
final class DesktopInputPermissionWindow: NSObject, DesktopInputPermissionTarget, NSWindowDelegate {
    let pid = Darwin.getpid()
    let expectedText = "PersonaStack permission check \(UUID().uuidString)"
    private(set) var clickCount = 0
    private var active = false
    private var window: NSWindow?
    private let field = NSTextField(string: "")
    private let button = NSButton(title: DesktopInputPermissionVerifier.buttonLabel, target: nil, action: nil)
    var windowID: Int { window?.windowNumber ?? 0 }
    var text: String { field.currentEditor()?.string ?? field.stringValue }

    func present() throws {
        guard window == nil, !active else { throw CancellationError() }
        let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 220),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        value.title = "Verify PersonaStack Desktop Control"
        value.isReleasedWhenClosed = false
        value.delegate = self
        let explanation = NSTextField(wrappingLabelWithString:
            "PersonaStack will click this test button and enter disposable text below. Your other windows are not used for this check.")
        field.setAccessibilityLabel(DesktopInputPermissionVerifier.fieldLabel)
        field.isEditable = true
        field.isSelectable = true
        button.target = self
        button.action = #selector(verifyClick)
        button.bezelStyle = .rounded
        let content = NSStackView(views: [explanation, button, field])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        value.contentView?.addSubview(content)
        if let view = value.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
                field.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        }
        window = value
        active = true
        value.center()
        value.makeKeyAndOrderFront(nil)
        value.makeFirstResponder(button)
        try requireCurrent()
    }

    func requireCurrent() throws {
        guard active, let window, window.isVisible, window.windowNumber > 0,
              button.isEnabled, field.isEditable else { throw CancellationError() }
    }

    @objc private func verifyClick() {
        guard active, let window, window.isVisible else { return }
        clickCount += 1
        window.makeFirstResponder(field)
    }

    func invalidate() {
        active = false
        button.isEnabled = false
        field.isEditable = false
        field.isSelectable = false
        field.currentEditor()?.string = ""
        window?.makeFirstResponder(nil)
        field.stringValue = ""
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { invalidate() }
}
