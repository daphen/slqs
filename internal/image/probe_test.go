package image

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"
)

func TestProbeKittyGraphics_TimeoutFails(t *testing.T) {
	t.Setenv("TMUX", "")
	r := blockingReader{}
	var w bytes.Buffer
	ok := ProbeKittyGraphics(&w, r, 50*time.Millisecond)
	if ok {
		t.Error("expected probe to fail on timeout")
	}
	if !strings.Contains(w.String(), "\x1b_G") {
		t.Errorf("expected \\e_G in probe output, got %q", w.String())
	}
}

func TestProbeKittyGraphics_WrapsProbeInTmux(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux")
	r := blockingReader{}
	var w bytes.Buffer
	ok := ProbeKittyGraphics(&w, r, 50*time.Millisecond)
	if ok {
		t.Error("expected probe to fail on timeout")
	}
	if !strings.HasPrefix(w.String(), "\x1bPtmux;\x1b\x1b_G") {
		t.Errorf("expected tmux-wrapped kitty probe, got %q", w.String())
	}
}

// TestProbeKittyGraphics_NoStdinTheftAfterTimeout is the regression
// guard for issue #50. The historical implementation leaked a goroutine
// that kept reading from r forever after the probe timed out; that
// goroutine then stole bytes from whatever reader the host installed
// next (bubbletea), making slk unresponsive in zellij / tmux without
// allow-passthrough.
//
// We use os.Pipe to get a real pollable *os.File pair. We expect that:
//  1. ProbeKittyGraphics returns false on timeout.
//  2. A byte written to the pipe AFTER the probe returns is delivered
//     intact to a subsequent reader (i.e. no leaked goroutine
//     intercepts it).
func TestProbeKittyGraphics_NoStdinTheftAfterTimeout(t *testing.T) {
	t.Setenv("TMUX", "")
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	defer pr.Close()
	defer pw.Close()

	var wbuf bytes.Buffer
	ok := ProbeKittyGraphics(&wbuf, pr, 50*time.Millisecond)
	if ok {
		t.Fatal("expected probe to fail on timeout (pipe never replies)")
	}

	// Write a byte AFTER the probe has timed out. If a leaked
	// goroutine is still reading from pr, it will consume this byte
	// and the Read below will block until the test's deadline.
	if _, err := pw.Write([]byte{'X'}); err != nil {
		t.Fatalf("pipe write: %v", err)
	}

	// Bound the read so the test fails fast on regression instead of
	// hanging.
	if err := pr.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}
	buf := make([]byte, 1)
	n, err := pr.Read(buf)
	if err != nil || n != 1 || buf[0] != 'X' {
		t.Fatalf("expected to read 'X' from pipe after probe; got n=%d err=%v buf=%q (probe goroutine likely leaked and stole the byte)",
			n, err, buf[:n])
	}
}

type blockingReader struct{}

func (blockingReader) Read(p []byte) (int, error) {
	time.Sleep(time.Hour)
	return 0, nil
}
