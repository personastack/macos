import AppKit
import SwiftUI

@MainActor
final class DesktopDownloadNotice: ObservableObject {
    static let shared = DesktopDownloadNotice()

    struct Notice: Equatable {
        let title: String
        let detail: String
        let file: URL?
    }

    @Published private(set) var notice: Notice? {
        didSet {
            guard let notice else { return }
            let action = notice.file == nil ? "" : " View File shows the file in Finder."
            announce("\(notice.title). \(notice.detail)." + action)
        }
    }
    private var destinations: [ObjectIdentifier: URL] = [:]
    private let fileExists: (URL) -> Bool
    private let revealFile: (URL) -> Void
    private let announce: (String) -> Void

    init(fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
         revealFile: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         announce: @escaping (String) -> Void = { message in
             guard let window = NSApp?.mainWindow else { return }
             NSAccessibility.post(element: window, notification: .announcementRequested,
                                  userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
         }) {
        self.fileExists = fileExists
        self.revealFile = revealFile
        self.announce = announce
    }

    func track(_ identifier: ObjectIdentifier, destination: URL) {
        guard destination.isFileURL else { return }
        destinations[identifier] = destination
    }

    func finished(_ identifier: ObjectIdentifier) {
        guard let destination = destinations.removeValue(forKey: identifier) else { return }
        guard fileExists(destination) else {
            failedNotice()
            return
        }
        notice = Notice(title: "Download complete", detail: destination.lastPathComponent, file: destination)
    }

    func failed(_ identifier: ObjectIdentifier) {
        destinations.removeValue(forKey: identifier)
        failedNotice()
    }

    func viewFile() {
        guard let file = notice?.file else { return }
        guard fileExists(file) else {
            notice = Notice(title: "File unavailable", detail: "The downloaded file was moved or removed.", file: nil)
            return
        }
        revealFile(file)
        dismiss()
    }

    func dismiss() { notice = nil }

    private func failedNotice() {
        notice = Notice(title: "Download failed", detail: "The file could not be saved. Please try again.", file: nil)
    }
}

struct DesktopDownloadToast: View {
    @ObservedObject var downloads: DesktopDownloadNotice = .shared

    var body: some View {
        if let notice = downloads.notice {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: notice.file == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(notice.file == nil ? Color.orange : Color.green)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title).font(.headline)
                    Text(notice.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if notice.file != nil {
                        Text("Saved to Downloads").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if notice.file != nil {
                    Button("View File") { downloads.viewFile() }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .help("Show the downloaded file in Finder")
                }
                Button { downloads.dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss download notification")
                .help("Dismiss")
            }
            .padding(16)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .shadow(radius: 12, y: 4)
            .accessibilityElement(children: .contain)
        }
    }
}
