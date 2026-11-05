import AppKit
import PersonaStackCore

/// One native confirmation surface owns capability choice. Page state never
/// supplies this decision. Keeping the target alive also owns checkbox events.
@MainActor final class IMessageReviewCapabilityControls: NSObject {
    let read: NSButton
    let send: NSButton
    let view: NSStackView
    private let approvalButton: NSButton
    init(readEnabled: Bool, sendEnabled: Bool, approvalButton: NSButton) {
        read = NSButton(checkboxWithTitle: "Read messages", target: nil, action: nil)
        send = NSButton(checkboxWithTitle: "Send messages", target: nil, action: nil)
        view = NSStackView(views: [read, send]); view.orientation = .vertical; view.alignment = .leading
        view.spacing = 8; self.approvalButton = approvalButton
        super.init()
        read.state = readEnabled ? .on : .off; send.state = sendEnabled ? .on : .off
        for button in [read, send] { button.target = self; button.action = #selector(changed) }
        changed()
    }
    @objc private func changed() { approvalButton.isEnabled = read.state == .on || send.state == .on }
}

@MainActor final class IMessageNativeMessageComposer: NSObject, NSTextViewDelegate {
    let picker: NSPopUpButton
    let text: NSTextView
    let view: NSStackView
    private let approvalButton: NSButton
    init(conversations: [IMessageGatewayPublicConversation], approvalButton: NSButton) {
        self.approvalButton = approvalButton
        picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        picker.addItems(withTitles: conversations.map { $0.label.isEmpty ? $0.participants.joined(separator: ", ") : $0.label })
        picker.setAccessibilityLabel("Conversation")
        text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        text.isRichText = false; text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Message")
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true
        view = NSStackView(views: [picker, scroll]); view.orientation = .vertical; view.spacing = 12
        view.widthAnchor.constraint(equalToConstant: 360).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        super.init(); text.delegate = self
        textDidChange(Notification(name: NSText.didChangeNotification))
    }
    func textDidChange(_ notification: Notification) {
        approvalButton.isEnabled = !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.string.utf8.count <= 16384
    }
    static func preview(_ body: String) -> NSView {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
        text.isRichText = false; text.isEditable = false; text.isSelectable = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize); text.string = body
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text; scroll.hasVerticalScroller = true
        return scroll
    }
}
