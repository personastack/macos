import Foundation

/// Bundled WebKit diagnostic for hosted versions without the voice test hook.
/// No audio crosses the JavaScript boundary. Every stream belongs to one test.
enum DesktopVoicePermissionScript {
    static let test = #"""
        if (window.top !== window || !window.isSecureContext) return 'unsupported';
        if (window.__personastackNativeVoiceTest) return 'busy';
        const operation = { id: testID, cancel: () => {} };
        window.__personastackNativeVoiceTest = operation;
        const current = () => window.__personastackNativeVoiceTest === operation;
        const owner = window.personastackVoicePermission;
        if (owner && owner.version === '1' && typeof owner.test === 'function' && typeof owner.cancel === 'function') {
            operation.cancel = () => {
                if (current()) delete window.__personastackNativeVoiceTest;
                owner.cancel(testID);
            };
            try { return await owner.test(testID) === true ? 'ready' : 'failed'; }
            finally { if (current()) delete window.__personastackNativeVoiceTest; }
        }
        if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
            delete window.__personastackNativeVoiceTest;
            return 'unsupported';
        }
        return await new Promise((resolve) => {
            let ended = false, stream, recorder, stopTimer, deadline, bytes = 0;
            const finish = (result) => {
                if (ended) return;
                ended = true;
                clearTimeout(stopTimer);
                clearTimeout(deadline);
                window.removeEventListener('pagehide', cancel);
                if (recorder?.state === 'recording') { try { recorder.stop(); } catch {} }
                stream?.getTracks().forEach((track) => track.stop());
                stream = undefined;
                if (current()) delete window.__personastackNativeVoiceTest;
                resolve(result);
            };
            const cancel = () => finish('cancelled');
            operation.cancel = cancel;
            window.addEventListener('pagehide', cancel, { once: true });
            deadline = setTimeout(() => finish('timedOut'), 10000);
            const failed = (error) => finish(error?.name === 'NotAllowedError' ? 'denied'
                : error?.name === 'NotFoundError' ? 'noInput' : 'failed');
            try {
                Promise.resolve(navigator.mediaDevices.getUserMedia({ audio: true, video: false })).then((media) => {
                    if (ended || !current()) { media.getTracks().forEach((track) => track.stop()); cancel(); return; }
                    stream = media;
                    if (!media.getAudioTracks().some((track) => track.readyState === 'live')) { finish('noInput'); return; }
                    try {
                        recorder = new MediaRecorder(media);
                        recorder.addEventListener('dataavailable', (event) => {
                            if (ended) return;
                            bytes += event.data.size;
                            if (bytes > 1048576) finish('failed');
                        });
                        recorder.addEventListener('error', () => finish('failed'));
                        recorder.addEventListener('stop', () => finish(current() && bytes > 0 &&
                            stream?.getAudioTracks().some((track) => track.readyState === 'live') ? 'ready' : 'failed'));
                        recorder.start(200);
                        stopTimer = setTimeout(() => {
                            try { recorder.stop(); } catch { finish('failed'); }
                        }, 200);
                    } catch (error) { failed(error); }
                }, failed);
            } catch (error) { failed(error); }
        });
        """#

    static let cancel = #"""
        const operation = window.__personastackNativeVoiceTest;
        if (operation?.id === expectedID) operation.cancel();
        """#
}
