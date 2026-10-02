import AppKit
import PersonaStackCore
import SwiftUI

@MainActor
final class MainWebViewLoadRecovery: ObservableObject {
    @Published private(set) var isFailed = false
    private var currentNavigation: ObjectIdentifier?

    func navigationStarted(_ navigation: AnyObject?) {
        guard let navigation else { return }
        currentNavigation = ObjectIdentifier(navigation)
        isFailed = false
    }

    func navigationSucceeded(_ navigation: AnyObject?) {
        guard isCurrent(navigation) else { return }
        currentNavigation = nil
        isFailed = false
    }

    func navigationFailed(_ navigation: AnyObject?, error: Error) {
        guard isCurrent(navigation) else { return }
        currentNavigation = nil
        let error = error as NSError
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
        isFailed = true
    }

    func reset() {
        currentNavigation = nil
        isFailed = false
    }

    private func isCurrent(_ navigation: AnyObject?) -> Bool {
        guard let navigation else { return false }
        return currentNavigation == ObjectIdentifier(navigation)
    }
}

struct MainWebViewLoadRecoveryOverlay: View {
    let coordinator: PersonaStackWebView.Coordinator
    @ObservedObject private var recovery: MainWebViewLoadRecovery

    init(coordinator: PersonaStackWebView.Coordinator) {
        self.coordinator = coordinator
        _recovery = ObservedObject(wrappedValue: coordinator.loadRecovery)
    }

    var body: some View {
        if recovery.isFailed {
            ZStack {
                Color(nsColor: WindowPresentation.canvasColor)
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("PersonaStack couldn’t load")
                        .font(.title3.weight(.semibold))
                    Text("Check your connection and try again.")
                        .foregroundStyle(.secondary)
                    Button("Retry", action: coordinator.retry)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("main-webview-retry")
                }
                .multilineTextAlignment(.center)
                .padding(32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
