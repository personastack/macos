package control

import (
	"context"
	"testing"

	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

func TestQuiesceAndResumePreservePendingNativeSetup(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	binding := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "connection", PersonaID: "persona", RuntimeKind: runtime.AdapterKindOpenClaw, ConnectionGeneration: 2, OpenClawSetupPending: true, RuntimeLaunchAllowed: true}
	err := store.SaveBinding(binding)
	if err != nil {
		t.Fatal(err)
	}
	for _, operation := range []string{"quiesce", "resume"} {
		response := request(t, c, operation, `{}`)
		if response.Error != nil {
			t.Fatal(response.Error)
		}
		current, ok := store.BindingKey(binding.Key())
		if !ok || !current.OpenClawSetupPending || !current.RuntimeLaunchAllowed {
			t.Fatalf("%s discarded previously authorized native setup", operation)
		}
		if current.Quiesced != (operation == "quiesce") {
			t.Fatalf("%s did not change admission", operation)
		}
	}
}

func TestCheckCannotReportQuiescedBindingReady(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	binding := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "connection", PersonaID: "persona", RuntimeKind: runtime.AdapterKindHermes, ConnectionGeneration: 2, PersonaMCPToken: "fixture", ReadinessState: runtime.AdapterStateMCPVerified}
	err := store.SaveBinding(binding)
	if err != nil {
		t.Fatal(err)
	}
	checks := 0
	c.Check = func(context.Context, config.Binding) (runtime.Detection, error) {
		checks++
		return runtime.Detection{Kind: runtime.AdapterKindHermes, State: runtime.AdapterStateMCPVerified}, nil
	}
	response := request(t, c, "quiesce", `{}`)
	if response.Error != nil {
		t.Fatal(response.Error)
	}
	for _, operation := range []string{"status", "check"} {
		response = request(t, c, operation, `{}`)
		if response.Error != nil || len(response.Result.Connections) != 1 {
			t.Fatalf("%s failed: %+v", operation, response)
		}
		row := response.Result.Connections[0]
		if row.ReadinessState != "unavailable" || row.DiagnosticCode != "busy" || checks != 0 {
			t.Fatalf("%s ignored paused admission: %+v, probes %d", operation, row, checks)
		}
	}
	response = request(t, c, "resume", `{}`)
	if response.Error != nil {
		t.Fatal(response.Error)
	}
	response = request(t, c, "check", `{}`)
	if response.Error != nil || response.Result.Connections[0].ReadinessState != "mcp_verified" || checks != 1 {
		t.Fatalf("resumed check did not verify the profile: %+v", response)
	}
}
