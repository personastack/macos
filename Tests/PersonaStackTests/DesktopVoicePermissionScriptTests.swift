import Foundation
import JavaScriptCore
import Testing
@testable import PersonaStack

/// Runs the actual bundled diagnostic in-process with deterministic Web APIs.
/// No browser, microphone, audio content, app, or external service is started.
private final class VoiceScriptFixture {
    let context: JSContext
    init() throws {
        context = try #require(JSContext())
        context.exceptionHandler = { _, value in Issue.record("Unexpected JavaScript fixture exception: \(value?.toString() ?? "unknown")") }
        context.evaluateScript(#"""
            var timers = [], events = {}, tracksStopped = 0, requests = 0, starts = 0, stops = 0;
            var permissionResolve, permissionReject, result = 'pending', failure;
            var payloadBytes = 100, trackState = 'live';
            var window = globalThis;
            window.top = window;
            window.isSecureContext = true;
            window.addEventListener = (name, call) => events[name] = call;
            window.removeEventListener = (name) => delete events[name];
            function setTimeout(call, delay) { const timer = { call, delay, active: true }; timers.push(timer); return timer; }
            function clearTimeout(timer) { if (timer) timer.active = false; }
            function fire(delay) { timers.filter(t => t.active && t.delay === delay).forEach(t => { t.active = false; t.call(); }); }
            var track = { get readyState() { return trackState; }, stop() { tracksStopped++; trackState = 'ended'; } };
            var media = { getTracks: () => [track], getAudioTracks: () => [track] };
            var navigator = { mediaDevices: { getUserMedia: (options) => {
                if (options.audio !== true || options.video !== false) throw new Error('wrong constraints');
                requests++;
                return new Promise((resolve, reject) => { permissionResolve = resolve; permissionReject = reject; });
            } } };
            class MediaRecorder {
                constructor() { this.events = {}; this.state = 'inactive'; }
                addEventListener(name, handler) { this.events[name] = handler; }
                start() { starts++; this.state = 'recording'; }
                stop() {
                    stops++;
                    this.state = 'inactive';
                    this.events.dataavailable({ data: { size: payloadBytes } });
                    this.events.stop();
                }
            }
            """#)
    }
    func run() {
        context.evaluateScript("(async function(testID) {\n" + DesktopVoicePermissionScript.test + "\n})('fixture-id').then(value => result = value, error => failure = String(error));")
    }
    func cancel(id: String = "fixture-id") {
        context.setObject(id, forKeyedSubscript: "expectedID" as NSString)
        context.evaluateScript(DesktopVoicePermissionScript.cancel)
    }
    func value(_ expression: String) -> String { context.evaluateScript(expression)?.toString() ?? "undefined" }
}

struct DesktopVoicePermissionScriptTests {
    @Test func olderHostedPageRecordsAndDiscardsWithoutAnyHostedHook() throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        #expect(fixture.value("requests") == "1")
        fixture.context.evaluateScript("permissionResolve(media)")
        #expect(fixture.value("starts") == "1")
        fixture.context.evaluateScript("fire(200)")
        #expect(fixture.value("result") == "ready")
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("window.__personastackNativeVoiceTest") == "undefined")
        #expect(fixture.value("failure") == "undefined")
    }

    @Test(arguments: ["payloadBytes = 0", "payloadBytes = 1048577", "trackState = 'ended'"])
    func emptyOversizedOrEndedInputCannotVerify(change: String) throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        fixture.context.evaluateScript("permissionResolve(media)")
        fixture.context.evaluateScript(change)
        fixture.context.evaluateScript("fire(200)")
        #expect(fixture.value("result") == "failed")
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("window.__personastackNativeVoiceTest") == "undefined")
    }

    @Test(arguments: ["cancel", "deadline", "navigation"])
    func pendingPermissionCancellationStopsLateStreamWithoutRecording(reason: String) throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        switch reason {
        case "cancel": fixture.cancel()
        case "deadline": fixture.context.evaluateScript("fire(10000)")
        default: fixture.context.evaluateScript("events.pagehide()")
        }
        #expect(fixture.value("result") == (reason == "deadline" ? "timedOut" : "cancelled"))
        fixture.context.evaluateScript("permissionResolve(media)")
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("starts") == "0")
    }

    @Test func staleCancellationDoesNotStopCurrentRecording() throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        fixture.cancel(id: "stale")
        #expect(fixture.value("result") == "pending")
        fixture.context.evaluateScript("permissionResolve(media)")
        fixture.cancel()
        #expect(fixture.value("result") == "cancelled")
        #expect(fixture.value("tracksStopped") == "1")
    }

    @Test(arguments: ["NotAllowedError", "NotFoundError", "NotReadableError"])
    func captureErrorsKeepActionableReasons(name: String) throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        fixture.context.setObject(name, forKeyedSubscript: "errorName" as NSString)
        fixture.context.evaluateScript("permissionReject({ name: errorName })")
        #expect(fixture.value("result") == (name == "NotAllowedError" ? "denied" : name == "NotFoundError" ? "noInput" : "failed"))
        #expect(fixture.value("starts") == "0")
    }

    @Test func installedHostedHookOwnsTheRecordingAndCancellation() throws {
        let fixture = try VoiceScriptFixture()
        fixture.context.evaluateScript(#"""
            var hostedTest, hostedCancel;
            window.personastackVoicePermission = {
                version: '1', test: (id) => { hostedTest = id; return new Promise(() => {}); },
                cancel: (id) => hostedCancel = id
            };
            """#)
        fixture.run()
        #expect(fixture.value("hostedTest") == "fixture-id")
        #expect(fixture.value("requests") == "0")
        fixture.cancel()
        #expect(fixture.value("hostedCancel") == "fixture-id")
        #expect(fixture.value("window.__personastackNativeVoiceTest") == "undefined")
        fixture.run()
        #expect(fixture.value("window.__personastackNativeVoiceTest.id") == "fixture-id")
        #expect(fixture.value("requests") == "0")
    }

    @Test func cancelledHostedPromiseCannotRemoveItsSuccessorWhenItEventuallySettles() throws {
        let fixture = try VoiceScriptFixture()
        fixture.context.evaluateScript(#"""
            var completions = [];
            window.personastackVoicePermission = {
                version: '1', test: () => new Promise(resolve => completions.push(resolve)), cancel: () => {}
            };
            """#)
        fixture.run()
        fixture.cancel()
        fixture.run()
        fixture.context.evaluateScript("completions[0](true)")
        #expect(fixture.value("window.__personastackNativeVoiceTest.id") == "fixture-id")
        fixture.context.evaluateScript("completions[1](true)")
        #expect(fixture.value("window.__personastackNativeVoiceTest") == "undefined")
    }
}

@Test @MainActor func nativeVoiceCheckRejectsAnExistingWebKitCaptureWithoutExecutingJavaScript() {
    let page = DesktopVoicePermissionWebPage(isCapturing: { true }, evaluate: { _, _, _ in
        Issue.record("Existing capture must not be disturbed")
    })
    var busy = false
    page.test(id: "fixture") { result in
        if case .failure(DesktopVoicePermissionError.busy) = result { busy = true }
    }
    #expect(busy)
}

@Test @MainActor func nativeVoiceReplyAcceptsOnlyReadyAndPreservesFailureReasons() throws {
    for status in ["ready", "busy", "denied", "noInput", "failed", "unsupported", "timedOut"] {
        let page = DesktopVoicePermissionWebPage(isCapturing: { false }, evaluate: { script, arguments, completion in
            #expect(script == DesktopVoicePermissionScript.test)
            #expect(arguments["testID"] as? String == "fixture")
            completion(.success(status))
        })
        var result: Result<Bool, Error>?
        page.test(id: "fixture") { result = $0 }
        if status == "ready" { #expect(try result?.get() == true) }
        else {
            guard case .failure(let error as DesktopVoicePermissionError) = result else {
                Issue.record("Missing typed failure for \(status)"); continue
            }
            #expect(!error.observation.verified)
        }
    }
}
