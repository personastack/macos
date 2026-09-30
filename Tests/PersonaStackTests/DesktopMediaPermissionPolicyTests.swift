import Foundation
import Testing
import PersonaStackCore

@Test func desktopMediaPermissionAllowsOnlyTrustedMainFrameMicrophone() {
    let appURL = URL(string: "https://my.personastack.ai/user/personas")!
    #expect(DesktopMediaPermissionPolicy.decision(
        scheme: "https", host: "my.personastack.ai", port: 443, mainFrame: true,
        appURL: appURL, microphoneOnly: true, authorization: .authorized
    ) == .grant)
    #expect(DesktopMediaPermissionPolicy.decision(
        scheme: "https", host: "my.personastack.ai", port: 443, mainFrame: true,
        appURL: appURL, microphoneOnly: true, authorization: .notDetermined
    ) == .prompt)
    for authorization in [DesktopMicrophoneAuthorization.denied, .restricted] {
        #expect(DesktopMediaPermissionPolicy.decision(
            scheme: "https", host: "my.personastack.ai", port: 443, mainFrame: true,
            appURL: appURL, microphoneOnly: true, authorization: authorization
        ) == .deny)
    }
}

@Test func desktopMediaPermissionRejectsForeignOriginFrameCameraAndInsecureLAN() {
    let appURL = URL(string: "https://my.personastack.ai")!
    for (scheme, host, port, mainFrame, microphoneOnly) in [
        ("https", "foreign.example", 443, true, true),
        ("https", "my.personastack.ai", 444, true, true),
        ("https", "my.personastack.ai", 443, false, true),
        ("https", "my.personastack.ai", 443, true, false),
        ("http", "my.personastack.ai", 80, true, true),
    ] {
        #expect(DesktopMediaPermissionPolicy.decision(
            scheme: scheme, host: host, port: port, mainFrame: mainFrame,
            appURL: appURL, microphoneOnly: microphoneOnly, authorization: .authorized
        ) == .deny)
    }
    #expect(DesktopMediaPermissionPolicy.decision(
        scheme: "http", host: "personastack.ericgreer.info", port: 8080, mainFrame: true,
        appURL: URL(string: "http://personastack.ericgreer.info:8080")!,
        microphoneOnly: true, authorization: .authorized
    ) == .deny)
    #expect(DesktopMediaPermissionPolicy.decision(
        scheme: "http", host: "127.0.0.1", port: 8080, mainFrame: true,
        appURL: URL(string: "http://127.0.0.1:8080")!,
        microphoneOnly: true, authorization: .authorized
    ) == .grant)
}
