package main

import (
	"context"
	"errors"
	"testing"
)

func TestUnreadableRuntimeIntentKeepsLocalControl(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name    string
		enabled bool
		err     error
		want    bool
	}{
		{name: "enabled", enabled: true, want: true},
		{name: "disabled"},
		{name: "unreadable", err: errors.New("private state unreadable"), want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := localControlNeeded(func() (bool, error) { return tc.enabled, tc.err })
			if got != tc.want {
				t.Fatalf("retain local controls = %t, want %t", got, tc.want)
			}
		})
	}
}

func TestUnavailableExternalCredentialsWaitForHelperShutdown(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- runExternalAgents(ctx, false, func(context.Context) error {
			return errors.New("external runner must not start without credentials")
		})
	}()
	select {
	case err := <-done:
		t.Fatalf("external failure shut down local control: %v", err)
	default:
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("credential-free shutdown: %v", err)
	}
}

func TestAvailableExternalCredentialsUseExistingRunner(t *testing.T) {
	t.Parallel()
	want := errors.New("external runner result")
	ctx := context.Background()
	called := false
	err := runExternalAgents(ctx, true, func(got context.Context) error {
		called = true
		if got != ctx {
			t.Fatal("runner context changed")
		}
		return want
	})
	if !called || !errors.Is(err, want) {
		t.Fatalf("existing runner was not preserved: called=%t, err=%v", called, err)
	}
}
