// Package debuglog provides categorized debug logging for slk.
//
// When SLK_DEBUG is set in the environment, Init opens slk-debug.log
// in the current working directory (truncating any existing file) and
// configures a package-internal logger. When unset, every category
// function is a fast no-op via an atomic.Bool flag — Sprintf-style
// args still get evaluated by Go's calling convention, but no
// formatting work occurs inside the package.
//
// Categories:
//   - Cache     — messages cache + reconciliation
//   - ImgFetch  — image fetcher lifecycle
//   - ImgRender — image render sizing + protocol decisions
//   - WS        — websocket events
//   - Backfill  — reconnect-driven history backfill
//   - Perf      — render/cache timing for perf investigation
//   - General   — misc / catch-all
//
// All output goes to a single file. Categories are encoded as inline
// tag prefixes (e.g. "[cache] ...") so users can grep to slice the
// log.
package debuglog

import (
	"io"
	"log"
	"os"
	"sync/atomic"
)

var (
	enabled atomic.Bool
	logger  *log.Logger
	reqID   atomic.Uint64
)

// Init opens slk-debug.log in cwd (truncating) when SLK_DEBUG is set,
// configures the package-internal logger, and routes the global stdlib
// log package to the same file. When SLK_DEBUG is unset, Init sets the
// global stdlib log to io.Discard (so spurious log.Printf calls don't
// bleed into the user's altscreen TUI) and returns nil, nil.
//
// Concurrency contract: Init MUST be called from main before any
// goroutine that may call a category function. The package-level
// `logger` var is published here without a mutex on the assumption
// that goroutine-creation happens-before from main's sequential
// execution makes it visible to all later-spawned workers. Calling
// Init from a goroutine that races with category-function readers
// would be a data race.
//
// Returns the *os.File so the caller can close it on exit. Idempotent
// modulo the underlying file handle: calling Init twice with SLK_DEBUG
// set will truncate the file twice and return the second handle (the
// first handle is leaked — the caller is expected to call Init exactly
// once at startup).
func Init() (*os.File, error) {
	if os.Getenv("SLK_DEBUG") == "" {
		log.SetOutput(io.Discard)
		enabled.Store(false)
		return nil, nil
	}
	f, err := os.OpenFile("slk-debug.log",
		os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		// Failed to open — keep enabled=false so calls remain no-op.
		log.SetOutput(io.Discard)
		enabled.Store(false)
		return nil, err
	}
	// Route both the package logger and the global stdlib log to the
	// same file. Log flags set ISO-ish date+time with microsecond
	// precision so timelines sort lexically.
	flags := log.Ldate | log.Ltime | log.Lmicroseconds
	logger = log.New(f, "", flags)
	log.SetOutput(f)
	log.SetFlags(flags)
	enabled.Store(true)
	return f, nil
}

// Enabled reports whether logging is active. Cheap (atomic.Bool load).
func Enabled() bool {
	return enabled.Load()
}

// Cache logs a message tagged [cache] for messages-cache and
// reconciliation events. No-op when !Enabled().
func Cache(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	logger.Printf("[cache] "+format, args...)
}

// Backfill logs a message tagged [backfill] for reconnect-driven
// history and thread-reply catch-up. No-op when !Enabled().
func Backfill(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	logger.Printf("[backfill] "+format, args...)
}

// ImgFetch logs a message tagged [imgfetch] for image fetcher
// lifecycle events. No-op when !Enabled().
func ImgFetch(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	logger.Printf("[imgfetch] "+format, args...)
}

// ImgRender logs a message tagged [imgrender] for image render-sizing
// and protocol decisions. No-op when !Enabled().
func ImgRender(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	logger.Printf("[imgrender] "+format, args...)
}

// WS logs a message tagged [ws] for WebSocket events. No-op when
// !Enabled().
func WS(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	logger.Printf("[ws] "+format, args...)
}

// Perf logs a message tagged [perf] for render/cache timing events
// emitted from the UI hot path (View, buildCache, SetFocused). No-op
// when !Enabled(). Intended for ad-hoc perf investigation: keep call
// sites cheap (atomic load + early return) so leaving them in place
// in production builds has no measurable cost when SLK_DEBUG is unset.
func Perf(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	logger.Printf("[perf] "+format, args...)
}

// General logs a message tagged [general] for miscellaneous events.
// No-op when !Enabled().
func General(format string, args ...any) {
	if !enabled.Load() {
		return
	}
	logger.Printf("[general] "+format, args...)
}

// NextReqID returns a process-wide monotonic uint64 starting at 1.
// The first call returns 1, so the zero value of a uint64 field is
// a safe "no req_id assigned yet" sentinel for structs that embed
// an ID (e.g. image.FetchRequest.ReqID). Used to correlate image-fetch
// lifecycle log lines across the enqueue → http → dispatch → recv
// stages. Safe to call regardless of Enabled().
func NextReqID() uint64 {
	return reqID.Add(1)
}
