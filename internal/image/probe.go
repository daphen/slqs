package image

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"slqs/internal/debuglog"
)

// ProbeKittyGraphics sends a tiny image upload with response requested
// and waits up to timeout for the OK reply. Returns true if the
// terminal acknowledges. Used at startup to downgrade ProtoKitty when
// the terminal claims kitty support but doesn't actually deliver
// (e.g., iTerm2's limited kitty implementation, or zellij / tmux with
// allow-passthrough=off swallowing the probe escape).
//
// Inputs:
//
//	w:       terminal writer (typically os.Stdout)
//	r:       terminal reader (typically os.Stdin in raw mode)
//	timeout: how long to wait for the reply
//
// Implementation note (issue #50): the production path uses pollProbe
// (poll(2) + read(2), see probe_unix.go) so the function is fully
// synchronous and spawns no goroutine. Earlier implementations spawned
// a goroutine that kept reading from r forever after the select-on-
// timeout returned. That leaked goroutine then raced bubbletea's input
// loop for every byte the user typed, discarding ~95% of keystrokes
// (most aren't 0x1b) and making slk unresponsive whenever the probe
// timed out -- which is exactly when the user is in zellij or in tmux
// with allow-passthrough=off, because the multiplexer swallows the
// probe escape and no reply ever arrives.
//
// The poll-based path needs r to be an *os.File (any Go file with a
// real fd works: os.Stdin, os.Pipe). For non-*os.File readers
// (blockingReader in tests), this falls back to the legacy goroutine-
// based probe; that path may leak but tests exit immediately so it
// doesn't matter.
func ProbeKittyGraphics(w io.Writer, r io.Reader, timeout time.Duration) bool {
	// Minimal valid 1x1 PNG.
	const tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+P+/HgAFhAJ/wlseKgAAAABJRU5ErkJggg=="
	const probeID = 9999
	header := fmt.Sprintf("a=T,f=100,t=d,i=%d,q=0", probeID)
	if err := writeKittySequence(w, fmt.Sprintf("\x1b_G%s;%s\x1b\\", header, tinyPNG)); err != nil {
		return false
	}

	start := time.Now()

	if f, ok := r.(*os.File); ok {
		ok, bytesRead, reason := pollProbe(int(f.Fd()), timeout)
		debuglog.ImgRender("probe: ok=%v reason=%s bytes_read=%d elapsed_ms=%d",
			ok, reason, bytesRead, time.Since(start).Milliseconds())
		return ok
	}

	// Test fallback for non-*os.File readers.
	return probeViaGoroutine(r, timeout)
}

// probeViaGoroutine is the legacy goroutine-based probe. Retained for
// tests that pass a non-*os.File reader. NOT used in production. The
// goroutine spawned here is intentionally not cleaned up on timeout;
// see the doc comment on ProbeKittyGraphics for why that's acceptable
// in test-only code paths.
func probeViaGoroutine(r io.Reader, timeout time.Duration) bool {
	type result struct{ ok bool }
	ch := make(chan result, 1)
	go func() {
		br := bufio.NewReader(r)
		for {
			b, err := br.ReadByte()
			if err != nil {
				ch <- result{false}
				return
			}
			if b != 0x1b {
				continue
			}
			next, err := br.ReadByte()
			if err != nil || next != '_' {
				if err != nil {
					ch <- result{false}
					return
				}
				continue
			}
			next, err = br.ReadByte()
			if err != nil || next != 'G' {
				if err != nil {
					ch <- result{false}
					return
				}
				continue
			}
			payload, err := br.ReadString(0x1b)
			if err != nil {
				ch <- result{false}
				return
			}
			ch <- result{strings.Contains(payload, ";OK")}
			return
		}
	}()
	select {
	case res := <-ch:
		return res.ok
	case <-time.After(timeout):
		return false
	}
}

// scanForOK returns (matched, ok). matched is true if a complete kitty
// graphics response (\x1b_G ... \x1b\\) is present in buf. ok is true
// when matched is true AND the payload contains ";OK". Used by both
// the poll-based and goroutine-based probe paths.
func scanForOK(buf []byte) (matched, ok bool) {
	i := bytes.Index(buf, []byte("\x1b_G"))
	if i < 0 {
		return false, false
	}
	tail := buf[i+3:] // skip past \x1b_G
	j := bytes.Index(tail, []byte("\x1b\\"))
	if j < 0 {
		return false, false
	}
	return true, bytes.Contains(tail[:j], []byte(";OK"))
}
