import AppKit
import PersonaStackCore
import SwiftUI

@MainActor
final class DesktopPerceptionSetupController: ObservableObject {
    @Published private(set) var review: CuaPerceptionInstallReview?
    @Published private(set) var status: CuaPerceptionStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var failure: String?
    private let installer: any CuaPerceptionInstalling
    private var generation = 0
    private var preparation: Task<CuaPerceptionInstallReview, Error>?
    private var installation: Task<CuaPerceptionStatus, Error>?
    private var observation: Task<CuaPerceptionStatus, Error>?

    init(installer: any CuaPerceptionInstalling = CuaPerceptionInstaller()) { self.installer = installer }

    func refresh(driver: CuaDriverInstallation) async {
        guard !isWorking else { return }
        let current = generation
        let task = Task { try await installer.status(driver: driver) }
        observation = task
        do {
            let result = try await task.value
            guard !Task.isCancelled, generation == current else { return }
            status = result
            failure = nil
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            status = nil
            failure = error.localizedDescription
        }
    }

    func prepare(driver: CuaDriverInstallation) async {
        guard !isWorking else { return }
        generation += 1
        let current = generation
        isWorking = true
        failure = nil
        defer { if generation == current { isWorking = false } }
        do {
            let task = Task { try await installer.prepareReview(driver: driver) }
            preparation = task
            let candidate = try await task.value
            guard !Task.isCancelled, generation == current else { return }
            review = candidate
        } catch {
            guard generation == current else { return }
            failure = error.localizedDescription
        }
    }

    /// Call only from a native Install button after displaying the exact review.
    func confirmInstall() async -> Bool {
        guard !isWorking, let approved = review else { return false }
        generation += 1
        let current = generation
        isWorking = true
        failure = nil
        defer { if generation == current { isWorking = false } }
        do {
            let task = Task { try await installer.install(review: approved) }
            installation = task
            let result = try await task.value
            guard !Task.isCancelled, generation == current else { return false }
            status = result
            review = nil
            return status?.ready == true
        } catch {
            guard !Task.isCancelled, generation == current else { return false }
            review = nil
            failure = error.localizedDescription
            return false
        }
    }

    func cancel() async {
        generation += 1
        installation?.cancel()
        observation?.cancel()
        preparation?.cancel()
        preparation = nil
        review = nil
        isWorking = false
        await installer.cancelReview()
    }

    var catalogURL: URL { get async { await installer.catalogURL } }
}

/// Reuse in the existing wizard's component area. The full upstream review stays visible.
struct DesktopPerceptionInstallReviewView: View {
    let review: CuaPerceptionInstallReview
    let isWorking: Bool
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install visual perception").font(.headline)
            Text("CUA Perception 0.2.1 downloads 426 MB. It includes separately licensed models. Review the publisher, licenses, source, checksums and destination before installing.")
            Text("License: \(review.license)\nDestination: \(review.destination)")
                .font(.callout).textSelection(.enabled)
            ScrollView {
                Text(review.displayJSON).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(minHeight: 160, maxHeight: 280)
                .accessibilityLabel("Exact verified CUA perception installation review")
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.bordered).disabled(isWorking)
                Spacer()
                Button(isWorking ? "Installing…" : "Install", action: install)
                    .buttonStyle(.borderedProminent).disabled(isWorking)
            }
        }.padding(16)
    }
}
