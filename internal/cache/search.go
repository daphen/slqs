// Package cache: full-text search over the messages table.
//
// messages_fts is an external-content FTS5 table over messages.text,
// kept in sync by AFTER INSERT/UPDATE/DELETE triggers (the standard
// FTS5 external-content pattern). Soft deletes (is_deleted=1) do not
// touch text, so query time filters them via a join back to messages.
//
// WARNING: messages has a TEXT composite PK, so it uses implicit
// rowids, and VACUUM may renumber them — desyncing the external-content
// mapping. Do not VACUUM this database without rebuilding the index via
// INSERT INTO messages_fts(messages_fts) VALUES('rebuild').
package cache

import (
	"database/sql"
	"fmt"
	"strings"
)

// buildFTSQuery converts raw user input into an FTS5 MATCH expression
// of quoted prefix terms: `foo bar` -> `"foo"* "bar"*` ("messages
// containing words starting with foo AND bar"). Quoting every term
// means user input is never interpreted as FTS5 syntax; embedded
// double quotes are escaped by doubling per SQL string rules.
func buildFTSQuery(input string) string {
	fields := strings.Fields(input)
	parts := make([]string, 0, len(fields))
	for _, f := range fields {
		parts = append(parts, `"`+strings.ReplaceAll(f, `"`, `""`)+`"*`)
	}
	return strings.Join(parts, " ")
}

// migrateSearch creates the FTS5 table, sync triggers, and backfills
// existing rows. Idempotent: a no-op when messages_fts already exists.
func (db *DB) migrateSearch() error {
	var n int
	if err := db.conn.QueryRow(
		`SELECT count(*) FROM sqlite_master WHERE type='table' AND name='messages_fts'`).Scan(&n); err != nil {
		return fmt.Errorf("probing messages_fts: %w", err)
	}
	if n == 1 {
		return nil
	}

	tx, err := db.conn.Begin()
	if err != nil {
		return fmt.Errorf("beginning fts migration: %w", err)
	}
	defer tx.Rollback()

	stmts := []string{
		`CREATE VIRTUAL TABLE messages_fts USING fts5(
			text,
			content='messages',
			content_rowid='rowid',
			tokenize='unicode61 remove_diacritics 2'
		)`,
		`CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
			INSERT INTO messages_fts(rowid, text) VALUES (new.rowid, new.text);
		END`,
		`CREATE TRIGGER messages_fts_au AFTER UPDATE OF text ON messages BEGIN
			INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
			INSERT INTO messages_fts(rowid, text) VALUES (new.rowid, new.text);
		END`,
		`CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN
			INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
		END`,
		`INSERT INTO messages_fts(rowid, text) SELECT rowid, text FROM messages`,
	}
	for _, s := range stmts {
		if _, err := tx.Exec(s); err != nil {
			return fmt.Errorf("fts migration: %w", err)
		}
	}
	return tx.Commit()
}

// SearchChannelMessages returns the ts values of non-deleted messages
// in (channelID, workspaceID) whose text matches the query, newest
// first. Matching is word-prefix, case- and accent-insensitive (FTS5
// unicode61 remove_diacritics 2). When FTS is unavailable it degrades
// to a substring LIKE scan (ASCII case-insensitive only).
func (db *DB) SearchChannelMessages(channelID, workspaceID, query string) ([]string, error) {
	if db.ftsDisabled {
		return db.searchChannelMessagesLike(channelID, workspaceID, query)
	}
	match := buildFTSQuery(query)
	if match == "" {
		return nil, nil
	}
	// Mirror GetMessages' channel-feed predicate: plain thread replies
	// (cached when threads are viewed) can't be displayed in the
	// channel pane, so jumping to one would fail. Searching replies is
	// a v2 follow-up.
	rows, err := db.conn.Query(`
		SELECT m.ts
		FROM messages_fts f
		JOIN messages m ON m.rowid = f.rowid
		WHERE messages_fts MATCH ?
		  AND m.channel_id = ? AND m.workspace_id = ? AND m.is_deleted = 0
		  AND (m.thread_ts = '' OR m.thread_ts = m.ts OR m.subtype = 'thread_broadcast')
		ORDER BY m.ts DESC`, match, channelID, workspaceID)
	if err != nil {
		return nil, fmt.Errorf("searching messages: %w", err)
	}
	return scanTSColumn(rows)
}

// searchChannelMessagesLike is the degraded path: every term must
// appear as a substring (LIKE is case-insensitive for ASCII).
func (db *DB) searchChannelMessagesLike(channelID, workspaceID, query string) ([]string, error) {
	terms := strings.Fields(query)
	if len(terms) == 0 {
		return nil, nil
	}
	// Same channel-feed predicate as the FTS path: thread replies
	// can't be displayed in the channel pane (reply search is a v2
	// follow-up).
	q := `SELECT ts FROM messages WHERE channel_id = ? AND workspace_id = ? AND is_deleted = 0
		AND (thread_ts = '' OR thread_ts = ts OR subtype = 'thread_broadcast')`
	args := []any{channelID, workspaceID}
	for _, term := range terms {
		q += ` AND text LIKE ? ESCAPE '\'`
		escaped := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(term)
		args = append(args, "%"+escaped+"%")
	}
	q += ` ORDER BY ts DESC`
	rows, err := db.conn.Query(q, args...)
	if err != nil {
		return nil, fmt.Errorf("searching messages (like): %w", err)
	}
	return scanTSColumn(rows)
}

func scanTSColumn(rows *sql.Rows) ([]string, error) {
	defer rows.Close()
	var out []string
	for rows.Next() {
		var ts string
		if err := rows.Scan(&ts); err != nil {
			return nil, fmt.Errorf("scanning search result: %w", err)
		}
		out = append(out, ts)
	}
	return out, rows.Err()
}
