package control

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"net"
	"testing"
	"time"
)

type scriptedConnection struct {
	input  *bytes.Reader
	output bytes.Buffer
	closed bool
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
