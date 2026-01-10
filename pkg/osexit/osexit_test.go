// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

package osexit_test

import (
	"os"
	"testing"

	"espra.dev/pkg/osexit"
)

var exit = os.Exit

func TestExit(t *testing.T) {
	exit = osexit.Set()
	exit(2)
	if !osexit.Called() {
		t.Fatalf("mock exit function was not called")
	}
	status := osexit.Status()
	if status != 2 {
		t.Fatalf("mock exit function did not set the right status code: got %d, want 2", status)
	}
	exit(3)
	status = osexit.Status()
	if status != 2 {
		t.Fatalf("mock exit function overrode the status set by a previous call: got %d, want 2", status)
	}
	osexit.Reset()
	if osexit.Called() {
		t.Fatalf("the reset mock exit function claims to have been called")
	}
	status = osexit.Status()
	if status != 0 {
		t.Fatalf("the reset mock exit function returned a non-zero status code: got %d, want 0", status)
	}
}
