package daemon

import (
	"context"
	"fmt"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/hermessetup"
	"github.com/personastack/macos/agent-bridge/internal/mcp"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"github.com/personastack/macos/agent-bridge/internal/targetruntime"
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
	owned, err := targetruntime.VerifyEndpoint(ctx, endpoint, resolved.StateRoot, resolved.ConfigPath, b.RuntimeKind.String())
	if err != nil || !owned {
		return runtime.Detection{Kind: b.RuntimeKind, State: runtime.AdapterStateRuntimeStopped}, err
	}
	return r.bindingReadinessAtHomeContext(ctx, adapter, b, resolved.HomeDir, resolved.HermesHome, endpoint), nil
}
func (r Runner) RepairBinding(ctx context.Context, b config.Binding, restartConfirmed bool) error {
	if b.TargetSelectionRevision <= 0 {
		return fmt.Errorf("scope_changed: API-selected target required before repair")
	}
	latest, ok := config.BindingFor(r.Store, b)
	if !ok || latest.ConnectionGeneration != b.ConnectionGeneration {
		return fmt.Errorf("scope_changed: binding changed")
	}
	if latest.ActiveRunID != "" {
		return fmt.Errorf("busy: assigned run active")
	}
	latest.RuntimeLaunchAllowed = restartConfirmed
	writer, ok := r.Store.(config.WritableStore)
	if !ok {
		return fmt.Errorf("writable bridge store required")
	}
	err := writer.SaveBinding(latest)
	if err != nil {
		return err
	}
	if latest.RuntimeKind == runtime.AdapterKindHermes {
		endpoint, err := r.targetRuntimeURL(latest, targetForBinding(latest))
		if err != nil {
			return err
		}
		_, err = hermessetup.EnsureAPISetupForPathsAt(hermessetup.ResolvePaths("", latest.HermesHome), endpoint)
		if err != nil {
			return err
		}
	}
	// Explicit repair may replace a missing exact owned entry, but never a user edit.
	_, err = (mcp.Installer{Store: r.Store}).InstallBinding(latest)
	return err
}
