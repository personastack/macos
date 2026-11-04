package localcluster

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"syscall"
	"time"
)

type nativeCommand struct {
	Operation   RuntimeOperation
	Executable  string
	Arguments   []string
	Environment []string
	Input       io.Reader
	Capture     bool
}

type commandOutput struct {
	Stdout []byte
	Stderr []byte
}
type commandRunner interface {
	Run(context.Context, nativeCommand) (commandOutput, error)
}
type processRunner struct{}
type commandExit struct{ Code int }

func (exit *commandExit) Error() string {
	return fmt.Sprintf("native command exited with status %d", exit.Code)
}

const commandOutputLimit = 128 * 1024

func (processRunner) Run(ctx context.Context, command nativeCommand) (commandOutput, error) {
	cmd := exec.CommandContext(ctx, command.Executable, command.Arguments...)
	cmd.Env, cmd.Stdin = command.Environment, command.Input
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Kill the owned process group and synchronously Wait. A detached Lima host
	// agent is stopped separately through the fixed private instance owner.
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	stdout, stderr := boundedOutput{}, boundedOutput{}
	if command.Capture {
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
	} else {
		cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	}
	err := cmd.Run()
	if ctx.Err() != nil {
		return commandOutput{}, fmt.Errorf("native command cancelled: %w", ctx.Err())
	}
	if stdout.overflow || stderr.overflow {
		return commandOutput{}, fmt.Errorf("native command exceeded its output bound")
	}
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return commandOutput{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, &commandExit{Code: exit.ExitCode()}
		}
		return commandOutput{}, fmt.Errorf("native command failed: %w", err)
	}
	return commandOutput{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, nil
}

type boundedOutput struct {
	bytes.Buffer
	overflow bool
}

func (output *boundedOutput) Write(data []byte) (int, error) {
	length := len(data)
	remaining := commandOutputLimit - output.Len()
	if length > remaining {
		data, output.overflow = data[:remaining], true
	}
	_, _ = output.Buffer.Write(data)
	return length, nil
}
