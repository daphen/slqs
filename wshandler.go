package main

import (
	"encoding/json"
	"log"
	"time"

	"slqs/internal/cache"
	slackclient "slqs/internal/slack"
	"github.com/slack-go/slack"
)

// wsHandler persists live Slack WebSocket events to cache.db for one workspace.
// The daemon's pollWorkspace loop reads those writes and broadcasts/notifies —
// so slqs's own connection feeds the exact same code path that polling slk's
// cache used to, letting slk be retired entirely. Writes go through the shared
// read-write handle (d.writeDB); reads still use d.cacheDB.
type wsHandler struct {
	d *daemon
	w *workspace
}

func (h *wsHandler) OnConnect() {
	log.Printf("[%s] websocket connected", h.w.teamName)
	// Catch the cache up against REST for everything the socket missed while down.
	go h.d.backfill(h.w)
}
func (h *wsHandler) OnDisconnect() { log.Printf("[%s] websocket disconnected", h.w.teamName) }

func (h *wsHandler) OnMessage(channelID, userID, ts, text, threadTS, subtype string, edited bool, files []slack.File, blocks slack.Blocks, attachments []slack.Attachment, botID, username string) {
	authorID := userID
	if authorID == "" && botID != "" {
		authorID = botID
	}
	// Reconstruct the raw payload the cache/render path expects (files, blocks,
	// attachments live in raw_json — that's how images and Block Kit render).
	synthetic := slack.Message{Msg: slack.Msg{
		Type: "message", Timestamp: ts, User: authorID, Text: text,
		ThreadTimestamp: threadTS, SubType: subtype, Username: username,
		Files: files, Blocks: blocks, Attachments: attachments,
	}}
	raw, _ := json.Marshal(synthetic)
	if err := h.d.writeDB.UpsertMessage(cache.Message{
		TS: ts, ChannelID: channelID, WorkspaceID: h.w.teamID, UserID: authorID,
		Text: text, ThreadTS: threadTS, Subtype: subtype,
		RawJSON: string(raw), CreatedAt: time.Now().Unix(),
	}); err != nil {
		log.Printf("[%s] ws upsert message: %v", h.w.teamName, err)
	}
	h.d.writeDB.SetChannelSyncedAt(channelID, time.Now().Unix())
	// Edits keep the same ts, so the poll loop (ts > lastTS) never re-emits
	// them — broadcast the updated message directly so the client replaces it.
	if edited && h.w.chans[channelID] != "" {
		h.d.broadcast(map[string]any{
			"type": "message", "workspace": h.w.teamID, "channel": channelID, "thread": threadTS,
			"mention": h.w.isMention(h.w.chanKind[channelID], text),
			"msg":     h.d.msgFromRaw(h.w, channelID, authorID, ts, text, 0, string(raw)),
		})
	}
	// A thread reply just landed in the cache — re-push the (sorted) threads
	// list so the Threads view updates live: thread moves to top, count bumps.
	if threadTS != "" && threadTS != ts {
		h.d.markThreadsDirty()
	}
}

func (h *wsHandler) OnMessageDeleted(channelID, ts string) {
	h.d.writeDB.DeleteMessage(channelID, ts)
	if h.w.chans[channelID] != "" {
		h.d.broadcast(map[string]any{"type": "delete", "workspace": h.w.teamID, "channel": channelID, "ts": ts})
	}
}

func (h *wsHandler) OnReactionAdded(channelID, ts, userID, emoji string) {
	rows, err := h.d.writeDB.GetReactions(ts, channelID)
	if err == nil {
		found := false
		for _, r := range rows {
			if r.Emoji == emoji {
				h.d.writeDB.UpsertReaction(ts, channelID, emoji, append(r.UserIDs, userID), r.Count+1)
				found = true
				break
			}
		}
		if !found {
			h.d.writeDB.UpsertReaction(ts, channelID, emoji, []string{userID}, 1)
		}
	}
	h.broadcastReaction(channelID, ts)
}

func (h *wsHandler) OnReactionRemoved(channelID, ts, userID, emoji string) {
	rows, err := h.d.writeDB.GetReactions(ts, channelID)
	if err == nil {
		for _, r := range rows {
			if r.Emoji != emoji {
				continue
			}
			var keep []string
			for _, u := range r.UserIDs {
				if u != userID {
					keep = append(keep, u)
				}
			}
			if len(keep) == 0 {
				h.d.writeDB.DeleteReaction(ts, channelID, emoji)
			} else {
				h.d.writeDB.UpsertReaction(ts, channelID, emoji, keep, r.Count-1)
			}
			break
		}
	}
	h.broadcastReaction(channelID, ts)
}

// broadcastReaction pushes the authoritative reaction set for a message to the
// client. OnReaction* previously only updated the cache, so clients never saw
// other people's reactions live.
func (h *wsHandler) broadcastReaction(channelID, ts string) {
	if h.w.chans[channelID] == "" {
		return
	}
	h.d.broadcast(map[string]any{"type": "reaction", "workspace": h.w.teamID,
		"channel": channelID, "ts": ts, "reactionsJson": h.d.reactionsJSONFor(h.w, channelID, ts)})
}

func (h *wsHandler) OnChannelMarked(channelID, ts string, unreadCount int) {
	h.d.writeDB.UpdateChannelReadState(channelID, ts, unreadCount > 0)
}

func (h *wsHandler) OnThreadMarked(channelID, threadTS, ts string, read bool) {
	h.d.writeDB.UpsertThreadSubscription(h.w.teamID, channelID, threadTS, ts, !read)
}

func (h *wsHandler) OnThreadSubscriptionChanged(channelID, threadTS, lastRead string, active bool) {
	if active {
		h.d.writeDB.UpsertThreadSubscription(h.w.teamID, channelID, threadTS, lastRead, true)
	} else {
		h.d.writeDB.DeleteThreadSubscription(h.w.teamID, channelID, threadTS)
	}
	// A followed thread appeared/disappeared — refresh the Threads view live.
	h.d.markThreadsDirty()
}

// Live typing indicator — broadcast straight to clients (no persistence).
func (h *wsHandler) OnUserTyping(channelID, threadTS, userID string) {
	if h.w.chans[channelID] == "" {
		return
	}
	h.d.broadcast(map[string]any{"type": "typing", "workspace": h.w.teamID,
		"channel": channelID, "thread": threadTS, "user": h.w.users[userID]})
}

// --- events slqs doesn't act on ---
func (h *wsHandler) OnPresenceChange(userID, presence string)                       {}
func (h *wsHandler) OnSelfPresenceChange(presence string)                           {}
func (h *wsHandler) OnDNDChange(enabled bool, endUnix int64)                        {}
func (h *wsHandler) OnConversationOpened(channel slack.Channel)                     { h.d.registerChannel(h.w, channel) }
func (h *wsHandler) OnChannelSectionUpserted(ev slackclient.ChannelSectionUpserted) {}
func (h *wsHandler) OnChannelSectionDeleted(sectionID string)                       {}
func (h *wsHandler) OnChannelSectionChannelsUpserted(sectionID string, ids []string) {}
func (h *wsHandler) OnChannelSectionChannelsRemoved(sectionID string, ids []string)  {}
func (h *wsHandler) OnPrefChange(name, value string)                                {}
func (h *wsHandler) OnMemberJoined(channelID, userID string)                        {}
func (h *wsHandler) OnMemberLeft(channelID, userID string)                          {}
