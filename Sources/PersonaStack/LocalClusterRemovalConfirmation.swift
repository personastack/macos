import AppKit

@MainActor
enum LocalClusterRemovalConfirmation {
    static func makeAlert(messageText: String, informativeText: String, alertStyle: NSAlert.Style? = nil) -> NSAlert {
        let alert = NSAlert()
        if let alertStyle { alert.alertStyle = alertStyle }
        alert.messageText = messageText
        alert.informativeText = informativeText
        let remove = alert.addButton(withTitle: "Remove Local Data")
        let cancel = alert.addButton(withTitle: "Cancel")
        remove.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert
    }
}
