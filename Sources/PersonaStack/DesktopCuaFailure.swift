import Foundation

/// Only reviewed codes and authored recovery text cross the relay. Cua's raw
/// error content can include private paths, page content, and command arguments.
struct DesktopCuaFailure: Error {
    let code: String
    let message: String

    static func from(_ result: [String: Any], tool: String) -> Self {
        let structured = result["structuredContent"] as? [String: Any]
        let refusal = structured?["refusal"] as? [String: Any]
        // Cua 0.29.1 uses all three reviewed locations: refusal.code for
        // policy/target refusals, code for structured tool failures, and
        // error for launch_app's legacy structured failure envelope.
        let launchError = tool == "launch_app" ? structured?["error"] as? String : nil
        let code = refusal?["code"] as? String ?? structured?["code"] as? String ?? launchError ?? ""
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
        case "PROTECTED_HOST_ENTRYPOINT":
            message = "Cua refused to launch its protected control host. Use PersonaStack's native permission setup flow for operating-system permission actions."
        case "LAUNCH_CALLBACK_TIMEOUT":
            message = "Cua's launch callback timed out. The app or URL may already have opened. Discover current apps and windows before any repeat. If the intended target is Safari and it is absent, launch Safari without URLs, rediscover its window, then enter the URL through GUI input."
        case "NSWORKSPACE_LAUNCH_FAILED", "LAUNCH_RESULT_MISSING", "LAUNCH_FAILED":
            message = "Cua could not confirm that the requested app launched. Check the app identifier and current app or window state before deciding whether to retry; the failure report does not establish whether the app is running."
        case "APP_NOT_INSTALLED":
            message = "Cua could not find an installed macOS app matching the requested name or identifier. Check the app identifier or install the app, then discover its window before sending input."
        case "APP_URL_INVALID", "FILE_NOT_FOUND":
            message = "Cua rejected the launch target. Check that the app identifier or requested file target is valid before retrying."
        case "authorization_required", "permission_denied":
            message = "Cua denied this operation under its current authorization or policy. Use the approved Desktop Control setup or ask the user to authorize the operation, then observe the current state before retrying."
        case "os_permission_prompt_requires_trusted_host":
            message = "Cua refused an operating-system permission prompt through the tool stream. Use PersonaStack's native permission setup flow."
        case "invalid_arguments":
            message = "Cua rejected the operation arguments. Check the selected operation's required fields and valid ranges before retrying."
        case "type_text_incomplete":
            message = "Cua delivered only part of the text. Read the current field before deciding whether to send the remaining text. Do not repeat the full text blindly."
        case "delivery_failed":
            message = "Cua could not confirm input delivery. Inspect the current desktop and target before deciding whether to retry; input may have partly completed."
        case "background_unavailable":
            message = "Cua cannot use the requested background input route for this target. Choose a supported target or route, then read the current state before acting."
        case "invalid_action_target", "desktop_scope_disabled", "window_scope_disabled", "window_id_required",
             "window_target_resolution_failed", "window_target_not_found", "ambiguous_window_target",
             "window_id_not_found", "window_owner_pid_mismatch", "stale_element_token",
             "screenshot_context_missing", "zoom_context_missing", "px_window_not_found",
             "px_capture_unavailable", "px_frame_mismatch", "bring_to_front_pid_out_of_range",
             "bring_to_front_window_id_out_of_range", "bring_to_front_pid_not_found",
             "bring_to_front_window_not_found", "bring_to_front_window_pid_mismatch",
             "bring_to_front_window_not_ordinary":
            message = "The Cua target is missing, stale, or ambiguous. Discover the current applications and windows again, then read fresh target state before acting."
        default:
            return Self(code: "desktop_cua_failure_unknown",
                        message: "Cua returned an unrecognized failure. Observe the current desktop and target before deciding whether to retry; the action may have partly completed.")
        }
        return Self(code: code, message: message)
    }
}
