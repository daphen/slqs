package cache

import (
	"database/sql"
	"fmt"
)

// ReadState captures the per-channel read-state values that drive the
// unread dot and "new messages" line. It is the canonical type for
// passing read state across package boundaries.
type ReadState struct {
	LastReadTS string
	HasUnread  bool
}

// ChannelReadStateUpdate is one entry in a batched read-state write.
// LastReadTS == "" means "preserve the existing last_read_ts" (used by
// events that update has_unread only, e.g. new-message arrivals).
type ChannelReadStateUpdate struct {
	ChannelID  string
	LastReadTS string
	HasUnread  bool
}

// UpdateChannelReadState atomically updates the per-channel read state.
// If lastReadTS == "", the existing last_read_ts is preserved. This is
// the ONLY function permitted to modify read state after bootstrap.
func (db *DB) UpdateChannelReadState(channelID, lastReadTS string, hasUnread bool) error {
	var q string
	var args []any
	if lastReadTS == "" {
		q = `UPDATE channels SET has_unread = ? WHERE id = ?`
		args = []any{boolToInt(hasUnread), channelID}
	} else {
		q = `UPDATE channels SET last_read_ts = ?, has_unread = ? WHERE id = ?`
		args = []any{lastReadTS, boolToInt(hasUnread), channelID}
	}
	if _, err := db.conn.Exec(q, args...); err != nil {
		return fmt.Errorf("updating channel read state: %w", err)
	}
	return nil
}

// BatchUpdateChannelReadState writes multiple updates in a single
// transaction. Used by bootstrap and reconnect catch-up paths.
func (db *DB) BatchUpdateChannelReadState(updates []ChannelReadStateUpdate) error {
	if len(updates) == 0 {
		return nil
	}
	tx, err := db.conn.Begin()
	if err != nil {
		return fmt.Errorf("begin batch read-state tx: %w", err)
	}
	stmtBoth, err := tx.Prepare(`UPDATE channels SET last_read_ts = ?, has_unread = ? WHERE id = ?`)
	if err != nil {
		tx.Rollback()
		return fmt.Errorf("prepare both: %w", err)
	}
	defer stmtBoth.Close()
	stmtFlag, err := tx.Prepare(`UPDATE channels SET has_unread = ? WHERE id = ?`)
	if err != nil {
		tx.Rollback()
		return fmt.Errorf("prepare flag: %w", err)
	}
	defer stmtFlag.Close()

	for _, u := range updates {
		if u.LastReadTS == "" {
			if _, err := stmtFlag.Exec(boolToInt(u.HasUnread), u.ChannelID); err != nil {
				tx.Rollback()
				return fmt.Errorf("batch flag for %s: %w", u.ChannelID, err)
			}
		} else {
			if _, err := stmtBoth.Exec(u.LastReadTS, boolToInt(u.HasUnread), u.ChannelID); err != nil {
				tx.Rollback()
				return fmt.Errorf("batch both for %s: %w", u.ChannelID, err)
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit batch read-state: %w", err)
	}
	return nil
}

// GetChannelReadState returns the read state for a single channel.
// A missing row yields a zero-valued ReadState and a nil error.
func (db *DB) GetChannelReadState(channelID string) (ReadState, error) {
	var lastReadTS string
	var hasUnread int
	err := db.conn.QueryRow(
		`SELECT last_read_ts, has_unread FROM channels WHERE id = ?`,
		channelID,
	).Scan(&lastReadTS, &hasUnread)
	if err == sql.ErrNoRows {
		return ReadState{}, nil
	}
	if err != nil {
		return ReadState{}, fmt.Errorf("getting channel read state: %w", err)
	}
	return ReadState{LastReadTS: lastReadTS, HasUnread: hasUnread == 1}, nil
}

// GetWorkspaceReadState returns channelID -> ReadState for every
// channel in the workspace. Single batched query. Called by the
// sidebar View() at render time.
func (db *DB) GetWorkspaceReadState(workspaceID string) (map[string]ReadState, error) {
	rows, err := db.conn.Query(
		`SELECT id, last_read_ts, has_unread FROM channels WHERE workspace_id = ?`,
		workspaceID,
	)
	if err != nil {
		return nil, fmt.Errorf("query workspace read state: %w", err)
	}
	defer rows.Close()
	out := make(map[string]ReadState)
	for rows.Next() {
		var id, lastRead string
		var hasUnread int
		if err := rows.Scan(&id, &lastRead, &hasUnread); err != nil {
			return nil, fmt.Errorf("scan workspace read state: %w", err)
		}
		out[id] = ReadState{LastReadTS: lastRead, HasUnread: hasUnread == 1}
	}
	return out, rows.Err()
}

// WorkspacesWithUnreads returns the set of workspace IDs with at least
// one has_unread=true channel. Used by the workspace rail.
func (db *DB) WorkspacesWithUnreads() ([]string, error) {
	rows, err := db.conn.Query(
		`SELECT DISTINCT workspace_id FROM channels WHERE has_unread = 1`,
	)
	if err != nil {
		return nil, fmt.Errorf("query workspaces with unreads: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan workspace id: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
