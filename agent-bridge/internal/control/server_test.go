package control

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/personastack/macos/agent-bridge/internal/localcluster"
	"net"
	"sync"
	"testing"
	"time"
)

type scriptedConnection struct {
	input  *bytes.Reader
	output bytes.Buffer
	closed bool
}

func TestBackgroundStopRetainsHelperForActiveLocalSetup(t *testing.T) {
	t.Parallel()
	helper, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	manager, err := localcluster.NewManager(helper, localClusterWorkflowFunc(func(ctx context.Context, _ localcluster.Scope, _ func(localcluster.Progress)) error {
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}), nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = manager.Start(clusterScope())
	if err != nil {
		t.Fatal(err)
	}
	controller, _, _ := fixture(t)
	controller.LocalCluster = manager
	stops, shutdowns := 0, 0
	controller.Stop = func() error { stops++; return nil }
	controller.Shutdown = func() { shutdowns++ }
	connection := &scriptedConnection{input: bytes.NewReader([]byte(`{"version":1,"request_id":"` + uuid.NewString() + `","operation":"stop_background","payload":{}}` + "\n"))}
	handleConnection(context.Background(), connection, controller)
	var response Response
	err = json.Unmarshal(connection.output.Bytes(), &response)
	if err != nil {
		t.Fatal(err)
	}
	if response.Error != nil || response.Result == nil || response.Result.KeepService == nil || !*response.Result.KeepService {
		t.Fatalf("external stop did not preserve active cluster helper: %+v", response)
	}
	if stops != 1 || shutdowns != 0 || !manager.Active() {
		t.Fatalf("consumer stop affected local setup: stops=%d shutdowns=%d active=%t", stops, shutdowns, manager.Active())
	}
}

func (c *scriptedConnection) Read(p []byte) (int, error)       { return c.input.Read(p) }
func (c *scriptedConnection) Write(p []byte) (int, error)      { return c.output.Write(p) }
func (c *scriptedConnection) Close() error                     { c.closed = true; return nil }
func (c *scriptedConnection) LocalAddr() net.Addr              { return nil }
func (c *scriptedConnection) RemoteAddr() net.Addr             { return nil }
func (c *scriptedConnection) SetDeadline(time.Time) error      { return nil }
func (c *scriptedConnection) SetReadDeadline(time.Time) error  { return nil }
func (c *scriptedConnection) SetWriteDeadline(time.Time) error { return nil }
func TestDesktopAgentBridgeStopResponseBeforeShutdown(t *testing.T) {
	t.Parallel()
	controller, _, _ := fixture(t)
	requestID := uuid.NewString()
	connection := &scriptedConnection{input: bytes.NewReader([]byte(`{"version":1,"request_id":"` + requestID + `","operation":"stop_background","payload":{}}` + "\n"))}
	stops, shutdowns := 0, 0
	controller.Stop = func() error { stops++; return nil }
	controller.Shutdown = func() {
		shutdowns++
		var response Response
		if err := json.Unmarshal(connection.output.Bytes(), &response); err != nil {
			t.Fatal("shutdown before response")
		}
		if response.RequestID != requestID || response.Result == nil || response.Result.Disabled == nil || !*response.Result.Disabled {
			t.Fatal("invalid stop response")
		}
	}
	handleConnection(context.Background(), connection, controller)
	if stops != 1 || shutdowns != 1 || !connection.closed {
		t.Fatal("stop lifecycle incomplete")
	}
}
