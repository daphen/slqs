package cache

import (
	"database/sql"
	"path/filepath"
	"testing"
)

// ftsHelloMatches counts indexed messages matching the prefix term
// "hello"* via a rowid join back to messages (external-content tables
// can't be enumerated without a query term, so tests probe with a
// known token).
func ftsHelloMatches(t *testing.T, db *DB) int {
	t.Helper()
	var n int
	err := db.conn.QueryRow(
		`SELECT count(*) FROM messages m JOIN messages_fts f ON f.rowid = m.rowid WHERE messages_fts MATCH '"hello"*'`).Scan(&n)
	if err != nil {
		t.Fatalf("counting fts rows: %v", err)
	}
	return n
}

// TestFTS5Available is the canary: if modernc.org/sqlite ever ships
// without FTS5, this fails loudly instead of silently degrading every
// install to LIKE search.
func TestFTS5Available(t *testing.T) {
	db, err := New(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if db.ftsDisabled {
		t.Fatal("ftsDisabled is set: FTS5 unavailable in the sqlite driver")
	}
	var n int
	if err := db.conn.QueryRow(
		`SELECT count(*) FROM sqlite_master WHERE type='table' AND name='messages_fts'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("messages_fts table missing (n=%d)", n)
	}
}

func TestFTSTriggers_InsertUpdateDelete(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()
	db.UpsertChannel(Channel{ID: "C1", WorkspaceID: "T1", Name: "general", Type: "channel", IsMember: true})

	msg := Message{TS: "1700000001.000000", ChannelID: "C1", WorkspaceID: "T1", UserID: "U1", Text: "hello world"}
	if err := db.UpsertMessage(msg); err != nil {
		t.Fatal(err)
	}
	if got := ftsHelloMatches(t, db); got != 1 {
		t.Fatalf("after insert: fts matches = %d, want 1", got)
	}

	// Edit via upsert (the real edit path): text changes, old token gone.
	msg.Text = "goodbye world"
	if err := db.UpsertMessage(msg); err != nil {
		t.Fatal(err)
	}
	if got := ftsHelloMatches(t, db); got != 0 {
		t.Fatalf("after edit: stale 'hello' match still present (%d)", got)
	}

	// Hard DELETE keeps the index consistent (soft delete is filtered at
	// query time, but the AFTER DELETE trigger must exist for integrity).
	if _, err := db.conn.Exec(`DELETE FROM messages WHERE ts = ? AND channel_id = ?`, msg.TS, "C1"); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := db.conn.QueryRow(
		`SELECT count(*) FROM messages_fts WHERE messages_fts MATCH '"goodbye"*'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("after delete: stale fts row remains (%d)", n)
	}
}

// TestFTSBackfillOnPreExistingDB simulates upgrading an existing
// install: a DB created without the FTS table gets its rows indexed on
// next open. Pattern follows TestSubtypeMigrationOnPreExistingDB
// (db_test.go).
func TestFTSBackfillOnPreExistingDB(t *testing.T) {
	dsn := filepath.Join(t.TempDir(), "old.db")

	raw, err := sql.Open("sqlite", dsn)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`CREATE TABLE messages (
		ts TEXT NOT NULL,
		channel_id TEXT NOT NULL,
		workspace_id TEXT NOT NULL,
		user_id TEXT NOT NULL DEFAULT '',
		text TEXT NOT NULL DEFAULT '',
		thread_ts TEXT NOT NULL DEFAULT '',
		reply_count INTEGER NOT NULL DEFAULT 0,
		edited_at TEXT NOT NULL DEFAULT '',
		is_deleted INTEGER NOT NULL DEFAULT 0,
		raw_json TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL DEFAULT 0,
		subtype TEXT NOT NULL DEFAULT '',
		PRIMARY KEY (ts, channel_id)
	)`); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(
		`INSERT INTO messages (ts, channel_id, workspace_id, text) VALUES ('1700000001.000000', 'C1', 'T1', 'hello world')`); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	db, err := New(dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if got := ftsHelloMatches(t, db); got != 1 {
		t.Fatalf("backfill: fts matches = %d, want 1", got)
	}
}

func TestBuildFTSQuery(t *testing.T) {
	cases := []struct{ in, want string }{
		{"foo", `"foo"*`},
		{"foo bar", `"foo"* "bar"*`},
		{"  foo   bar  ", `"foo"* "bar"*`},
		{"", ""},
		{"   ", ""},
		// FTS5 operators must be treated as literal text.
		{"foo OR bar", `"foo"* "OR"* "bar"*`},
		{`say "hi"`, `"say"* """hi"""*`},
		{"(foo)", `"(foo)"*`},
		{"NEAR", `"NEAR"*`},
	}
	for _, c := range cases {
		if got := buildFTSQuery(c.in); got != c.want {
			t.Errorf("buildFTSQuery(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func seedSearchMessages(t *testing.T, db *DB) {
	t.Helper()
	db.UpsertChannel(Channel{ID: "C1", WorkspaceID: "T1", Name: "general", Type: "channel", IsMember: true})
	for _, m := range []Message{
		{TS: "1700000001.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "deploy went fine"},
		{TS: "1700000002.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "café is open"},
		{TS: "1700000003.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "deployment failed badly"},
		{TS: "1700000004.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "unrelated chatter"},
		{TS: "1700000005.000000", ChannelID: "C2", WorkspaceID: "T1", Text: "deploy in other channel"},
		{TS: "1700000006.000000", ChannelID: "C1", WorkspaceID: "T2", Text: "deploy in other workspace"},
		{TS: "1700000007.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "deleted deploy note", IsDeleted: true},
	} {
		if err := db.UpsertMessage(m); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSearchChannelMessages(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()
	seedSearchMessages(t, db)

	got, err := db.SearchChannelMessages("C1", "T1", "deploy")
	if err != nil {
		t.Fatal(err)
	}
	// Word-prefix: matches "deploy" and "deployment"; newest first.
	// Other channel, other workspace, and soft-deleted rows excluded.
	want := []string{"1700000003.000000", "1700000001.000000"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

func TestSearchChannelMessages_AccentAndCaseInsensitive(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()
	seedSearchMessages(t, db)

	got, err := db.SearchChannelMessages("C1", "T1", "CAFE")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != "1700000002.000000" {
		t.Fatalf("accent/case fold: got %v", got)
	}
}

func TestSearchChannelMessages_MultiTermAND(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()
	seedSearchMessages(t, db)

	got, err := db.SearchChannelMessages("C1", "T1", "deploy failed")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != "1700000003.000000" {
		t.Fatalf("AND semantics: got %v", got)
	}
}

func TestSearchChannelMessages_EmptyQuery(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()
	seedSearchMessages(t, db)

	got, err := db.SearchChannelMessages("C1", "T1", "   ")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("empty query: got %v", got)
	}
}

// Thread replies live in the messages table (upserted when threads are
// viewed) but the channel pane can't display them, so channel search
// must exclude them — mirroring GetMessages' feed predicate. Parents
// (thread_ts = ts) and thread_broadcast rows ARE in the feed and must
// match.
func TestSearchChannelMessages_ExcludesThreadReplies(t *testing.T) {
	seedThreadMessages := func(t *testing.T, db *DB) {
		t.Helper()
		db.UpsertChannel(Channel{ID: "C1", WorkspaceID: "T1", Name: "general", Type: "channel", IsMember: true})
		for _, m := range []Message{
			{TS: "1700000001.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "deploy parent", ThreadTS: "1700000001.000000"},
			{TS: "1700000002.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "deploy reply", ThreadTS: "1700000001.000000"},
			{TS: "1700000003.000000", ChannelID: "C1", WorkspaceID: "T1", Text: "deploy broadcast", ThreadTS: "1700000001.000000", Subtype: "thread_broadcast"},
		} {
			if err := db.UpsertMessage(m); err != nil {
				t.Fatal(err)
			}
		}
	}
	want := []string{"1700000003.000000", "1700000001.000000"} // newest first; reply excluded

	for _, mode := range []struct {
		name        string
		ftsDisabled bool
	}{
		{"fts", false},
		{"like", true},
	} {
		t.Run(mode.name, func(t *testing.T) {
			db := setupDBWithWorkspace(t)
			defer db.Close()
			seedThreadMessages(t, db)
			db.ftsDisabled = mode.ftsDisabled

			got, err := db.SearchChannelMessages("C1", "T1", "deploy")
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != len(want) {
				t.Fatalf("got %v, want %v", got, want)
			}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("got %v, want %v", got, want)
				}
			}
		})
	}
}

func TestSearchChannelMessages_LikeFallback(t *testing.T) {
	db := setupDBWithWorkspace(t)
	defer db.Close()
	seedSearchMessages(t, db)
	db.ftsDisabled = true

	got, err := db.SearchChannelMessages("C1", "T1", "deploy failed")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != "1700000003.000000" {
		t.Fatalf("LIKE fallback: got %v", got)
	}

	// LIKE wildcards and the escape character in user input must be
	// escaped, not interpreted. No seeded message contains a literal
	// '%', '_', or '\'; if they leaked through as wildcards, "%" and
	// "_" would match every row and "c_f" would match "café".
	for _, q := range []string{"%", "_", `\`, "c_f"} {
		got, err = db.SearchChannelMessages("C1", "T1", q)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 0 {
			t.Fatalf("LIKE escape: %q matched %v", q, got)
		}
	}
}
