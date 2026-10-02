import AppKit
import SwiftUI
import Testing
@testable import PersonaStack

@Suite @MainActor
struct DesktopDiagnosticsRenderingTests {
    @Test func diagnosticsRendersAtDefaultAndMinimumSizes() async throws {
        let model = DesktopControlDiagnosticsModel(read: { DesktopControlPresentationTests.report() }, repair: {})
        model.start()
        defer { model.stop() }
        for _ in 0..<100 where model.report == nil { await Task.yield() }
        _ = try #require(model.report)
        for size in [NSSize(width: 580, height: 590), NSSize(width: 440, height: 400)] {
            let host = NSHostingView(rootView: DesktopControlDiagnosticsView(model: model)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            host.appearance = window.appearance
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.displayIfNeeded()
            #expect(host.frame.size == size)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let directory = ProcessInfo.processInfo.environment["PERSONASTACK_NATIVE_RENDER_DIR"] {
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("desktop-diagnostics-\(Int(size.width)).png"))
            }
            window.close()
        }
    }
}
