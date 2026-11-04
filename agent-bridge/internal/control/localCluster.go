package control

import (
	"context"
	"errors"

	"github.com/personastack/macos/agent-bridge/internal/localcluster"
)

type LocalClusterStartPayload struct {
	Scope localcluster.Scope `json:"scope"`
}

type LocalClusterAttemptPayload struct {
	Scope     localcluster.Scope `json:"scope"`
	AttemptID string             `json:"attempt_id,omitempty"`
}

type LocalClusterApplyPayload struct {
	Scope     localcluster.Scope         `json:"scope"`
	AttemptID string                     `json:"attempt_id"`
	Manifest  string                     `json:"manifest"`
	Binding   localcluster.TargetBinding `json:"binding"`
}

func localClusterOperation(operation string) bool {
	switch operation {
	case "local_cluster_start", "local_cluster_status", "local_cluster_cancel", "local_cluster_runtime_status", "local_cluster_runtime_stop", "local_cluster_runtime_resume", "local_cluster_apply", "local_cluster_binding", "local_cluster_remove", "local_cluster_new_setup":
		return true
	default:
		return false
	}
}

func (c *Controller) performLocalCluster(ctx context.Context, request Request) (Result, error) {
	switch request.Operation {
	case "local_cluster_runtime_status", "local_cluster_runtime_stop":
		return c.performLocalMachine(ctx, request)
	case "local_cluster_start", "local_cluster_runtime_resume":
		return c.performLocalScopedStart(request)
	case "local_cluster_apply":
		return c.performLocalApply(request)
	case "local_cluster_binding":
		return c.performLocalBinding(ctx, request)
	case "local_cluster_remove", "local_cluster_new_setup":
		return c.performLocalTargetMutation(request)
	default:
		return c.performLocalTask(request)
	}
}

func (c *Controller) performLocalScopedStart(request Request) (Result, error) {
	payload := LocalClusterStartPayload{}
	err := strict(request.Payload, &payload)
	if err != nil {
		return Result{}, err
	}
	if c.LocalCluster == nil {
		return Result{}, localClusterError(localcluster.ErrUnavailable)
	}
	if request.Operation == "local_cluster_runtime_resume" && payload.Scope == (localcluster.Scope{}) {
		accepted, err := c.LocalCluster.ResumeLocal()
		if err != nil {
			return Result{}, localClusterError(err)
		}
		return Result{LocalClusterStop: &accepted}, nil
	}
	var snapshot localcluster.Snapshot
	if request.Operation == "local_cluster_start" {
		snapshot, err = c.LocalCluster.Start(payload.Scope)
	} else {
		snapshot, err = c.LocalCluster.Resume(payload.Scope)
	}
	return localClusterTaskResult(snapshot, err)
}

func (c *Controller) performLocalApply(request Request) (Result, error) {
	payload := LocalClusterApplyPayload{}
	err := strict(request.Payload, &payload)
	if err != nil {
		return Result{}, err
	}
	if !validUUID(payload.AttemptID) {
		return Result{}, issue("invalid_request", "Current local cluster attempt required.")
	}
	if c.LocalCluster == nil {
		return Result{}, localClusterError(localcluster.ErrUnavailable)
	}
	snapshot, err := c.LocalCluster.Apply(payload.Scope, payload.AttemptID, payload.Binding, []byte(payload.Manifest))
	return localClusterTaskResult(snapshot, err)
}

type LocalClusterTargetPayload struct {
	Scope   localcluster.Scope         `json:"scope"`
	Binding localcluster.TargetBinding `json:"binding"`
}

func (c *Controller) performLocalBinding(ctx context.Context, request Request) (Result, error) {
	payload := LocalClusterStartPayload{}
	err := strict(request.Payload, &payload)
	if err != nil {
		return Result{}, err
	}
	if c.LocalCluster == nil {
		return Result{}, localClusterError(localcluster.ErrUnavailable)
	}
	binding, err := c.LocalCluster.Binding(ctx, payload.Scope)
	if err != nil {
		return Result{}, localClusterError(err)
	}
	return Result{LocalClusterBinding: &binding}, nil
}

func (c *Controller) performLocalTargetMutation(request Request) (Result, error) {
	payload := LocalClusterTargetPayload{}
	err := strict(request.Payload, &payload)
	if err != nil {
		return Result{}, err
	}
	if c.LocalCluster == nil {
		return Result{}, localClusterError(localcluster.ErrUnavailable)
	}
	if request.Operation == "local_cluster_remove" && payload.Scope == (localcluster.Scope{}) {
		if payload.Binding != (localcluster.TargetBinding{}) {
			return Result{}, localClusterError(localcluster.ErrInvalidScope)
		}
		accepted, err := c.LocalCluster.RemoveLocal()
		if err != nil {
			return Result{}, localClusterError(err)
		}
		return Result{LocalClusterStop: &accepted}, nil
	}
	var snapshot localcluster.Snapshot
	switch request.Operation {
	case "local_cluster_remove":
		snapshot, err = c.LocalCluster.Remove(payload.Scope, payload.Binding)
	case "local_cluster_new_setup":
		snapshot, err = c.LocalCluster.NewSetupAfterRemoval(payload.Scope, payload.Binding)
	}
	return localClusterTaskResult(snapshot, err)
}

func (c *Controller) performLocalTask(request Request) (Result, error) {
	payload := LocalClusterAttemptPayload{}
	err := strict(request.Payload, &payload)
	if err != nil {
		return Result{}, err
	}
	needsAttempt := request.Operation == "local_cluster_cancel" || payload.AttemptID != ""
	if needsAttempt && !validUUID(payload.AttemptID) {
		return Result{}, issue("invalid_request", "Current local cluster attempt required.")
	}
	if c.LocalCluster == nil {
		return Result{}, localClusterError(localcluster.ErrUnavailable)
	}
	var snapshot localcluster.Snapshot
	if request.Operation == "local_cluster_status" {
		snapshot, err = c.LocalCluster.Status(payload.Scope, payload.AttemptID)
	} else {
		snapshot, err = c.LocalCluster.Cancel(payload.Scope, payload.AttemptID)
	}
	return localClusterTaskResult(snapshot, err)
}

func localClusterTaskResult(snapshot localcluster.Snapshot, err error) (Result, error) {
	if err != nil {
		return Result{}, localClusterError(err)
	}
	return Result{LocalCluster: &snapshot}, nil
}

func (c *Controller) performLocalMachine(ctx context.Context, request Request) (Result, error) {
	payload := struct{}{}
	err := strict(request.Payload, &payload)
	if err != nil {
		return Result{}, err
	}
	if c.LocalCluster == nil {
		return Result{}, localClusterError(localcluster.ErrUnavailable)
	}
	if request.Operation == "local_cluster_runtime_status" {
		status, err := c.LocalCluster.RuntimeStatus(ctx)
		if err != nil {
			return Result{}, localClusterError(err)
		}
		return Result{LocalClusterRuntime: &status}, nil
	}
	status, err := c.LocalCluster.Stop()
	if err != nil {
		return Result{}, localClusterError(err)
	}
	return Result{LocalClusterStop: &status}, nil
}

func localClusterError(err error) error {
	switch {
	case errors.Is(err, localcluster.ErrBusy):
		return issue("busy", "Wait for the current local cluster operation to finish.")
	case errors.Is(err, localcluster.ErrInvalidBinding):
		return issue("invalid_request", "A current local cluster target binding is required.")
	case errors.Is(err, localcluster.ErrInvalidManifest):
		return issue("invalid_request", "A bounded setup manifest is required.")
	case errors.Is(err, localcluster.ErrUnavailable):
		return issue("runtime_unsupported", "Managed local cluster setup is unavailable.")
	case errors.Is(err, localcluster.ErrOccupied):
		return issue("runtime_occupied", "Managed local cluster setup is occupied.")
	case errors.Is(err, localcluster.ErrAttemptChanged):
		return issue("attempt_changed", "Current local cluster attempt required.")
	default:
		return issue("invalid_request", "Valid native local cluster scope required.")
	}
}
