import Foundation
import JavaScriptCore
import PersonaStackCore
import Testing
import WebKit
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
            var payloadBytes = 100, trackState = 'live', recorderInstance, timeslice;
            var omitStopEvents = false;
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
                constructor() { this.events = {}; this.state = 'inactive'; recorderInstance = this; }
                addEventListener(name, handler) { this.events[name] = handler; }
                start(slice) { starts++; timeslice = slice; this.state = 'recording'; }
                stop() {
                    stops++;
                    this.state = 'inactive';
                    if (omitStopEvents) return;
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
        context.evaluateScript("(function(expectedID) {\n" + DesktopVoicePermissionScript.cancel + "\n})(expectedID)")
    }
    func value(_ expression: String) -> String { context.evaluateScript(expression)?.toString() ?? "undefined" }
}

struct DesktopVoicePermissionScriptTests {
    @Test func olderHostedPageWaitsForRecorderStartAndUsableDataBeforeStopping() throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        #expect(fixture.value("requests") == "1")
        fixture.context.evaluateScript("permissionResolve(media)")
        #expect(fixture.value("starts") == "1")
        #expect(fixture.value("timeslice") == "1000")
        fixture.context.evaluateScript("fire(200)")
        fixture.context.evaluateScript("fire(5000)")
        #expect(fixture.value("stops") == "0")
        #expect(fixture.value("result") == "pending")
        fixture.context.evaluateScript("recorderInstance.events.start()")
        fixture.context.evaluateScript("recorderInstance.events.dataavailable({ data: { size: 0 } })")
        #expect(fixture.value("stops") == "0")
        #expect(fixture.value("result") == "pending")
        fixture.context.evaluateScript("recorderInstance.events.dataavailable({ data: { size: 100 } })")
        #expect(fixture.value("result") == "ready")
        #expect(fixture.value("stops") == "1")
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("timers.filter(t => t.active).length") == "0")
        #expect(fixture.value("window.__personastackNativeVoiceTest") == "undefined")
        #expect(fixture.value("failure") == "undefined")
    }

    @Test(arguments: ["payloadBytes = 0", "payloadBytes = 1048577", "trackState = 'ended'"])
    func emptyOversizedOrEndedInputCannotVerify(change: String) throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        fixture.context.evaluateScript("permissionResolve(media)")
        fixture.context.evaluateScript("recorderInstance.events.start()")
        fixture.context.evaluateScript(change)
        fixture.context.evaluateScript("fire(5000)")
        #expect(fixture.value("result") == (change == "payloadBytes = 0" ? "empty" : "failed"))
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("window.__personastackNativeVoiceTest") == "undefined")
    }

    @Test func finalChunkCanVerifyWhenWebKitDoesNotEmitPeriodicData() throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        fixture.context.evaluateScript("permissionResolve(media)")
        fixture.context.evaluateScript("recorderInstance.events.start(); fire(5000)")
        #expect(fixture.value("result") == "ready")
        #expect(fixture.value("stops") == "1")
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("timers.filter(t => t.active).length") == "0")
    }

    @Test(arguments: ["missingStart", "missingStop"])
    func recorderEventDeadlineStopsOnlyTheOwnedStream(reason: String) throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        fixture.context.evaluateScript("permissionResolve(media)")
        if reason == "missingStop" {
            fixture.context.evaluateScript("omitStopEvents = true; recorderInstance.events.start(); fire(5000)")
        }
        fixture.context.evaluateScript("fire(10000)")
        #expect(fixture.value("result") == "timedOut")
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("stops") == "1")
        #expect(fixture.value("window.__personastackNativeVoiceTest") == "undefined")
        #expect(fixture.value("timers.filter(t => t.active).length") == "0")
    }

    @Test(arguments: [false, true])
    func cancelledRecorderIgnoresLateStartDataAndStopEvents(started: Bool) throws {
        let fixture = try VoiceScriptFixture()
        fixture.run()
        fixture.context.evaluateScript("permissionResolve(media)")
        if started { fixture.context.evaluateScript("recorderInstance.events.start()") }
        fixture.cancel()
        fixture.context.evaluateScript("recorderInstance.events.start(); recorderInstance.events.dataavailable({data:{size:100}}); recorderInstance.events.stop()")
        #expect(fixture.value("result") == "cancelled")
        #expect(fixture.value("stops") == "1")
        #expect(fixture.value("tracksStopped") == "1")
        #expect(fixture.value("timers.filter(t => t.active).length") == "0")
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
    for status in ["ready", "busy", "denied", "noInput", "empty", "failed", "unsupported", "timedOut"] {
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

@Test(arguments: [WKError.Code.javaScriptExceptionOccurred, .javaScriptResultTypeIsUnsupported,
                  .webContentProcessTerminated, .webViewInvalidated, .javaScriptInvalidFrameTarget]) @MainActor
func nativeVoiceJavaScriptEvaluationFailureDoesNotClaimAnEmptyRecording(code: WKError.Code) {
    let page = DesktopVoicePermissionWebPage(isCapturing: { false }, evaluate: { _, _, completion in
        completion(.failure(NSError(domain: WKError.errorDomain, code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "private page and script details"])))
    })
    var observation: PersonaStackCore.DesktopPermissionObservation?
    page.test(id: "fixture") { result in
        if case .failure(let error as DesktopVoicePermissionError) = result { observation = error.observation }
    }
    #expect(observation == DesktopVoicePermissionError.evaluationFailed.observation)
    #expect(observation != DesktopVoicePermissionError.emptyRecording.observation)
    #expect(observation?.detail.contains("private") == false)
}

@Test @MainActor func nativeVoiceEmptyRecordingHasItsOwnFailureReason() {
    let page = DesktopVoicePermissionWebPage(isCapturing: { false }, evaluate: { _, _, completion in
        completion(.success("empty"))
    })
    var empty = false
    page.test(id: "fixture") { result in
        if case .failure(DesktopVoicePermissionError.emptyRecording) = result { empty = true }
    }
    #expect(empty)
}
