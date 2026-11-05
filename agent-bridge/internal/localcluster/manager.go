package localcluster

import (
	"bytes"
	"context"
	"errors"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
)

// Scope is native-supplied ownership metadata, not cloud authorization.
// DocumentID records the originating document. A reopened document for the same
// app/account/workspace may observe the task without inheriting cloud authority.
type Scope struct {
	AppOrigin   string `json:"app_origin"`
	AccountID   string `json:"account_id"`
	WorkspaceID string `json:"workspace_id"`
	DocumentID  string `json:"document_id"`
}

type Operation string

type Stage string
type State string
type Reason string
type Action string

const (
	OperationInstall  Operation = "install"
	OperationResume   Operation = "resume"
	OperationStop     Operation = "stop"
	OperationApply    Operation = "apply"
	operationRestore  Operation = "restore"
	OperationRemove   Operation = "remove"
	OperationNewSetup Operation = "new_setup"

	StageQueued      Stage = "queued"
	StageDownloading Stage = "downloading"
	StageVerifying   Stage = "verifying"
	StageExtracting  Stage = "extracting"
	StageStarting    Stage = "starting"
	StageChecking    Stage = "checking"
	StageCompleted   Stage = "completed"

	StateNoTask     State = "no_task"
	StateRunning    State = "running"
	StateCancelling State = "cancelling"
	StateCompleted  State = "completed"
	StateInstalled  State = "installed"
	StateFailed     State = "failed"
	StateCancelled  State = "cancelled"

	ReasonStopFailed           Reason = "stop_failed"
	ReasonStateChanged         Reason = "state_changed"
	ReasonStatusUnavailable    Reason = "status_unavailable"
	ReasonLocalDataRemoved     Reason = "local_data_removed"
	ReasonNone                 Reason = ""
	ReasonSetupFailed          Reason = "setup_failed"
	ReasonArtifactUnavailable  Reason = "artifact_unavailable"
	ReasonIntegrityFailed      Reason = "integrity_failed"
	ReasonComponentUnverified  Reason = "component_unverified"
	ReasonLocalDataUnavailable Reason = "local_data_unavailable"
	ReasonPermissionRequired   Reason = "permission_required"
	ReasonResourceUnavailable  Reason = "resource_unavailable"
	ReasonUnsupportedHost      Reason = "unsupported_host"

	ActionNone         Action = "none"
	ActionRetry        Action = "retry"
	ActionOpenSettings Action = "open_settings"
	ActionUpdateApp    Action = "update_app"
	ActionDetails      Action = "details"
)

var (
	ErrBusy            = errors.New("local cluster task is busy")
	ErrInvalidManifest = errors.New("invalid local cluster manifest")
	ErrInvalidBinding  = errors.New("invalid local cluster target binding")
	ErrUnavailable     = errors.New("local cluster workflow unavailable")
	ErrInvalidScope    = errors.New("invalid native local cluster scope")
	ErrOccupied        = errors.New("local cluster task belongs to another owner")
	ErrAttemptChanged  = errors.New("local cluster attempt changed")
)

// Progress counts aggregate input transfer activity, not digest verification or
// API readiness. Cached inputs advance only after their verification succeeds.
// The concrete installer must not regress stages or completed byte counts.
type Progress struct {
	Stage          Stage `json:"stage"`
	CompletedBytes int64 `json:"completed_bytes"`
	TotalBytes     int64 `json:"total_bytes"`
}

type Snapshot struct {
	Operation  Operation `json:"operation,omitempty"`
	AttemptID  string    `json:"attempt_id,omitempty"`
	Scope      Scope     `json:"scope,omitzero"`
	State      State     `json:"state"`
	Progress   Progress  `json:"progress,omitzero"`
	Reason     Reason    `json:"safe_reason,omitempty"`
	Message    string    `json:"safe_message,omitempty"`
	Action     Action    `json:"action"`
	StartedAt  time.Time `json:"started_at,omitzero"`
	UpdatedAt  time.Time `json:"updated_at,omitzero"`
	FinishedAt time.Time `json:"finished_at,omitzero"`
}

// Workflow is the single native installer owner. Install must return only after
// its work and child processes have stopped. Cancellation does not imply rollback.
// The manager never sends bearer credentials, commands, URLs or paths to it.
type Workflow interface {
	Install(context.Context, Scope, func(Progress)) error
}

// RuntimeWorkflow is optional on the same installer owner. All mutations share
// the manager's single task slot. Probe observes only local native state.
type RuntimeWorkflow interface {
	Probe(context.Context, Scope) (RuntimeStatus, error)
	Start(context.Context, Scope) error
	Stop(context.Context) error
	ApplyManifest(context.Context, Scope, TargetBinding, []byte) error
	Binding(context.Context, Scope) (TargetBindingStatus, error)
	RemoveData(context.Context, Scope, TargetBinding) error
	NewSetupAfterRemoval(context.Context, Scope, TargetBinding) error
}

type runtimeRestorer interface{ Restore(context.Context) error }

type MachineStatus struct {
	Installed           bool   `json:"installed"`
	Running             bool   `json:"running"`
	KubernetesAvailable bool   `json:"kubernetes_available"`
	Enabled             bool   `json:"enabled"`
	InstallerActive     bool   `json:"installer_active"`
	Reason              Reason `json:"safe_reason,omitempty"`
	Message             string `json:"message,omitempty"`
	Action              Action `json:"action,omitempty"`
}

type StopResult struct {
	Active bool `json:"active"`
}

const MaxManifestBytes = 192 * 1024

// Failure provides finite installer guidance. Raw error text never enters status.
type Failure struct{ Reason Reason }

func (f *Failure) Error() string { return "local cluster setup failed" }

type installTask struct {
	snapshot Snapshot
	binding  TargetBinding
	cancel   context.CancelFunc
	done     chan struct{}
}

// Manager owns at most one installer task for the helper lifetime. Its lock only
// protects value snapshots. No workflow or cancellation callback runs under it.
type Manager struct {
	ctx         context.Context
	workflow    Workflow
	runtime     RuntimeWorkflow
	owner       Scope
	hasOwner    bool
	quiesced    bool
	cached      MachineStatus
	stopFailure *setupGuidance
	now         func() time.Time
	mu          sync.Mutex
	task        *installTask
}

func NewManager(ctx context.Context, workflow Workflow, now func() time.Time) (*Manager, error) {
	if ctx == nil || workflow == nil {
		return nil, ErrUnavailable
	}
	if now == nil {
		now = time.Now
	}
	runtime, _ := workflow.(RuntimeWorkflow)
	return &Manager{ctx: ctx, workflow: workflow, runtime: runtime, now: now}, nil
}

func (m *Manager) Start(scope Scope) (Snapshot, error) {
	return m.startScoped(scope, OperationInstall, "", TargetBinding{}, nil)
}

func (m *Manager) Resume(scope Scope) (Snapshot, error) {
	return m.startScoped(scope, OperationResume, "", TargetBinding{}, nil)
}

func (m *Manager) Apply(scope Scope, attemptID string, binding TargetBinding, manifest []byte) (Snapshot, error) {
	if len(manifest) == 0 || len(manifest) > MaxManifestBytes || !utf8.Valid(manifest) {
		return Snapshot{}, ErrInvalidManifest
	}
	if !validTargetBinding(binding) {
		return Snapshot{}, ErrInvalidBinding
	}
	return m.startScoped(scope, OperationApply, attemptID, binding, manifest)
}

func (m *Manager) Remove(scope Scope, binding TargetBinding) (Snapshot, error) {
	if binding != (TargetBinding{}) && !validTargetBinding(binding) {
		return Snapshot{}, ErrInvalidBinding
	}
	return m.startScoped(scope, OperationRemove, "", binding, nil)
}

func (m *Manager) NewSetupAfterRemoval(scope Scope, binding TargetBinding) (Snapshot, error) {
	if binding != (TargetBinding{}) && !validTargetBinding(binding) {
		return Snapshot{}, ErrInvalidBinding
	}
	return m.startScoped(scope, OperationNewSetup, "", binding, nil)
}

// Binding is a native-only scoped read. It never changes a task or projects
// cloud authority. The runtime verifies persisted ownership before disclosure.
func (m *Manager) Binding(ctx context.Context, scope Scope) (TargetBindingStatus, error) {
	if !validScope(scope) {
		return TargetBindingStatus{}, ErrInvalidScope
	}
	m.mu.Lock()
	if m.runtime == nil {
		m.mu.Unlock()
		return TargetBindingStatus{}, ErrUnavailable
	}
	if m.hasOwner && !sameOwner(scope, m.owner) {
		m.mu.Unlock()
		return TargetBindingStatus{}, ErrOccupied
	}
	if m.task != nil && active(m.task.snapshot.State) {
		m.mu.Unlock()
		return TargetBindingStatus{}, ErrBusy
	}
	task := m.task
	m.mu.Unlock()
	binding, err := m.runtime.Binding(ctx, scope)
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.task != task {
		return TargetBindingStatus{}, ErrBusy
	}
	return binding, err
}

func (m *Manager) startScoped(scope Scope, operation Operation, attemptID string, binding TargetBinding, manifest []byte) (Snapshot, error) {
	if !validScope(scope) {
		return Snapshot{}, ErrInvalidScope
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.ctx.Err() != nil {
		return Snapshot{}, ErrUnavailable
	}
	if m.quiesced {
		return Snapshot{}, ErrBusy
	}
	if operation != OperationInstall && m.runtime == nil {
		return Snapshot{}, ErrUnavailable
	}
	if m.hasOwner && !sameOwner(scope, m.owner) && operation != OperationNewSetup {
		return Snapshot{}, ErrOccupied
	}
	var previous *installTask
	if m.task != nil && active(m.task.snapshot.State) {
		if m.task.snapshot.Operation == operation && operation != OperationApply && m.task.snapshot.Scope != (Scope{}) && m.task.binding == binding && sameOwner(scope, m.task.snapshot.Scope) {
			return m.task.snapshot, nil
		}
		if operation != OperationRemove {
			return Snapshot{}, ErrBusy
		}
		previous = m.task
	}
	if operation == OperationApply {
		err := m.checkApplyLocked(scope, attemptID, binding)
		if err != nil {
			return Snapshot{}, err
		}
		if m.task.snapshot.Operation == OperationApply && m.task.snapshot.State == StateCompleted {
			return m.task.snapshot, nil
		}
	}
	if !m.hasOwner {
		m.owner, m.hasOwner = scope, true
	}
	return m.launchLocked(scope, operation, previous, binding, bytes.Clone(manifest)), nil
}

func (m *Manager) checkApplyLocked(scope Scope, attemptID string, binding TargetBinding) error {
	if m.task == nil || attemptID != m.task.snapshot.AttemptID {
		return ErrAttemptChanged
	}
	current := m.task.snapshot
	if current.Scope == (Scope{}) || !sameOwner(scope, current.Scope) {
		return ErrAttemptChanged
	}
	switch current.Operation {
	case OperationInstall:
		if current.State == StateInstalled {
			return nil
		}
	case OperationResume:
		if current.State == StateCompleted {
			return nil
		}
	case OperationApply:
		if m.task.binding != binding {
			return ErrAttemptChanged
		}
		if current.State == StateFailed || current.State == StateCompleted {
			return nil
		}
	}
	return ErrAttemptChanged
}

func (m *Manager) launchLocked(scope Scope, operation Operation, previous *installTask, binding TargetBinding, manifest []byte) Snapshot {
	ctx, cancel := context.WithCancel(m.ctx)
	now := m.now().UTC()
	task := &installTask{snapshot: Snapshot{
		Operation: operation, AttemptID: uuid.NewString(), Scope: scope, State: StateRunning,
		Progress: Progress{Stage: StageQueued}, Action: ActionNone,
		StartedAt: now, UpdatedAt: now,
	}, binding: binding, cancel: cancel, done: make(chan struct{})}
	m.task = task
	go m.runTask(ctx, task, previous, manifest)
	return task.snapshot
}

// Stop is a local machine action. Its result never includes another owner's
// task or scope. It joins outstanding installer work before stopping the VM.
func (m *Manager) Stop() (StopResult, error) {
	return m.startMachine(OperationStop)
}

// ResumeLocal restores only retained machine-owned state. It supplies no cloud
// scope or enrollment authority and returns no private owner/task metadata.
func (m *Manager) ResumeLocal() (StopResult, error) {
	return m.startMachine(OperationResume)
}

// RemoveLocal is an explicitly confirmed local OS-owner action. The runtime
// derives its private target and verifies stopped custody without disclosure.
func (m *Manager) RemoveLocal() (StopResult, error) {
	return m.startMachine(OperationRemove)
}

// RestoreLocal is the helper-startup continuation. It consults existing native
// enable intent through Runtime.Restore and never establishes cloud authority.
func (m *Manager) RestoreLocal() error {
	_, err := m.startMachine(operationRestore)
	return err
}

func (m *Manager) startMachine(operation Operation) (StopResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.runtime == nil || m.ctx.Err() != nil {
		return StopResult{}, ErrUnavailable
	}
	if m.quiesced {
		return StopResult{}, ErrBusy
	}
	if operation == operationRestore {
		if _, ok := m.runtime.(runtimeRestorer); !ok {
			return StopResult{}, ErrUnavailable
		}
	}
	var previous *installTask
	if m.task != nil && active(m.task.snapshot.State) {
		if m.task.snapshot.Operation == operation && m.task.snapshot.Scope == (Scope{}) {
			return StopResult{Active: true}, nil
		}
		if operation != OperationStop && operation != OperationRemove {
			return StopResult{}, ErrBusy
		}
		previous = m.task
	}
	m.launchLocked(Scope{}, operation, previous, TargetBinding{}, nil)
	return StopResult{Active: true}, nil
}

func (m *Manager) Active() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.task != nil && active(m.task.snapshot.State)
}

// RuntimeStatus returns generic local observation only. During mutation its
// cached booleans are not stopped proof: InstallerActive remains true.
func (m *Manager) RuntimeStatus(ctx context.Context) (MachineStatus, error) {
	m.mu.Lock()
	if m.runtime == nil {
		m.mu.Unlock()
		return MachineStatus{}, ErrUnavailable
	}
	task := m.task
	if task != nil && active(task.snapshot.State) {
		status := m.machineStatusLocked(true)
		m.mu.Unlock()
		return status, nil
	}
	m.mu.Unlock()
	observed, err := m.runtime.Probe(ctx, Scope{})
	m.mu.Lock()
	defer m.mu.Unlock()
	if task != m.task {
		status := m.machineStatusLocked(m.task != nil && active(m.task.snapshot.State))
		guidance := failureGuidance(&Failure{Reason: ReasonStateChanged})
		status.Reason, status.Message, status.Action = guidance.reason, guidance.message, guidance.action
		return status, nil
	}
	if err != nil {
		status := m.machineStatusLocked(false)
		guidance := failureGuidance(err)
		status.Reason, status.Message, status.Action = guidance.reason, guidance.message, guidance.action
		return status, nil
	}
	m.cached = MachineStatus{Installed: observed.Installed, Running: observed.Running, KubernetesAvailable: observed.KubernetesAvailable, Enabled: observed.Enabled, Action: ActionNone}
	if observed.Reason != ReasonNone {
		guidance := guidanceForReason(observed.Reason)
		m.cached.Reason, m.cached.Message, m.cached.Action = guidance.reason, guidance.message, guidance.action
	}
	return m.machineStatusLocked(false), nil
}

func (m *Manager) machineStatusLocked(busy bool) MachineStatus {
	status := m.cached
	status.InstallerActive = busy
	if m.stopFailure != nil {
		status.Reason, status.Message, status.Action = m.stopFailure.reason, m.stopFailure.message, m.stopFailure.action
	}
	return status
}

// RetainForBackgroundStop atomically fences new mutations after an idle stopped
// readback. A concurrent task or unverified native state retains the helper.
func (m *Manager) RetainForBackgroundStop(ctx context.Context) (bool, error) {
	m.mu.Lock()
	if m.task != nil && active(m.task.snapshot.State) {
		m.mu.Unlock()
		return true, nil
	}
	task := m.task
	hasRuntime := m.runtime != nil
	m.mu.Unlock()
	status := MachineStatus{}
	var err error
	if hasRuntime {
		status, err = m.RuntimeStatus(ctx)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err != nil {
		return true, err
	}
	if ctx.Err() != nil {
		return true, ctx.Err()
	}
	if m.task != task || status.InstallerActive || status.Enabled || status.Running || blockingReason(status.Reason) {
		return true, nil
	}
	m.quiesced = true
	return false, nil
}

// Status without an attempt ID passively discovers this owner's current task.
// NoTask means no task is recorded by this helper. It says nothing about disks
// or an existing installation. A supplied attempt ID must still match exactly.
func (m *Manager) Status(scope Scope, attemptID string) (Snapshot, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	err := m.match(scope, attemptID, true)
	if err != nil {
		return Snapshot{}, err
	}
	if m.task == nil || m.task.snapshot.Scope == (Scope{}) || releasedSetup(m.task, attemptID) {
		return Snapshot{State: StateNoTask, Action: ActionNone}, nil
	}
	return m.task.snapshot, nil
}

// Cancel returns cancelling while the workflow is still stopping. Only workflow
// completion can acknowledge cancelled. Repeated cancellation is safe.
func (m *Manager) Cancel(scope Scope, attemptID string) (Snapshot, error) {
	m.mu.Lock()
	err := m.match(scope, attemptID, false)
	if err != nil {
		m.mu.Unlock()
		return Snapshot{}, err
	}
	task := m.task
	if !active(task.snapshot.State) {
		snapshot := task.snapshot
		m.mu.Unlock()
		return snapshot, nil
	}
	task.snapshot.State = StateCancelling
	task.snapshot.UpdatedAt = m.now().UTC()
	snapshot := task.snapshot
	m.mu.Unlock()
	task.cancel()
	return snapshot, nil
}

func (m *Manager) match(scope Scope, attemptID string, discover bool) error {
	if !validScope(scope) {
		return ErrInvalidScope
	}
	if m.task == nil {
		if discover && attemptID == "" {
			return nil
		}
		return ErrAttemptChanged
	}
	resetOwner := m.task.snapshot.Operation == OperationNewSetup && sameOwner(scope, m.task.snapshot.Scope)
	if m.hasOwner && !sameOwner(scope, m.owner) && !resetOwner {
		return ErrOccupied
	}
	if discover && releasedSetup(m.task, attemptID) {
		return nil
	}
	if m.task.snapshot.Scope != (Scope{}) && !sameOwner(scope, m.task.snapshot.Scope) {
		return ErrOccupied
	}
	if m.task.snapshot.Scope == (Scope{}) {
		if discover && attemptID == "" && !active(m.task.snapshot.State) {
			return nil
		}
		return ErrBusy
	}
	if attemptID != m.task.snapshot.AttemptID && !(discover && attemptID == "") {
		return ErrAttemptChanged
	}
	return nil
}

func (m *Manager) runTask(ctx context.Context, task, previous *installTask, manifest []byte) {
	defer close(task.done)
	defer task.cancel()
	defer clear(manifest)
	if previous != nil {
		previous.cancel()
		<-previous.done
	}
	if ctx.Err() != nil {
		m.finishTask(ctx, task, ctx.Err())
		return
	}
	var err error
	switch task.snapshot.Operation {
	case OperationInstall:
		err = m.workflow.Install(ctx, task.snapshot.Scope, func(progress Progress) { m.report(task, progress) })
	case OperationResume:
		err = m.runtime.Start(ctx, task.snapshot.Scope)
	case OperationApply:
		err = m.runtime.ApplyManifest(ctx, task.snapshot.Scope, task.binding, manifest)
	case OperationRemove:
		err = m.runtime.RemoveData(ctx, task.snapshot.Scope, task.binding)
	case OperationNewSetup:
		err = m.runtime.NewSetupAfterRemoval(ctx, task.snapshot.Scope, task.binding)
	case operationRestore:
		err = m.runtime.(runtimeRestorer).Restore(ctx)
	case OperationStop:
		err = m.runtime.Stop(ctx)
	}
	m.finishTask(ctx, task, err)
}

func (m *Manager) finishTask(ctx context.Context, task *installTask, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.task != task || !active(task.snapshot.State) {
		return
	}
	snapshot := &task.snapshot
	snapshot.UpdatedAt = m.now().UTC()
	snapshot.FinishedAt = snapshot.UpdatedAt
	switch {
	case err == nil:
		snapshot.State, snapshot.Progress.Stage = StateCompleted, StageCompleted
		if snapshot.Operation == OperationInstall {
			snapshot.State = StateInstalled
		}
		if snapshot.Operation == OperationStop || snapshot.Operation == OperationRemove {
			m.stopFailure = nil
		}
		if snapshot.Operation == OperationNewSetup {
			m.owner, m.hasOwner = Scope{}, false
		}
	case snapshot.Operation == OperationStop:
		snapshot.State = StateFailed
		guidance := failureGuidance(err)
		if guidance.reason == ReasonSetupFailed {
			guidance = failureGuidance(&Failure{Reason: ReasonStopFailed})
		}
		m.stopFailure = &guidance
		snapshot.Reason, snapshot.Message, snapshot.Action = guidance.reason, guidance.message, guidance.action
	case errors.Is(err, context.Canceled) && ctx.Err() != nil:
		snapshot.State, snapshot.Action = StateCancelled, ActionRetry
	default:
		snapshot.State = StateFailed
		guidance := failureGuidance(err)
		snapshot.Reason, snapshot.Message, snapshot.Action = guidance.reason, guidance.message, guidance.action
	}
}

func (m *Manager) report(task *installTask, progress Progress) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.task != task || !active(task.snapshot.State) || !validProgress(task.snapshot.Progress, progress) {
		return
	}
	task.snapshot.Progress = progress
	task.snapshot.UpdatedAt = m.now().UTC()
}

func validProgress(previous, next Progress) bool {
	rank := stageRank(next.Stage)
	return rank > 0 && rank >= stageRank(previous.Stage) && next.CompletedBytes >= previous.CompletedBytes &&
		next.TotalBytes >= 0 && (next.TotalBytes == 0 || next.CompletedBytes <= next.TotalBytes)
}

func stageRank(stage Stage) int {
	switch stage {
	case StageQueued:
		return 1
	case StageDownloading:
		return 2
	case StageVerifying:
		return 3
	case StageExtracting:
		return 4
	case StageStarting:
		return 5
	case StageChecking:
		return 6
	default:
		return 0
	}
}

type setupGuidance struct {
	reason  Reason
	message string
	action  Action
}

// This is the sole user-facing installer failure vocabulary. Native consumers
// display the fixed message and action instead of interpreting raw stderr.
var setupGuidanceTable = [...]setupGuidance{
	{ReasonSetupFailed, "Local cluster setup could not finish. Try again.", ActionRetry},
	{ReasonStopFailed, "The local cluster could not stop. Try again.", ActionRetry},
	{ReasonStateChanged, "Local cluster state changed. Check again.", ActionRetry},
	{ReasonStatusUnavailable, "Local runtime status is unavailable. Check again.", ActionRetry},
	{ReasonLocalDataRemoved, "Local cluster files were removed.", ActionNone},
	{ReasonArtifactUnavailable, "A required setup download is unavailable. Try again.", ActionRetry},
	{ReasonIntegrityFailed, "A setup download could not be verified. Try again.", ActionRetry},
	{ReasonComponentUnverified, "The installed app component could not be verified. Update PersonaStack for macOS.", ActionUpdateApp},
	{ReasonLocalDataUnavailable, "Existing local cluster files could not be verified. Review details before continuing.", ActionDetails},
	{ReasonResourceUnavailable, "The Mac does not have enough resources for setup. Try again after freeing resources.", ActionRetry},
	{ReasonPermissionRequired, "A macOS permission is required to continue setup. Open Settings to review it.", ActionOpenSettings},
	{ReasonUnsupportedHost, "This Mac does not support managed local cluster setup.", ActionNone},
}

func failureGuidance(err error) setupGuidance {
	var failure *Failure
	if errors.As(err, &failure) && failure != nil && failure.Reason != ReasonLocalDataRemoved {
		return guidanceForReason(failure.Reason)
	}
	return setupGuidanceTable[0]
}

func guidanceForReason(reason Reason) setupGuidance {
	for _, guidance := range setupGuidanceTable {
		if guidance.reason == reason {
			return guidance
		}
	}
	return setupGuidanceTable[0]
}

func blockingReason(reason Reason) bool {
	return reason != ReasonNone && reason != ReasonLocalDataRemoved
}
func releasedSetup(task *installTask, attemptID string) bool {
	return attemptID == "" && task.snapshot.Operation == OperationNewSetup && task.snapshot.State == StateCompleted
}

func active(state State) bool { return state == StateRunning || state == StateCancelling }
func sameOwner(a, b Scope) bool {
	return a.AppOrigin == b.AppOrigin && a.AccountID == b.AccountID && a.WorkspaceID == b.WorkspaceID
}
func validScope(scope Scope) bool {
	if len(scope.AppOrigin) > 512 {
		return false
	}
	origin, err := url.Parse(scope.AppOrigin)
	if err != nil || (origin.Scheme != "https" && origin.Scheme != "http") || origin.Host == "" ||
		origin.User != nil || origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" {
		return false
	}
	for _, value := range []string{scope.AccountID, scope.WorkspaceID} {
		if len(value) > 256 || strings.TrimSpace(value) == "" || !utf8.ValidString(value) {
			return false
		}
		for _, character := range value {
			if unicode.IsControl(character) {
				return false
			}
		}
	}
	id, err := uuid.Parse(scope.DocumentID)
	return err == nil && id != uuid.Nil
}
