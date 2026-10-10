package control

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/personastack/macos/agent-bridge/internal/config"
	"github.com/personastack/macos/agent-bridge/internal/runtime"
)

func deadlineRequest(t *testing.T, operation string, payload interface{}) []byte {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(Request{Version: Version, RequestID: uuid.NewString(), Operation: operation, Payload: body})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestDesktopAgentBridgeControlCancellationReleasesOwnerAndExpiresQueuedWork(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	b := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "connection", ConnectionGeneration: 7, TargetSelectionRevision: 9, PersonaMCPToken: "fixture"}
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	var checks atomic.Int32
	c.Check = func(ctx context.Context, current config.Binding) (runtime.Detection, error) {
		if checks.Add(1) != 1 || current.Key() != b.Key() {
			t.Error("expired queued request made protected check")
		}
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > RequestTimeout {
			t.Error("check received helper lifetime context")
		}
		close(started)
		<-ctx.Done()
		return runtime.Detection{}, ctx.Err()
	}
	firstContext, cancelFirst := context.WithCancel(context.Background())
	defer cancelFirst()
	firstDone := make(chan Response, 1)
	check := deadlineRequest(t, "check", BindingPayload{BindingKey: ptrBindingKey(b.Key())})
	go func() { firstDone <- c.Dispatch(firstContext, check) }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("finite check was not dispatched")
	}
	queuedContext, cancelQueued := context.WithCancel(context.Background())
	cancelQueued()
	queuedDone := make(chan Response, 1)
	quiesce := deadlineRequest(t, "quiesce", BindingPayload{BindingKey: ptrBindingKey(b.Key())})
	go func() {
		queuedDone <- c.Dispatch(queuedContext, quiesce)
	}()
	cancelFirst()
	for _, done := range []chan Response{firstDone, queuedDone} {
		select {
		case response := <-done:
			if response.Error == nil || response.Error.Code != "operation_timeout" || response.Result != nil {
				t.Fatal("cancelled owner returned success")
			}
		case <-time.After(time.Second):
			t.Fatal("cancelled check retained controller mutex")
		}
	}
	if current, _ := config.BindingFor(store, b); current.Quiesced || checks.Load() != 1 {
		t.Fatal("expired queued operation mutated admission")
	}
	response := c.Dispatch(context.Background(), deadlineRequest(t, "status", BindingPayload{BindingKey: ptrBindingKey(b.Key())}))
	if response.Error != nil || response.Result == nil || len(response.Result.Connections) != 1 {
		t.Fatal("following finite operation remained blocked")
	}
}

func ptrBindingKey(key config.BindingKey) *config.BindingKey { return &key }

type deadlineConnection struct {
	input                       *bytes.Reader
	output                      bytes.Buffer
	readDeadline, writeDeadline time.Time
	closed                      bool
}

func (c *deadlineConnection) Read(p []byte) (int, error)  { return c.input.Read(p) }
func (c *deadlineConnection) Write(p []byte) (int, error) { return c.output.Write(p) }
func (c *deadlineConnection) Close() error                { c.closed = true; return nil }
func (*deadlineConnection) LocalAddr() net.Addr           { return &net.UnixAddr{Name: "private", Net: "unix"} }
func (*deadlineConnection) RemoteAddr() net.Addr          { return &net.UnixAddr{Name: "owner", Net: "unix"} }
func (*deadlineConnection) SetDeadline(time.Time) error {
	panic("use separate request/read and reply deadlines")
}
func (c *deadlineConnection) SetReadDeadline(deadline time.Time) error {
	c.readDeadline = deadline
	return nil
}
func (c *deadlineConnection) SetWriteDeadline(deadline time.Time) error {
	c.writeDeadline = deadline
	return nil
}

func TestDesktopAgentBridgeSocketOwnerPropagatesWorkAndReplyBudgets(t *testing.T) {
	t.Parallel()
	c, store, _ := fixture(t)
	b := config.Binding{EnvironmentID: "https://app.test", ConnectionID: "connection", ConnectionGeneration: 7, TargetSelectionRevision: 9, PersonaMCPToken: "fixture"}
	if err := store.SaveBinding(b); err != nil {
		t.Fatal(err)
	}
	checked := false
	c.Check = func(ctx context.Context, current config.Binding) (runtime.Detection, error) {
		checked = true
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > RequestTimeout || time.Until(deadline) < RequestTimeout-time.Second || current.Key() != b.Key() {
			t.Fatal("socket passed lifetime/foreign context")
		}
		return runtime.Detection{}, nil
	}
	connection := &deadlineConnection{input: bytes.NewReader(append(deadlineRequest(t, "check", BindingPayload{BindingKey: ptrBindingKey(b.Key())}), '\n'))}
	before := time.Now()
	handleConnection(context.Background(), connection, c)
	if !checked || !connection.closed || connection.writeDeadline.Sub(connection.readDeadline) != 2*time.Second || connection.readDeadline.Before(before.Add(RequestTimeout)) || connection.writeDeadline.Before(before.Add(ConnectionTimeout)) {
		t.Fatal("socket request/reply budgets changed")
	}
	response := Response{}
	if err := json.Unmarshal(connection.output.Bytes(), &response); err != nil || response.Error != nil || response.Result == nil {
		t.Fatal("finite socket response missing", err)
	}
}
