package debuglog

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestEnabled_DefaultFalse(t *testing.T) {
	// Reset the package-level flag so this test is order-independent
	// under `go test -shuffle=on`. Other tests in this package set
	// enabled=true via Init.
	enabled.Store(false)
	if Enabled() {
		t.Fatalf("Enabled() should be false before Init")
	}
}

func TestInit_TruncatesExisting(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	t.Setenv("SLK_DEBUG", "1")

	// Pre-populate slk-debug.log with content.
	preexisting := filepath.Join(dir, "slk-debug.log")
	if err := os.WriteFile(preexisting, []byte("old content from a previous session"), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	// Reset the package-level flag so this test is order-independent.
	enabled.Store(false)

	f, err := Init()
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	if f == nil {
		t.Fatalf("Init returned nil file when SLK_DEBUG was set")
	}
	defer f.Close()

	info, err := os.Stat(preexisting)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if info.Size() != 0 {
		t.Fatalf("slk-debug.log should be truncated, got size %d", info.Size())
	}
	if !Enabled() {
		t.Fatalf("Enabled() should be true after Init with SLK_DEBUG set")
	}
}

func TestInit_NoFileWhenDisabled(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	// Explicitly unset SLK_DEBUG (defensive — env may bleed in from CI).
	t.Setenv("SLK_DEBUG", "")
	enabled.Store(false)

	f, err := Init()
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	if f != nil {
		defer f.Close()
		t.Fatalf("Init should return nil file when SLK_DEBUG is unset, got %v", f.Name())
	}
	if Enabled() {
		t.Fatalf("Enabled() should be false after Init with SLK_DEBUG unset")
	}

	if _, err := os.Stat(filepath.Join(dir, "slk-debug.log")); !os.IsNotExist(err) {
		t.Fatalf("slk-debug.log should not exist when disabled, got err=%v", err)
	}
}

func TestCategoryPrefixes(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	t.Setenv("SLK_DEBUG", "1")
	enabled.Store(false)

	f, err := Init()
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	defer f.Close()

	Cache("cache-line %d", 1)
	ImgFetch("imgfetch-line %d", 2)
	ImgRender("imgrender-line %d", 3)
	WS("ws-line %d", 4)
	General("general-line %d", 5)
	Backfill("backfill-line %d", 6)

	body, err := os.ReadFile(filepath.Join(dir, "slk-debug.log"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	out := string(body)
	for _, want := range []string{
		"[cache] cache-line 1",
		"[imgfetch] imgfetch-line 2",
		"[imgrender] imgrender-line 3",
		"[ws] ws-line 4",
		"[general] general-line 5",
		"[backfill] backfill-line 6",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log missing %q\nfull output:\n%s", want, out)
		}
	}
}

func TestEnabled_FastPathNoOp(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	t.Setenv("SLK_DEBUG", "")
	enabled.Store(false)

	if _, err := Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}

	// Should not panic and should not create a file.
	Cache("nope %d", 1)
	ImgFetch("nope %d", 2)
	ImgRender("nope %d", 3)
	WS("nope %d", 4)
	General("nope %d", 5)

	if _, err := os.Stat(filepath.Join(dir, "slk-debug.log")); !os.IsNotExist(err) {
		t.Fatalf("slk-debug.log should not exist; err=%v", err)
	}
}

func TestNextReqID_MonotonicUnique(t *testing.T) {
	const G = 16
	const M = 100
	var wg sync.WaitGroup
	collected := make([][]uint64, G)
	for g := 0; g < G; g++ {
		g := g
		wg.Add(1)
		go func() {
			defer wg.Done()
			ids := make([]uint64, M)
			for i := 0; i < M; i++ {
				ids[i] = NextReqID()
			}
			collected[g] = ids
		}()
	}
	wg.Wait()

	seen := map[uint64]struct{}{}
	for _, ids := range collected {
		for _, id := range ids {
			if _, dup := seen[id]; dup {
				t.Fatalf("duplicate id %d", id)
			}
			seen[id] = struct{}{}
		}
	}
	if len(seen) != G*M {
		t.Fatalf("want %d unique ids, got %d", G*M, len(seen))
	}
}

func TestConcurrentWrites_NoTornLines(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	t.Setenv("SLK_DEBUG", "1")
	enabled.Store(false)

	f, err := Init()
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	defer f.Close()

	const G = 8
	const M = 200
	var wg sync.WaitGroup
	for g := 0; g < G; g++ {
		g := g
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < M; i++ {
				Cache("g=%d i=%d", g, i)
			}
		}()
	}
	wg.Wait()

	body, err := os.ReadFile(filepath.Join(dir, "slk-debug.log"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	scanner := bufio.NewScanner(strings.NewReader(string(body)))
	count := 0
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, "[cache] g=") {
			t.Errorf("malformed line: %q", line)
		}
		count++
	}
	if count != G*M {
		t.Errorf("want %d lines, got %d", G*M, count)
	}
}
