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
	d.backfillChannels(w)
	d.backfillSubscriptions(w)
	log.Printf("[%s] reconnect backfill done in %.1fs", w.teamName, time.Since(start).Seconds())
	d.refreshChannels()
}

// backfillChannels catches up persistent read-state from the server, then
// re-fetches history (since each channel's watermark) for every channel that
// has cached messages plus any the server reports unread — recovering messages
// the socket missed. The poll loop broadcasts the newly-cached messages.
func (d *daemon) backfillChannels(w *workspace) {
	var unreadIDs []string
	if unreads, _, err := w.client.GetUnreadCounts(); err != nil {
		log.Printf("[%s] backfill GetUnreadCounts: %v", w.teamName, err)
	} else {
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
		return
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
	if err != nil {
		log.Printf("[%s] backfill subscriptions: %v", w.teamName, err)
		return
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
		fresh = append(fresh, cache.ThreadSubscription{
			ChannelID: s.ChannelID, ThreadTS: s.ThreadTS, LastRead: s.LastRead, Active: true,
		})
	}
	// Make the cached active set match Slack's authoritative list. This also
	// tombstones phantom subscriptions — e.g. a thread we only opened to read.
	if err := d.writeDB.ReconcileThreadSubscriptions(w.teamID, fresh); err != nil {
		log.Printf("[%s] reconcile subscriptions: %v", w.teamName, err)
	}
}
