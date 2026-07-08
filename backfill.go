package main

import (
	"context"
	"log"
	"sync"
	"time"

	"slqs/internal/cache"
)

// backfill is the reliability mechanism: on every websocket (re)connect it
// catches the cache up against the live REST API, closing the gap left while
// the (flaky) flannel socket was down. This is how slk stayed correct on the
// same connection — the socket carries live deltas, REST backfill recovers
// anything it dropped. Three phases: read-state + channel history, then the
// followed-threads list. A 30s gate absorbs reconnect storms.
func (d *daemon) backfill(w *workspace) {
	d.backfillMu.Lock()
	if last, ok := d.lastBackfill[w.teamID]; ok && time.Since(last) < 30*time.Second {
		d.backfillMu.Unlock()
		return
	}
	d.lastBackfill[w.teamID] = time.Now()
	d.backfillMu.Unlock()

	start := time.Now()
	// Channel read-state comes from the fast client.counts call, which also
	// reports whether any threads are unread. The live socket keeps followed
	// threads in sync while connected (OnThreadMarked/OnMessage/…), so the
	// expensive full getView is only worth it as an offline catch-up — and only
	// when the server actually says there's unread thread activity to find.
	threadsUnread := d.backfillChannels(w)
	if threadsUnread {
		d.backfillSubscriptions(w)
	}
	log.Printf("[%s] reconnect backfill done in %.1fs (threadsUnread=%v)", w.teamName, time.Since(start).Seconds(), threadsUnread)
	d.refreshChannels()
}

// backfillChannels catches up persistent read-state from the server, then
// re-fetches history (since each channel's watermark) for every channel that
// has cached messages plus any the server reports unread — recovering messages
// the socket missed. The poll loop broadcasts the newly-cached messages.
func (d *daemon) backfillChannels(w *workspace) bool {
	var unreadIDs []string
	threadsUnread := false
	if unreads, agg, err := w.client.GetUnreadCounts(); err != nil {
		log.Printf("[%s] backfill GetUnreadCounts: %v", w.teamName, err)
	} else {
		threadsUnread = agg.HasUnreads
		updates := make([]cache.ChannelReadStateUpdate, 0, len(unreads))
		for _, u := range unreads {
			updates = append(updates, cache.ChannelReadStateUpdate{
				ChannelID: u.ChannelID, LastReadTS: u.LastRead, HasUnread: u.HasUnread,
			})
			if u.HasUnread {
				unreadIDs = append(unreadIDs, u.ChannelID)
			}
		}
		if len(updates) > 0 {
			d.writeDB.BatchUpdateChannelReadState(updates)
		}
	}

	rows, err := d.writeDB.BackfillCandidates(w.teamID, unreadIDs)
	if err != nil {
		log.Printf("[%s] backfill candidates: %v", w.teamName, err)
		return threadsUnread
	}
	sem := make(chan struct{}, 4)
	var wg sync.WaitGroup
	for _, row := range rows {
		wg.Add(1)
		go func(channelID string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			oldest, _ := d.writeDB.GetChannelWatermark(channelID)
			ctx, cancel := context.WithTimeout(d.ctx, 15*time.Second)
			res, err := w.client.GetHistorySince(ctx, channelID, oldest, 500)
			cancel()
			if err != nil {
				return
			}
			for _, m := range res.Messages {
				d.persistMessage(w, channelID, m)
			}
			d.writeDB.SetChannelSyncedAt(channelID, time.Now().Unix())
		}(row.ChannelID)
	}
	wg.Wait()
	return threadsUnread
}

// backfillSubscriptions re-fetches the followed-threads list live and rebuilds
// the cached subscriptions from it, so a thread the socket never delivered
// still shows up in the threads view.
func (d *daemon) backfillSubscriptions(w *workspace) {
	// High cap so getView returns the full authoritative set — reconcile below
	// tombstones anything not in it, so a truncated list would wrongly drop
	// real subscriptions. That means we must let it FINISH: with many followed
	// threads it paginates (100/page, each heavy from fetch_threads_state), and
	// a 20s budget timed out mid-run — leaving thread unreads unsynced (they'd
	// still badge on other clients). This is a background reconcile, so give it
	// room. On timeout it errors out and skips the reconcile (no tombstoning),
	// so a slow run degrades to "stale", never to "dropped subscriptions".
	ctx, cancel := context.WithTimeout(d.ctx, 90*time.Second)
	views, err := w.client.ListThreadSubscriptions(ctx, 1000)
	cancel()
	// A timeout can still return a most-recent-first prefix. Use it to surface
	// the recent (unread) threads via upsert, but DON'T reconcile/tombstone off
	// an incomplete list — that would wrongly drop the unseen tail.
	partial := err != nil && len(views) > 0
	if err != nil && !partial {
		log.Printf("[%s] backfill subscriptions: %v", w.teamName, err)
		return
	}
	if partial {
		log.Printf("[%s] backfill subscriptions: partial (%d threads, %v) — upserting without tombstone", w.teamName, len(views), err)
	}
	fresh := make([]cache.ThreadSubscription, 0, len(views))
	for _, v := range views {
		s := v.Subscription
		if s.ChannelID == "" || s.ThreadTS == "" {
			continue
		}
		rm := v.RootMessage
		if rm.Timestamp == "" {
			rm.Timestamp = s.ThreadTS
		}
		d.persistMessage(w, s.ChannelID, rm)
		if partial {
			// upsert-only: mark active + carry last_read, never deactivate
			if e := d.writeDB.UpsertThreadSubscription(w.teamID, s.ChannelID, s.ThreadTS, s.LastRead, true); e != nil {
				log.Printf("[%s] upsert subscription: %v", w.teamName, e)
			}
			continue
		}
		fresh = append(fresh, cache.ThreadSubscription{
			ChannelID: s.ChannelID, ThreadTS: s.ThreadTS, LastRead: s.LastRead, Active: true,
		})
	}
	if partial {
		return // skip the authoritative reconcile on an incomplete list
	}
	// Make the cached active set match Slack's authoritative list. This also
	// tombstones phantom subscriptions — e.g. a thread we only opened to read.
	if err := d.writeDB.ReconcileThreadSubscriptions(w.teamID, fresh); err != nil {
		log.Printf("[%s] reconcile subscriptions: %v", w.teamName, err)
	}
}
