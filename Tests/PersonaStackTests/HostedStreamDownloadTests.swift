import AppKit
import Foundation
import Testing
import WebKit
@testable import PersonaStack

// Explicit network/native acceptance. Ordinary regression tests do not load a page.
@MainActor
struct HostedStreamDownloadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PERSONASTACK_STREAM_DOWNLOAD_FIXTURE_URL"] != nil))
    func authenticatedAttachmentPreservesStreamAndRejectsDenials() async throws {
        let base = try #require(URL(string: ProcessInfo.processInfo.environment["PERSONASTACK_STREAM_DOWNLOAD_FIXTURE_URL"] ?? ""))
        guard base.host == "127.0.0.1", base.scheme == "http" else {
            Issue.record("The native download fixture must use loopback HTTP")
            return
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HostedStreamDownloadTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stream = StackPopoutWindow(url: base.appendingPathComponent("stream"), transparent: false,
            kind: .stackStream, downloadDirectory: directory, openExternalURL: { _ in Issue.record("Download opened external browser") }) {}
        defer { stream.dispose() }
        try await waitFor { await self.evaluate(stream.webView, "!!document.querySelector('#file')") }
        let filename = "native-stack-download-\(UUID().uuidString.lowercased()).txt"
        let file = directory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: file) }
        let link = base.appendingPathComponent("user/stacks/assets/download").absoluteString
            + "?workspace_id=fixture&stack_id=fixture&asset_id=fixture&filename=\(filename)"
        #expect(await evaluate(stream.webView, "document.querySelector('#file').href='\(link)'; document.querySelector('#file').click(); true"))
        try await waitFor { (try? Data(contentsOf: file)) == Data("private stack bytes\n".utf8) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "private stack bytes\n")
        for result in ["denied", "error", "redirect"] {
            #expect(await evaluate(stream.webView, "document.querySelector('#file').href='\(link)&result=\(result)'; document.querySelector('#file').click(); true"))
            try await Task.sleep(for: .milliseconds(350))
            #expect(await evaluate(stream.webView, "!!document.querySelector('#stream')"))
            #expect(stream.webView.navigationDelegate != nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [filename])
        #expect(stream.webView.url == base.appendingPathComponent("stream"))
    }

    private func evaluate(_ view: WKWebView, _ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value as? Bool == true) }
        }
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await condition(), "Native download fixture condition timed out")
    }
}
