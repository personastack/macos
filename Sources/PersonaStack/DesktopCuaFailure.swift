import Foundation

/// Only reviewed codes and authored recovery text cross the relay. Cua's raw
/// error content can include private paths, page content, and command arguments.
struct DesktopCuaFailure: Error {
    let code: String
    let message: String

    static func from(_ result: [String: Any], tool: String) -> Self {
        let structured = result["structuredContent"] as? [String: Any]
        let refusal = structured?["refusal"] as? [String: Any]
        let code = refusal?["code"] as? String ?? ""
        let message: String
        switch code {
        case "browser_requires_setup", "browser_consent_required":
            message = "This browser needs setup. Use GUI controls for its current profile, or call desktop_control_browser with browser_prepare and arguments {confirm:true} to open a separate isolated Chrome or Edge profile."
        case "browser_route_unavailable":
            message = "This browser has no supported DOM control route. Use desktop observation and input, or prepare an isolated Chrome or Edge browser."
        case "browser_binding_stale", "browser_binding_ambiguous", "browser_wrong_target_refused",
             "browser_tab_required", "browser_tab_not_found", "browser_ref_stale", "browser_endpoint_owner_mismatch":
            message = "The browser target is missing, changed, or ambiguous. Discover its windows again, then call get_browser_state for a fresh target, tab, and references before acting."
        case "browser_input_incomplete":
            message = "Browser input was only partly delivered. Read the current field before deciding what remains. Do not repeat the entire input blindly."
        case "browser_consent_revoked", "browser_origin_outside_scope":
            message = "Browser access was denied or left its approved scope. Ask the user to restore access or use the approved GUI control path."
        case "browser_reconnect_exhausted":
            message = "The browser connection could not recover. Inspect the browser with GUI controls before preparing or binding it again."
        case "browser_input_trust_unavailable", "browser_action_unavailable":
            message = "This browser target cannot perform that action. Read its current state and use GUI input for the supported target."
        default:
            let recovery = ["get_desktop_state", "get_window_state"].contains(tool)
                ? "Check Screen Capture permission and discover the current target again."
                : "Observe the current desktop and target again before deciding whether to retry. The action may have partly completed."
            return Self(code: "desktop_command_failed", message: "Cua could not complete the requested action. " + recovery)
        }
        return Self(code: code, message: message)
    }
}
