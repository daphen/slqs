package cache

import (
	"database/sql"
	"errors"
	"fmt"
)

// UpsertChannelMember inserts or updates a single membership row.
// Used by member_joined_channel event deltas.
func (db *DB) UpsertChannelMember(workspaceID, channelID, userID string, updatedAt int64) error {
	_, err := db.conn.Exec(`
		INSERT INTO channel_members (workspace_id, channel_id, user_id, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(workspace_id, channel_id, user_id) DO UPDATE SET
			updated_at=excluded.updated_at
	`, workspaceID, channelID, userID, updatedAt)
	if err != nil {
		return fmt.Errorf("upserting channel member: %w", err)
	}
	return nil
}

// DeleteChannelMember removes a single membership row.
// No-op (no error) if the row doesn't exist.
func (db *DB) DeleteChannelMember(workspaceID, channelID, userID string) error {
	_, err := db.conn.Exec(`
		DELETE FROM channel_members
		WHERE workspace_id = ? AND channel_id = ? AND user_id = ?
	`, workspaceID, channelID, userID)
	if err != nil {
		return fmt.Errorf("deleting channel member: %w", err)
	}
	return nil
}

// ListChannelMembers returns user IDs for a channel, in no guaranteed order.
func (db *DB) ListChannelMembers(workspaceID, channelID string) ([]string, error) {
	rows, err := db.conn.Query(`
		SELECT user_id FROM channel_members
		WHERE workspace_id = ? AND channel_id = ?
	`, workspaceID, channelID)
	if err != nil {
		return nil, fmt.Errorf("listing channel members: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning channel member: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// ReplaceChannelMembers atomically replaces the full member set for a
// channel and updates last_full_fetch_at in channel_membership_meta.
// Used by the background full-fetch completion path. fetchedAt is a
// Unix second timestamp.
func (db *DB) ReplaceChannelMembers(workspaceID, channelID string, userIDs []string, fetchedAt int64) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return fmt.Errorf("begin replace channel members: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // committed below on success

	if _, err := tx.Exec(`
		DELETE FROM channel_members
		WHERE workspace_id = ? AND channel_id = ?
	`, workspaceID, channelID); err != nil {
		return fmt.Errorf("clearing channel members: %w", err)
	}

	stmt, err := tx.Prepare(`
		INSERT INTO channel_members (workspace_id, channel_id, user_id, updated_at)
		VALUES (?, ?, ?, ?)
	`)
	if err != nil {
		return fmt.Errorf("prepare insert: %w", err)
	}
	defer stmt.Close()
	for _, uid := range userIDs {
		if _, err := stmt.Exec(workspaceID, channelID, uid, fetchedAt); err != nil {
			return fmt.Errorf("insert channel member %s: %w", uid, err)
		}
	}

	if _, err := tx.Exec(`
		INSERT INTO channel_membership_meta (workspace_id, channel_id, last_full_fetch_at)
		VALUES (?, ?, ?)
		ON CONFLICT(workspace_id, channel_id) DO UPDATE SET
			last_full_fetch_at=excluded.last_full_fetch_at
	`, workspaceID, channelID, fetchedAt); err != nil {
		return fmt.Errorf("upserting meta: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit replace channel members: %w", err)
	}
	return nil
}

// ZeroChannelMembershipMeta sets last_full_fetch_at to 0 for a
// channel without touching the channel_members table. Used by
// membership.Manager.ForceStale on websocket reconnect to invalidate
// freshness without wiping the persisted member list.
//
// No-op (no error) if the meta row doesn't exist — there's nothing
// to invalidate, and the next full fetch will create the row.
func (db *DB) ZeroChannelMembershipMeta(workspaceID, channelID string) error {
	_, err := db.conn.Exec(`
		UPDATE channel_membership_meta
		SET last_full_fetch_at = 0
		WHERE workspace_id = ? AND channel_id = ?
	`, workspaceID, channelID)
	if err != nil {
		return fmt.Errorf("zeroing channel membership meta: %w", err)
	}
	return nil
}

// GetChannelMembershipMeta returns last_full_fetch_at for a channel.
// ok=false if no row exists (channel never fetched).
func (db *DB) GetChannelMembershipMeta(workspaceID, channelID string) (int64, bool, error) {
	var ts int64
	err := db.conn.QueryRow(`
		SELECT last_full_fetch_at FROM channel_membership_meta
		WHERE workspace_id = ? AND channel_id = ?
	`, workspaceID, channelID).Scan(&ts)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, false, nil
		}
		return 0, false, fmt.Errorf("getting channel membership meta: %w", err)
	}
	return ts, true, nil
}
