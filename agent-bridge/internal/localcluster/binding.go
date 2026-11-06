package localcluster

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"
)

// TargetBinding is a native-verified canonical target identity. InstallationID
// is SHA-256 of the API-owned 32-byte Ed25519 public key, never key material.
type TargetBinding struct {
	IntegrationID  string `json:"integration_id"`
	InstallationID string `json:"installation_id"`
}

type TargetBindingStatus struct {
	Binding                *TargetBinding `json:"binding,omitempty"`
	Removed                bool           `json:"removed"`
	PreviousRemovedBinding *TargetBinding `json:"previous_removed_binding,omitempty"`
}

func validTargetBinding(binding TargetBinding) bool {
	if len(binding.IntegrationID) == 0 || len(binding.IntegrationID) > 256 || strings.TrimSpace(binding.IntegrationID) == "" || !utf8.ValidString(binding.IntegrationID) {
		return false
	}
	for _, character := range binding.IntegrationID {
		if unicode.IsControl(character) {
			return false
		}
	}
	if len(binding.InstallationID) != 64 || binding.InstallationID != strings.ToLower(binding.InstallationID) {
		return false
	}
	digest, err := hex.DecodeString(binding.InstallationID)
	return err == nil && len(digest) == 32
}

// Binding is private native observation. It never grants cloud authority and
// is not included in scope-free machine status or page progress snapshots.
func (runtime *Runtime) Binding(ctx context.Context, scope Scope) (TargetBindingStatus, error) {
	if !validScope(scope) {
		return TargetBindingStatus{}, ErrInvalidScope
	}
	err := runtime.acquire(ctx)
	if err != nil {
		return TargetBindingStatus{}, err
	}
	defer runtime.release()
	tree, err := runtime.tree(false)
	if errors.Is(err, os.ErrNotExist) {
		return TargetBindingStatus{}, nil
	}
	if err != nil {
		return TargetBindingStatus{}, runtimeCustodyFailure(ctx, err)
	}
	defer tree.directory.Close()
	owner, err := runtime.owner(tree, scope)
	if errors.Is(err, os.ErrNotExist) {
		return TargetBindingStatus{}, runtime.missingOwnerObservation(ctx, tree)
	}
	if err != nil {
		return TargetBindingStatus{}, runtimeCustodyFailure(ctx, err)
	}
	status := TargetBindingStatus{Removed: owner.Removed}
	if owner.Binding != (TargetBinding{}) {
		binding := owner.Binding
		status.Binding = &binding
	}
	if owner.PreviousRemovedBinding != (TargetBinding{}) && owner.PreviousBindingOwner.matches(scope) {
		previous := owner.PreviousRemovedBinding
		status.PreviousRemovedBinding = &previous
	}
	if owner.Removed {
		present, presentErr := runtime.removalPayloadPresent(tree)
		if presentErr != nil {
			return TargetBindingStatus{}, runtimeCustodyFailure(ctx, presentErr)
		}
		status.Removed = !present
	}
	return status, nil
}

func (runtime *Runtime) bindTarget(ctx context.Context, tree *ownedTree, owner runtimeOwner, binding TargetBinding) error {
	if !validTargetBinding(binding) {
		return ErrInvalidManifest
	}
	if owner.Removed {
		return runtimeFailure(ctx, ReasonLocalDataRemoved, fmt.Errorf("local data removal requires explicit new setup"))
	}
	if owner.Binding != (TargetBinding{}) && owner.Binding != binding {
		return runtimeCustodyFailure(ctx, fmt.Errorf("canonical target or installation identity changed"))
	}
	if owner.Binding == binding {
		return nil
	}
	previous := owner.PreviousRemovedBinding
	if previous != (TargetBinding{}) && (previous.IntegrationID == binding.IntegrationID || previous.InstallationID == binding.InstallationID) {
		return runtimeCustodyFailure(ctx, fmt.Errorf("blank setup requires a new target and installation key"))
	}
	owner.Binding = binding
	owner.PreviousRemovedBinding = TargetBinding{}
	owner.PreviousBindingOwner = nativeBindingOwner{}
	return writeRuntimeOwner(tree, owner)
}
