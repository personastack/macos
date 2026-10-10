package pairing

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"github.com/personastack/agent-gateway/pkg/externalagentprotocol"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
	"io"
	"net/http"
	"strings"
	"testing"
)

type desktopTransport func(*http.Request) (*http.Response, error)

func (f desktopTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestDesktopAgentBridgePreparedPairingContract(t *testing.T) {
	t.Parallel()
	private := ed25519.NewKeyFromSeed(make([]byte, 32))
	public := base64.StdEncoding.EncodeToString(private.Public().(ed25519.PublicKey))
	preparation := &externalagentprotocol.DesktopPreparation{PreparationID: "prepared", ProfileCandidateID: "opaque", DevicePublicKey: public}
	calls := 0
	client := Client{GatewayBaseURL: "https://gateway.example", HTTPClient: &http.Client{Transport: desktopTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "POST" || r.Header.Get("Content-Type") != "application/json" || r.URL.Path != "/v1/external-agent/pairing/exchange" {
			t.Fatalf("pairing request %s %s", r.Method, r.URL)
		}
		var p externalagentprotocol.PairingExchangeRequest
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&p); err != nil {
			t.Fatal(err)
		}
		proof, err := base64.StdEncoding.DecodeString(p.DeviceKeyProof)
		if err != nil || !ed25519.Verify(private.Public().(ed25519.PublicKey), []byte(deviceProofMessage(p)), proof) {
			t.Fatal("invalid prepared proof")
		}
		if p.ClientKind != externalagentprotocol.ClientKindMacOSApp || p.DesktopPreparation.PreparationID != "prepared" || p.DevicePublicKey != public {
			t.Fatalf("prepared DTO %+v", p)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"connection_id":"conn","persona_id":"persona","runtime_kind":"hermes","connection_generation":1,"credential_id":"credential","gateway_websocket_url":"wss://gateway.example/v1/external-agents/connect"}`)), Header: make(http.Header)}, nil
	})}}
	result, err := client.Exchange(context.Background(), Request{Code: "ABCD", RuntimeKind: runtime.AdapterKindHermes, PrivateKey: private, DesktopPreparation: preparation})
	if err != nil || result.Binding.BridgePublicKey != public || calls != 1 {
		t.Fatalf("exchange %+v %v", result, err)
	}
	preparation.DevicePublicKey = "other"
	if _, err = client.Exchange(context.Background(), Request{Code: "ABCD", RuntimeKind: runtime.AdapterKindHermes, PrivateKey: private, DesktopPreparation: preparation}); err == nil || calls != 1 {
		t.Fatal("wrong preparation reached exchange")
	}
}
