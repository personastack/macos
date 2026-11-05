package localcluster

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type pausedArtifactBody struct {
	ctx       context.Context
	ready     chan struct{}
	data      chan struct{}
	paused    chan struct{}
	eof       chan struct{}
	dataOnce  sync.Once
	eofOnce   sync.Once
	entered   bool
	delivered bool
	closed    atomic.Bool
}

func newPausedArtifactBody() *pausedArtifactBody {
	return &pausedArtifactBody{ready: make(chan struct{}), data: make(chan struct{}), paused: make(chan struct{}), eof: make(chan struct{})}
}
func (body *pausedArtifactBody) Read(p []byte) (int, error) {
	if !body.entered {
		body.entered = true
		close(body.ready)
	}
	if !body.delivered {
		select {
		case <-body.ctx.Done():
			return 0, body.ctx.Err()
		case <-body.data:
		}
		body.delivered = true
		return copy(p, strings.Repeat("x", 1024)), nil
	}
	select {
	case <-body.paused:
	default:
		close(body.paused)
	}
	select {
	case <-body.ctx.Done():
		return 0, body.ctx.Err()
	case <-body.eof:
		return 0, io.EOF
	}
}
func (body *pausedArtifactBody) Close() error { body.closed.Store(true); return nil }
func (body *pausedArtifactBody) provide()     { body.dataOnce.Do(func() { close(body.data) }) }
func (body *pausedArtifactBody) finish()      { body.eofOnce.Do(func() { close(body.eof) }) }
func awaitTransfer(t *testing.T, channel <-chan struct{}) {
	t.Helper()
	select {
	case <-channel:
	case <-time.After(time.Second):
		t.Fatal("transfer did not reach expected boundary")
	}
}

func TestManagerReportsActualBytesAndActivityBeforeDownloadEOF(t *testing.T) {
	t.Parallel()
	for _, cancelTransfer := range []bool{false, true} {
		t.Run(map[bool]string{false: "unverified EOF", true: "canceled transfer"}[cancelTransfer], func(t *testing.T) {
			t.Parallel()
			fixture := newRuntimeFixture(t)
			body := newPausedArtifactBody()
			t.Cleanup(func() { body.provide(); body.finish() })
			var requests atomic.Int32
			pin := PinnedDescriptor().Artifacts[1]
			fixture.runtime.dependencies.fetch = acquireArtifact
			fixture.runtime.dependencies.client = &http.Client{Transport: artifactTransport(func(request *http.Request) (*http.Response, error) {
				requests.Add(1)
				if request.Method != http.MethodGet || request.URL.String() != pin.URL || request.Header.Get("Authorization") != "" {
					t.Error("unexpected download request")
				}
				body.ctx = request.Context()
				return &http.Response{StatusCode: http.StatusOK, ContentLength: -1, Body: body}, nil
			})}
			parent, cancel := context.WithCancel(context.Background())
			t.Cleanup(cancel)
			clock := &atomic.Int64{}
			clock.Store(100)
			manager, err := NewManager(parent, fixture.runtime, func() time.Time { return time.Unix(clock.Load(), 0) })
			if err != nil {
				t.Fatal(err)
			}
			task, err := manager.Start(runtimeTestScope())
			if err != nil {
				t.Fatal(err)
			}
			awaitTransfer(t, body.ready)
			before, err := manager.Status(runtimeTestScope(), task.AttemptID)
			if err != nil || before.Progress.CompletedBytes != 0 {
				t.Fatal("transfer advanced before body bytes")
			}
			deadline, ok := body.ctx.Deadline()
			if !ok {
				t.Fatal("production download deadline missing")
			}
			clock.Store(110)
			body.provide()
			awaitTransfer(t, body.paused)
			activity, err := manager.Status(runtimeTestScope(), task.AttemptID)
			if err != nil || activity.State != StateRunning || activity.Progress.Stage != StageDownloading || activity.Progress.CompletedBytes != 1024 || activity.Progress.TotalBytes != 870442303 || !activity.UpdatedAt.Equal(time.Unix(110, 0)) || !activity.UpdatedAt.After(before.UpdatedAt) {
				t.Fatalf("body activity missing before EOF: %+v %v", activity, err)
			}
			unchanged, _ := body.ctx.Deadline()
			if !deadline.Equal(unchanged) {
				t.Fatal("byte activity reset download deadline")
			}
			clock.Store(120)
			if cancelTransfer {
				_, err = manager.Cancel(runtimeTestScope(), task.AttemptID)
				if err != nil {
					t.Fatal(err)
				}
			} else {
				body.finish()
			}
			awaitTask(t, manager)
			finished, err := manager.Status(runtimeTestScope(), task.AttemptID)
			if err != nil {
				t.Fatal(err)
			}
			if cancelTransfer {
				if finished.State != StateCancelled {
					t.Fatalf("canceled transfer: %+v", finished)
				}
			} else if finished.State != StateFailed || finished.Reason != ReasonIntegrityFailed {
				t.Fatalf("received bytes incorrectly implied verification: %+v", finished)
			}
			if requests.Load() != 1 || !body.closed.Load() || finished.Progress.Stage != StageDownloading || fixture.running {
				t.Fatal("failed transfer escaped download stage or left transport/VM active")
			}
			_, err = os.Stat(filepath.Join(fixture.runtime.options.Root, "l", InstanceName, "disk"))
			if !errors.Is(err, os.ErrNotExist) {
				t.Fatal("unverified transfer created a VM disk")
			}
		})
	}
}

func TestInstallerAggregatesTransferWithPriorVerifiedInputs(t *testing.T) {
	t.Parallel()
	fixture := newRuntimeFixture(t)
	original := fixture.runtime.dependencies.fetch
	fixture.runtime.dependencies.fetch = func(ctx context.Context, tree *ownedTree, client *http.Client, pin Artifact, report func(int64)) error {
		report(17)
		return original(ctx, tree, client, pin, report)
	}
	var received []int64
	err := fixture.runtime.Install(context.Background(), runtimeTestScope(), func(progress Progress) {
		if progress.Stage == StageDownloading {
			received = append(received, progress.CompletedBytes)
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	var transferring []int64
	for _, value := range received {
		if value == 17 || value == 620224512+17 || value == 620224512+73728162+17 {
			transferring = append(transferring, value)
		}
	}
	if !reflect.DeepEqual(transferring, []int64{17, 620224512 + 17, 620224512 + 73728162 + 17}) {
		t.Fatalf("transfer bytes lost prior verified inputs: %v", received)
	}
}

func TestTransferNotificationsAreThrottledAndClamped(t *testing.T) {
	t.Parallel()
	var activity []int64
	transfer := artifactTransfer{reader: strings.NewReader("abc"), limit: 2, report: func(n int64) { activity = append(activity, n) }}
	buffer := make([]byte, 1)
	_, err := transfer.Read(buffer)
	if err != nil {
		t.Fatal(err)
	}
	transfer.last = time.Now().Add(time.Hour)
	_, err = transfer.Read(buffer)
	if err != nil {
		t.Fatal(err)
	}
	transfer.last = time.Now().Add(-time.Second)
	_, err = transfer.Read(buffer)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(activity, []int64{1, 2}) {
		t.Fatalf("transfer callback was unbounded or unthrottled: %v", activity)
	}
}
