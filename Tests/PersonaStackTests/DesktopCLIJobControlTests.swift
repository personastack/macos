import Darwin
import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

@Suite @MainActor struct DesktopCLIJobControlTests {
    private enum FixtureError: Error { case missingResult, missingJob }

    private func frame(_ operation: String, target: DesktopControlTarget,
                       args: [String: DesktopControlJSONValue] = [:]) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: UUID().uuidString, target: target, operation: operation,
                            arguments: .object(args), deadlineAt: Date().addingTimeInterval(15))
    }
    private func object(_ result: DesktopControlFrame) throws -> [String: DesktopControlJSONValue] {
        guard case .object(let values)? = result.result else { throw FixtureError.missingResult }
        return values
    }
    private func output(_ result: [String: DesktopControlJSONValue]) -> String {
        guard case .array(let chunks)? = result["chunks"] else { return "" }
        return chunks.compactMap { chunk -> String? in
            guard case .object(let fields) = chunk, case .string(let encoded)? = fields["data_base64"],
                  let data = Data(base64Encoded: encoded) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined()
    }
    private func live(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return bytes == MemoryLayout<proc_bsdinfo>.size && info.pbi_status != UInt32(SZOMB)
    }

    @Test(arguments: [false, true])
    func cancelOrRevokeStopsDifferentJobGroupsInTheOwnedPTYSession(revoke: Bool) async throws {
        let executor = DesktopControlCommandExecutor()
        let target = DesktopControlTarget(installationID: "job-installation", workspaceID: "job-workspace", configID: "job-config",
            personaID: "job-persona", runID: "job-run", generation: 1, configVersion: 1)
        do {
            let lease = try object(await executor.handle(frame("desktop_control_acquire", target: target), proxy: nil))
            guard let token = lease["control_token"] else { throw FixtureError.missingResult }
            let python = "import os,signal,time; signal.signal(signal.SIGHUP,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); print('PS_JOB:%d:%d:%d'%(os.getpid(),os.getsid(0),os.getpgrp()),flush=True); time.sleep(30)"
            let quotedPython = "'" + python.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = "python3 -u -c " + quotedPython + " & wait"
            let command = "exec /bin/bash -ic '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let started = try object(await executor.handle(frame("desktop_control_execute", target: target, args: [
                "control_token": token, "command": .string(command), "working_directory": .string("/tmp"),
                "terminal_mode": .string("pty"), "timeout_seconds": .number(10)]), proxy: nil))
            guard let id = started["execution_id"] else { throw FixtureError.missingResult }
            var cursor = started["next_cursor"] ?? .number(0)
            var text = output(started)
            let end = ContinuousClock.now + .seconds(5)
            while text.range(of: #"PS_JOB:\d+:\d+:\d+\r?\n"#, options: .regularExpression) == nil, ContinuousClock.now < end {
                let page = try object(await executor.handle(frame("desktop_control_exec_read", target: target, args: [
                    "control_token": token, "execution_id": id, "cursor": cursor, "wait_ms": .number(500)]), proxy: nil))
                text += output(page)
                cursor = page["next_cursor"] ?? cursor
            }
            guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("PS_JOB:") }) else {
                throw FixtureError.missingJob
            }
            let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard fields.count == 4, let pid = pid_t(fields[1]), let sid = pid_t(fields[2]), let group = pid_t(fields[3]) else {
                throw FixtureError.missingJob
            }
            #expect(group != sid, "fixture must create a normal job-control group distinct from the session leader")
            #expect(live(pid))
            #expect(getsid(pid) == sid)
            let stopped: DesktopControlFrame
            if revoke {
                let scope = DesktopControlTarget(installationID: target.installationID, workspaceID: target.workspaceID,
                    configID: target.configID, personaID: "", runID: "", generation: 0, configVersion: 1)
                stopped = await executor.handle(frame("desktop_control_revoke_config", target: scope), proxy: nil)
            } else {
                stopped = await executor.handle(frame("desktop_control_exec_cancel", target: target,
                    args: ["control_token": token, "execution_id": id]), proxy: nil)
            }
            #expect(stopped.type == "result", "\(stopped.errorCode ?? "no failure")")
            #expect(!live(pid), "owned job must stop before cancellation or revocation is acknowledged")
            #expect(await executor.close())
        } catch { _ = await executor.close(); throw error }
    }
}
