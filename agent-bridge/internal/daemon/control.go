package daemon

import (
	"context"
	"fmt"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/hermessetup"
	"github.com/personastack/macos/agent-bridge/internal/mcp"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"net/url"
	"strings"
)

func targetForBinding(b config.Binding) *externalagentprotocol.RuntimeTarget {
	k := externalagentprotocol.RuntimeKindHermes
	if b.RuntimeKind == runtime.AdapterKindOpenClaw {
		k = externalagentprotocol.RuntimeKindOpenClaw
	}
	return &externalagentprotocol.RuntimeTarget{AccountCandidateID: b.AccountCandidateID, ProfileCandidateID: b.ProfileCandidateID, RuntimeKind: k, SelectionRevision: b.TargetSelectionRevision}
}

// CheckBinding does not mutate config or start a runtime/model run.
func (r Runner) CheckBinding(ctx context.Context, b config.Binding) (runtime.Detection, error) {
	latest, ok := config.BindingFor(r.Store, b)
	if !ok || latest.ConnectionGeneration != b.ConnectionGeneration {
		return runtime.Detection{}, fmt.Errorf("scope_changed: binding changed")
	}
	if latest.PersonaMCPSecretUnavailable {
		return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateAuthMissing, DiagnosticCode: "credential_unavailable", Note: "Allow this helper to read its stored Keychain credential before retrying."}, nil
	}
	if config.PersonaMCPReconnectRequired(latest) {
		return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateAuthMissing, DiagnosticCode: "reconnect_required", Note: "Disconnect and reconnect to renew PersonaStack MCP authorization."}, nil
	}
	if required, err := r.checkPersonaMCPCredentialUnlessOpenClaw(ctx, latest); err != nil {
		return runtime.Detection{}, err
	} else if required {
		return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateAuthMissing, DiagnosticCode: "reconnect_required", Note: "Disconnect and reconnect to renew PersonaStack MCP authorization."}, nil
	}

	if b.TargetSelectionRevision <= 0 {
		return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateTargetSelectionRequired}, nil
	}
	adapter, resolved, err := r.targetAdapter(b, targetForBinding(b))
	if err != nil {
		return runtime.Detection{}, err
	}
	endpoint, err := r.targetRuntimeURL(b, targetForBinding(b))
	if err != nil {
		return runtime.Detection{}, err
	}
	owned, err := r.verifyRuntimeEndpoint(ctx, endpoint, resolved, b.RuntimeKind)
	if err != nil {
		return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateRuntimeStopped}, err
	}
	if b.RuntimeKind == runtime.AdapterKindOpenClaw {
		enabled, err := mcp.OpenClawAppsEnabled(b.NativeConfigPath)
		if err != nil {
			return runtime.Detection{}, err
		}
		if !enabled {
			return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateCapabilityMissing, DiagnosticCode: "mcp_apps_disabled", Note: "Enable MCP Apps for this OpenClaw profile to verify its PersonaStack tools."}, nil
		}
	}
	if !owned {
		if b.RuntimeKind == runtime.AdapterKindHermes {
			return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateRuntimeStopped, DiagnosticCode: "hermes_host_consent_required", Note: "Confirm shared Hermes gateway startup before changing its host API configuration."}, nil
		}
		return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateRuntimeStopped}, nil
	}
	return r.bindingReadinessAtHomeContext(ctx, adapter, b, resolved.HomeDir, resolved.HermesHome, endpoint), nil
}
func (r Runner) RepairBinding(ctx context.Context, b config.Binding, restartConfirmed, openClawAppsConfirmed, hermesHostConfirmed bool) error {
	if !restartConfirmed {
		return fmt.Errorf("runtime_conflict: native consent required before profile repair")
	}
	latest, ok := config.BindingFor(r.Store, b)
	if !ok || latest.ConnectionGeneration != b.ConnectionGeneration || latest.TargetSelectionRevision != b.TargetSelectionRevision {
		return fmt.Errorf("scope_changed: binding changed")
	}
	if latest.TargetSelectionRevision <= 0 {
		return fmt.Errorf("scope_changed: API-selected target required before repair")
	}
	if latest.ActiveRunID != "" || latest.Quiesced {
		return fmt.Errorf("busy: assigned run or quiesce prevents repair")
	}
	if latest.PersonaMCPSecretUnavailable {
		return fmt.Errorf("credential_unavailable: stored Keychain credential cannot be read")
	}
	if config.PersonaMCPReconnectRequired(latest) {
		return fmt.Errorf("reconnect_required: Disconnect and reconnect to renew PersonaStack MCP authorization")
	}
	if latest.RuntimeKind == runtime.AdapterKindOpenClaw {
		resolved, err := r.resolveTarget(latest, targetForBinding(latest))
		if err != nil {
			return err
		}
		endpoint, err := r.targetRuntimeURL(latest, targetForBinding(latest))
		if err != nil {
			return err
		}
		// No listener means consented startup may proceed. A running selected
		// gateway must prove its actual loopback bind before enabling Apps.
		if _, err = r.verifyRuntimeEndpoint(ctx, endpoint, resolved, latest.RuntimeKind); err != nil {
			return err
		}
		enabled, err := mcp.OpenClawAppsEnabled(latest.NativeConfigPath)
		if err != nil {
			return err
		}
		if !enabled && !openClawAppsConfirmed {
			return fmt.Errorf("mcp_apps_disabled: explicit native MCP Apps consent required")
		}
	}
	if required, err := r.checkPersonaMCPCredentialUnlessOpenClaw(ctx, latest); err != nil {
		return err
	} else if required {
		return fmt.Errorf("reconnect_required: Disconnect and reconnect to renew PersonaStack MCP authorization")
	}
	hermesHostStopped := false
	if latest.RuntimeKind == runtime.AdapterKindHermes {
		resolved, err := r.resolveTarget(latest, targetForBinding(latest))
		if err != nil {
			return err
		}
		endpoint, err := r.targetRuntimeURL(latest, targetForBinding(latest))
		if err != nil {
			return err
		}
		owned, err := r.verifyRuntimeEndpoint(ctx, endpoint, resolved, latest.RuntimeKind)
		if err != nil {
			return err
		}
		hermesHostStopped = !owned
		if hermesHostStopped && !hermesHostConfirmed {
			return fmt.Errorf("hermes_host_consent_required: explicit shared gateway consent required")
		}
	}
	return config.UpdateBinding(r.Store, b, func(current *config.Binding) error {
		if current.ConnectionGeneration != latest.ConnectionGeneration || current.TargetSelectionRevision != latest.TargetSelectionRevision || current.PersonaMCPToken != latest.PersonaMCPToken {
			return fmt.Errorf("scope_changed: binding changed during repair")
		}
		if current.ActiveRunID != "" || current.Quiesced {
			return fmt.Errorf("busy: assigned run or quiesce prevents repair")
		}
		if current.RuntimeKind == runtime.AdapterKindHermes {
			resolved, err := r.resolveTarget(*current, targetForBinding(*current))
			if err != nil {
				return err
			}
			selected := hermessetup.ResolvePaths(resolved.HomeDir, resolved.HermesHome)
			if hermesHostStopped {
				host, err := hermessetup.HostPaths(selected, resolved.ProfileName)
				if err != nil {
					return err
				}
				endpoint, err := hermessetup.APIEndpoint(host)
				if err != nil {
					return err
				}
				err = hermessetup.EnsureHostAPI(host, endpoint)
				if err != nil {
					return err
				}
			}
			err = hermessetup.EnsureProfileAPIKey(selected, resolved.ProfileName)
			if err != nil {
				return err
			}
		}
		if _, err := mcp.ConfigureBinding(current, true, openClawAppsConfirmed); err != nil {
			return err
		}
		current.RuntimeLaunchAllowed = restartConfirmed
		if current.RuntimeKind == runtime.AdapterKindHermes {
			current.RuntimeLaunchAllowed = hermesHostConfirmed
			current.ReadinessState = runtime.AdapterStateCapabilityMissing
			current.ReadinessDiagnosticCode = "capability_missing"
		}
		if current.RuntimeKind == runtime.AdapterKindOpenClaw {
			current.OpenClawSetupPending = true
			current.OpenClawReadinessSession = runtime.OpenClawSessionIdentity{}
		}
		return nil
	})
}

func (r Runner) checkPersonaMCPCredentialUnlessOpenClaw(ctx context.Context, b config.Binding) (bool, error) {
	if b.RuntimeKind == runtime.AdapterKindOpenClaw {
		return false, nil
	}
	return r.checkPersonaMCPCredential(ctx, b)
}

// Canonical refresh metadata is authority from the authenticated gateway session.
// The protocol does not carry token material. Missing tokens require native
// scoped disconnect and fresh enrollment instead of claiming repair succeeded.
func (r Runner) applyMCPConfiguration(binding config.Binding, p *externalagentprotocol.ConfigRefreshPayload) error {
	if p == nil {
		return nil
	}
	if p.MCPURL != "" {
		parsed, err := url.Parse(p.MCPURL)
		if err != nil || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" || (parsed.Scheme != "https" && parsed.Scheme != "http") {
			return fmt.Errorf("invalid canonical MCP URL")
		}
	}
	for _, value := range []string{p.NativeMCPServerName, p.NativeMCPToolNamespace} {
		if len(value) > 128 || strings.ContainsAny(value, "\r\n\x00") {
			return fmt.Errorf("invalid canonical MCP server metadata")
		}
	}
	return config.UpdateBinding(r.Store, binding, func(latest *config.Binding) error {
		if latest.ConnectionGeneration != binding.ConnectionGeneration {
			return fmt.Errorf("stale connection generation")
		}
		if p.MCPURL != "" {
			latest.PersonaMCPURL = p.MCPURL
		}
		if p.NativeMCPServerName != "" {
			latest.NativeMCPServer = p.NativeMCPServerName
		}
		if p.NativeMCPToolNamespace != "" {
			latest.NativeMCPNamespace = p.NativeMCPToolNamespace
		}
		return nil
	})
}

func (r Runner) checkPersonaMCPCredential(ctx context.Context, b config.Binding) (bool, error) {
	verification := mcp.VerifyBindingLive(ctx, b, r.MCPHTTPClient)
	if verification.DiagnosticCode != "mcp_token_missing" && verification.DiagnosticCode != "mcp_token_rejected" {
		return false, nil
	}
	err := config.UpdateBinding(r.Store, b, func(latest *config.Binding) error {
		if latest.ConnectionGeneration != b.ConnectionGeneration {
			return fmt.Errorf("scope_changed: binding changed")
		}
		latest.ReadinessDiagnosticCode = "reconnect_required"
		return nil
	})
	return true, err
}
