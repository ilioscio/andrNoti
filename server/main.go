package main

import (
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	_ "modernc.org/sqlite"
)

// ── Config ────────────────────────────────────────────────────────────────────

var (
	flagPort            = flag.String("port", "8086", "TCP port to listen on")
	flagTokenFile       = flag.String("token-file", "", "Path to file containing the auth token")
	flagToken           = flag.String("token", "", "Auth token as a plain string (alternative to --token-file)")
	flagDB              = flag.String("db", "notifications.db", "Path to SQLite database file")
	flagHeartbeatMissed = flag.Int("heartbeat-missed", 3, "Missed beats before alerting on a remote source")

	// The elevated "control" scope. Distinct from the broadcast token: it gates
	// log retrieval (and, later, service control) via /fleet/command. Left empty,
	// the whole /fleet/command surface returns 503 — the feature is off until a
	// control token is explicitly provisioned.
	flagControlTokenFile = flag.String("control-token-file", "", "Path to file containing the elevated control-scope token")
	flagControlToken     = flag.String("control-token", "", "Control-scope token as a plain string (alternative to --control-token-file)")
)

var authToken string

// controlToken authorises the elevated /fleet/command scope. Empty = disabled.
var controlToken string

// selfSource labels notifications the relay generates about itself (heartbeat
// up/down alerts). It is excluded from the machines registry — the relay is not
// a remote machine.
const selfSource = "aisthetron"

// ── Models ────────────────────────────────────────────────────────────────────

type Notification struct {
	ID        int64   `json:"id"`
	Title     string  `json:"title"`
	Text      string  `json:"text"`
	Source    string  `json:"source"`
	CreatedAt string  `json:"created_at"`
	SeenAt    *string `json:"seen_at"`
}

type wsMessage struct {
	Type          string         `json:"type"`
	Notifications []Notification `json:"notifications,omitempty"`
	ID            int64          `json:"id,omitempty"`
	Title         string         `json:"title,omitempty"`
	Text          string         `json:"text,omitempty"`
	Source        string         `json:"source,omitempty"`
	CreatedAt     string         `json:"created_at,omitempty"`
	SeenAt        *string        `json:"seen_at,omitempty"`
}

// ── Database ──────────────────────────────────────────────────────────────────

var db *sql.DB

func initDB(path string) error {
	var err error
	// WAL + a busy timeout so concurrent access (long-poll queries vs. heartbeat
	// writes vs. the command reaper) waits for the lock instead of failing with
	// SQLITE_BUSY. Pragmas go in the DSN so every pooled connection inherits them.
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	dsn := path + sep + "_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)"
	db, err = sql.Open("sqlite", dsn)
	if err != nil {
		return fmt.Errorf("open sqlite: %w", err)
	}
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS notifications (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			title      TEXT NOT NULL DEFAULT '',
			text       TEXT NOT NULL,
			source     TEXT NOT NULL DEFAULT '',
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			seen_at    DATETIME
		)
	`)
	if err != nil {
		return err
	}
	// Safe migrations — silently ignored if columns already exist.
	_, _ = db.Exec(`ALTER TABLE notifications ADD COLUMN seen_at DATETIME`)
	_, _ = db.Exec(`ALTER TABLE notifications ADD COLUMN source TEXT NOT NULL DEFAULT ''`)

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS heartbeats (
			source    TEXT PRIMARY KEY,
			interval  INTEGER NOT NULL DEFAULT 60,
			last_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			alerted   INTEGER NOT NULL DEFAULT 0,
			health    TEXT,
			monitor   INTEGER NOT NULL DEFAULT 1
		)
	`)
	if err != nil {
		return err
	}
	// Safe migrations — silently ignored if columns already exist.
	_, _ = db.Exec(`ALTER TABLE heartbeats ADD COLUMN health TEXT`)
	_, _ = db.Exec(`ALTER TABLE heartbeats ADD COLUMN monitor INTEGER NOT NULL DEFAULT 1`)

	// Health telemetry samples collected from wearables.
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS samples (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			source     TEXT NOT NULL DEFAULT '',
			metric     TEXT NOT NULL,
			value      REAL NOT NULL,
			unit       TEXT NOT NULL DEFAULT '',
			ts         DATETIME NOT NULL,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	`)
	if err != nil {
		return err
	}
	_, _ = db.Exec(`CREATE INDEX IF NOT EXISTS idx_samples_metric_ts ON samples(metric, ts)`)

	// Latest systemd unit status per (source, unit). Pushed piggybacked on the
	// heartbeat. `alerted` tracks the failed→ok transition so we notify once per
	// fault, not every 60s.
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS unit_status (
			source     TEXT NOT NULL,
			unit       TEXT NOT NULL,
			active     TEXT NOT NULL DEFAULT '',
			sub        TEXT NOT NULL DEFAULT '',
			failed     INTEGER NOT NULL DEFAULT 0,
			alerted    INTEGER NOT NULL DEFAULT 0,
			updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (source, unit)
		)
	`)
	if err != nil {
		return err
	}

	// Fleet command queue AND audit log. Rows are never deleted by the server —
	// every request a control token ever made is retained for forensics. Actions
	// are a closed enum enforced in code; there is no free-form command column.
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS commands (
			id          INTEGER PRIMARY KEY AUTOINCREMENT,
			host        TEXT NOT NULL,
			action      TEXT NOT NULL,
			unit        TEXT NOT NULL DEFAULT '',
			lines       INTEGER NOT NULL DEFAULT 200,
			requester   TEXT NOT NULL DEFAULT '',
			status      TEXT NOT NULL DEFAULT 'pending',
			result      TEXT NOT NULL DEFAULT '',
			result_code INTEGER NOT NULL DEFAULT 0,
			created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			claimed_at  DATETIME,
			done_at     DATETIME
		)
	`)
	if err != nil {
		return err
	}
	_, _ = db.Exec(`CREATE INDEX IF NOT EXISTS idx_commands_host_status ON commands(host, status)`)
	return nil
}

func insertNotification(title, text, source string) (Notification, error) {
	res, err := db.Exec(
		`INSERT INTO notifications (title, text, source) VALUES (?, ?, ?)`,
		title, text, source,
	)
	if err != nil {
		return Notification{}, err
	}
	id, _ := res.LastInsertId()
	var n Notification
	row := db.QueryRow(
		`SELECT id, title, text, source, created_at, seen_at FROM notifications WHERE id = ?`, id,
	)
	err = row.Scan(&n.ID, &n.Title, &n.Text, &n.Source, &n.CreatedAt, &n.SeenAt)
	return n, err
}

func queryHistory(limit, offset int) ([]Notification, error) {
	rows, err := db.Query(
		`SELECT id, title, text, source, created_at, seen_at FROM notifications
		 ORDER BY id DESC LIMIT ? OFFSET ?`,
		limit, offset,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ns []Notification
	for rows.Next() {
		var n Notification
		if err := rows.Scan(&n.ID, &n.Title, &n.Text, &n.Source, &n.CreatedAt, &n.SeenAt); err != nil {
			return nil, err
		}
		ns = append(ns, n)
	}
	return ns, rows.Err()
}

// ── WebSocket Hub ─────────────────────────────────────────────────────────────

type client struct {
	conn *websocket.Conn
	send chan []byte
}

type hub struct {
	mu      sync.RWMutex
	clients map[*client]struct{}
	reg     chan *client
	unreg   chan *client
	bcast   chan []byte
}

func newHub() *hub {
	return &hub{
		clients: make(map[*client]struct{}),
		reg:     make(chan *client, 16),
		unreg:   make(chan *client, 16),
		bcast:   make(chan []byte, 256),
	}
}

func (h *hub) run() {
	for {
		select {
		case c := <-h.reg:
			h.mu.Lock()
			h.clients[c] = struct{}{}
			h.mu.Unlock()

		case c := <-h.unreg:
			h.mu.Lock()
			if _, ok := h.clients[c]; ok {
				delete(h.clients, c)
				close(c.send)
			}
			h.mu.Unlock()

		case msg := <-h.bcast:
			h.mu.RLock()
			for c := range h.clients {
				select {
				case c.send <- msg:
				default:
					// slow client — drop message
				}
			}
			h.mu.RUnlock()
		}
	}
}

func (h *hub) connectedCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

var upgrader = websocket.Upgrader{
	CheckOrigin:      func(r *http.Request) bool { return true },
	ReadBufferSize:   1024,
	WriteBufferSize:  4096,
	HandshakeTimeout: 10 * time.Second,
}

func writePump(c *client) {
	defer c.conn.Close()
	for msg := range c.send {
		c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			return
		}
	}
}

func readPump(h *hub, c *client) {
	defer func() {
		h.unreg <- c
		c.conn.Close()
	}()
	c.conn.SetReadLimit(512)
	c.conn.SetReadDeadline(time.Now().Add(70 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(70 * time.Second))
		return nil
	})
	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			return
		}
	}
}

func pingPump(c *client) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
			return
		}
	}
}

// ── Heartbeat Monitor ─────────────────────────────────────────────────────────

// parseSQLiteTime handles the two DATETIME formats SQLite uses.
func parseSQLiteTime(s string) (time.Time, error) {
	t, err := time.Parse("2006-01-02T15:04:05Z", s)
	if err == nil {
		return t.UTC(), nil
	}
	t, err = time.Parse("2006-01-02 15:04:05", s)
	if err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("unrecognised time format: %q", s)
}

func broadcastNotification(h *hub, n Notification) {
	msg := wsMessage{
		Type:      "notification",
		ID:        n.ID,
		Title:     n.Title,
		Text:      n.Text,
		Source:    n.Source,
		CreatedAt: n.CreatedAt,
	}
	data, _ := json.Marshal(msg)
	h.bcast <- data
}

func startHeartbeatChecker(h *hub, missedThreshold int) {
	ticker := time.NewTicker(time.Minute)
	for range ticker.C {
		checkHeartbeats(h, missedThreshold)
	}
}

// startCommandReaper fails out commands that never completed so the app doesn't
// poll a dead request forever: pending ones no agent claimed (host offline) and
// claimed ones no agent answered (agent died mid-run).
func startCommandReaper() {
	ticker := time.NewTicker(15 * time.Second)
	for range ticker.C {
		if _, err := db.Exec(
			`UPDATE commands SET status='error',
			   result='timed out: host agent did not respond',
			   result_code=-1, done_at=CURRENT_TIMESTAMP
			 WHERE status IN ('pending','claimed')
			   AND created_at < datetime('now','-90 seconds')`,
		); err != nil {
			log.Printf("reaper: %v", err)
		}
	}
}

func checkHeartbeats(h *hub, missedThreshold int) {
	rows, err := db.Query(
		`SELECT source, interval, last_seen, alerted, monitor FROM heartbeats`,
	)
	if err != nil {
		log.Printf("heartbeat check: %v", err)
		return
	}
	defer rows.Close()

	type hbRow struct {
		source   string
		interval int
		lastSeen time.Time
		alerted  bool
		monitor  bool
	}
	var sources []hbRow

	for rows.Next() {
		var (
			source      string
			interval    int
			lastSeenStr string
			alertedInt  int
			monitorInt  int
		)
		if err := rows.Scan(&source, &interval, &lastSeenStr, &alertedInt, &monitorInt); err != nil {
			continue
		}
		t, err := parseSQLiteTime(lastSeenStr)
		if err != nil {
			log.Printf("heartbeat check: parse time for %q: %v", source, err)
			continue
		}
		sources = append(sources, hbRow{
			source:   source,
			interval: interval,
			lastSeen: t,
			alerted:  alertedInt != 0,
			monitor:  monitorInt != 0,
		})
	}

	for _, hb := range sources {
		deadline := hb.lastSeen.Add(time.Duration(hb.interval*missedThreshold) * time.Second)
		isDown := time.Now().UTC().After(deadline)

		// monitor=false → intermittent device (e.g. a laptop): track status but
		// never fire unreachable/recovered alerts.
		if isDown && !hb.alerted && hb.monitor {
			silence := time.Since(hb.lastSeen).Round(time.Second)
			n, err := insertNotification(
				hb.source+" unreachable",
				fmt.Sprintf("No heartbeat for %s (%d missed × %ds interval).", silence, missedThreshold, hb.interval),
				selfSource,
			)
			if err != nil {
				log.Printf("heartbeat: insert alert for %q: %v", hb.source, err)
			} else {
				broadcastNotification(h, n)
				log.Printf("heartbeat: source=%q alerted (silent for %s)", hb.source, silence)
			}
			db.Exec(`UPDATE heartbeats SET alerted=1 WHERE source=?`, hb.source)
		}
	}
}

// ── Auth Middleware ────────────────────────────────────────────────────────────

// bearerToken extracts the presented bearer credential, or "" if absent.
func bearerToken(r *http.Request) string {
	v := r.Header.Get("Authorization")
	if !strings.HasPrefix(v, "Bearer ") {
		return ""
	}
	return strings.TrimPrefix(v, "Bearer ")
}

// constEq compares two tokens in constant time (avoids leaking length/prefix via
// timing). Both empty → false, so an unset control token never authorises.
func constEq(presented, want string) bool {
	if want == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(presented), []byte(want)) == 1
}

func requireBearer(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !constEq(bearerToken(r), authToken) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// requireControl gates the elevated fleet-command scope. If no control token is
// configured, the endpoint is *disabled* (503) rather than open — control is
// strictly opt-in. The broadcast token is NOT accepted here.
func requireControl(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if controlToken == "" {
			http.Error(w, "control scope not configured", http.StatusServiceUnavailable)
			return
		}
		if !constEq(bearerToken(r), controlToken) {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// ── Fleet command model ─────────────────────────────────────────────────────────

// fleetActions is the closed set of things a host agent will ever be asked to do.
// This phase is READ-ONLY by construction: no start/stop/restart exists here, and
// the host agent independently refuses anything outside this set. Adding a
// mutating action is a deliberate, reviewed change in BOTH places.
var fleetActions = map[string]bool{
	"journal":     true, // journalctl -u <unit> -n <lines>
	"unit-status": true, // systemctl status <unit> (read-only)
}

// validUnitName rejects anything that isn't a plausible systemd unit token before
// it is ever queued. The host agent's per-host allowlist is the real authority;
// this is a cheap early reject that also keeps junk out of the audit log.
var unitNameRe = regexp.MustCompile(`^[A-Za-z0-9@._:-]{1,128}$`)

func validUnitName(s string) bool { return unitNameRe.MatchString(s) }

// ── Handlers ──────────────────────────────────────────────────────────────────

func handleSend(h *hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Title  string `json:"title"`
			Text   string `json:"text"`
			Source string `json:"source"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(body.Text) == "" {
			http.Error(w, "text is required", http.StatusBadRequest)
			return
		}

		n, err := insertNotification(body.Title, body.Text, body.Source)
		if err != nil {
			log.Printf("insert notification: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		broadcastNotification(h, n)

		sentTo := h.connectedCount()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"id": n.ID, "sent_to": sentTo})
		log.Printf("send: id=%d sent_to=%d source=%q title=%q", n.ID, sentTo, n.Source, n.Title)
	}
}

func handleHeartbeat(h *hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			Source   string          `json:"source"`
			Interval int             `json:"interval"`
			Health   json.RawMessage `json:"health,omitempty"`
			Monitor  *bool           `json:"monitor,omitempty"`
			Units    []unitReport    `json:"units,omitempty"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(body.Source) == "" {
			http.Error(w, "source is required", http.StatusBadRequest)
			return
		}
		if body.Interval <= 0 {
			body.Interval = 60
		}
		// Absent monitor defaults to true (alert on miss).
		monitor := 1
		if body.Monitor != nil && !*body.Monitor {
			monitor = 0
		}

		// Check if this source was previously marked as down.
		var alertedInt int
		wasAlerted := false
		row := db.QueryRow(`SELECT alerted FROM heartbeats WHERE source = ?`, body.Source)
		if err := row.Scan(&alertedInt); err == nil {
			wasAlerted = alertedInt != 0
		}

		// Upsert — resets last_seen and clears alerted.
		_, err := db.Exec(`
			INSERT INTO heartbeats (source, interval, last_seen, alerted, monitor)
			VALUES (?, ?, CURRENT_TIMESTAMP, 0, ?)
			ON CONFLICT(source) DO UPDATE SET
				interval  = excluded.interval,
				last_seen = CURRENT_TIMESTAMP,
				alerted   = 0,
				monitor   = excluded.monitor
		`, body.Source, body.Interval, monitor)
		if err != nil {
			log.Printf("heartbeat: upsert %q: %v", body.Source, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		// Persist the latest health payload if one was included.
		if len(body.Health) > 0 {
			if _, err := db.Exec(`UPDATE heartbeats SET health = ? WHERE source = ?`,
				string(body.Health), body.Source); err != nil {
				log.Printf("heartbeat: store health for %q: %v", body.Source, err)
			}
		}

		// Reconcile reported systemd units — updates the board and fires a push on
		// the ok→failed transition (and a recovery on failed→ok). monitor=false
		// hosts still track status but never push, matching heartbeat semantics.
		if body.Units != nil {
			applyUnitStatus(h, body.Source, monitor != 0, body.Units)
		}

		if wasAlerted {
			// Send recovery notification.
			n, err := insertNotification(
				body.Source+" recovered",
				"Heartbeat resumed after outage.",
				selfSource,
			)
			if err != nil {
				log.Printf("heartbeat: recovery notification for %q: %v", body.Source, err)
			} else {
				broadcastNotification(h, n)
				log.Printf("heartbeat: source=%q recovered", body.Source)
			}
		} else {
			log.Printf("heartbeat: source=%q ok (interval=%ds)", body.Source, body.Interval)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true})
	}
}

func handleHistory() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		limit := 50
		offset := 0
		q := r.URL.Query()
		if v := q.Get("limit"); v != "" {
			fmt.Sscan(v, &limit)
		}
		if v := q.Get("offset"); v != "" {
			fmt.Sscan(v, &offset)
		}
		if limit < 1 {
			limit = 100
		}

		ns, err := queryHistory(limit, offset)
		if err != nil {
			log.Printf("query history: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if ns == nil {
			ns = []Notification{}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(ns)
	}
}

func handleMarkSeen() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			IDs []int64 `json:"ids"`
		}
		json.NewDecoder(r.Body).Decode(&body)

		var (
			res sql.Result
			err error
		)
		if len(body.IDs) > 0 {
			placeholders := strings.Repeat("?,", len(body.IDs))
			placeholders = placeholders[:len(placeholders)-1]
			args := make([]any, len(body.IDs))
			for i, id := range body.IDs {
				args[i] = id
			}
			res, err = db.Exec(
				fmt.Sprintf(`UPDATE notifications SET seen_at = CURRENT_TIMESTAMP
				             WHERE seen_at IS NULL AND id IN (%s)`, placeholders),
				args...,
			)
		} else {
			res, err = db.Exec(
				`UPDATE notifications SET seen_at = CURRENT_TIMESTAMP WHERE seen_at IS NULL`,
			)
		}
		if err != nil {
			log.Printf("mark-seen: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		count, _ := res.RowsAffected()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"marked": count})
		log.Printf("mark-seen: %d notifications marked", count)
	}
}

func handleDeleteNotifications() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		_, err := db.Exec(`DELETE FROM notifications`)
		if err != nil {
			log.Printf("delete notifications: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
		log.Printf("delete notifications: all records deleted")
	}
}

// ── Unit status (systemd) ───────────────────────────────────────────────────────

// unitReport is the wire form pushed inside a heartbeat.
type unitReport struct {
	Name   string `json:"name"`
	Active string `json:"active"` // active_state: active|inactive|failed|activating…
	Sub    string `json:"sub"`    // sub_state: running|dead|failed|exited…
}

// UnitStatus is the /machines wire form.
type UnitStatus struct {
	Unit      string `json:"unit"`
	Active    string `json:"active"`
	Sub       string `json:"sub"`
	Failed    bool   `json:"failed"`
	UpdatedAt string `json:"updated_at"`
}

func unitFailed(active, sub string) bool {
	return active == "failed" || sub == "failed"
}

// applyUnitStatus upserts the reported units for a source and fires transition
// notifications. `notify` is false for silent (monitor=false) hosts.
func applyUnitStatus(h *hub, source string, notify bool, units []unitReport) {
	for _, u := range units {
		name := strings.TrimSpace(u.Name)
		if name == "" {
			continue
		}
		failed := unitFailed(u.Active, u.Sub)

		var prevFailed, prevAlerted bool
		row := db.QueryRow(`SELECT failed, alerted FROM unit_status WHERE source=? AND unit=?`, source, name)
		var pf, pa int
		known := row.Scan(&pf, &pa) == nil
		prevFailed, prevAlerted = pf != 0, pa != 0

		failedInt := 0
		if failed {
			failedInt = 1
		}

		// Decide the new alerted flag and whether to emit a transition notice.
		newAlerted := prevAlerted
		var note *Notification
		if notify {
			switch {
			case failed && !prevAlerted:
				n, err := insertNotification(
					source+": "+name+" failed",
					fmt.Sprintf("Unit %s is %s/%s on %s.", name, u.Active, u.Sub, source),
					selfSource,
				)
				if err == nil {
					note = &n
					newAlerted = true
				} else {
					log.Printf("unit alert: insert for %q/%q: %v", source, name, err)
				}
			case !failed && prevAlerted:
				n, err := insertNotification(
					source+": "+name+" recovered",
					fmt.Sprintf("Unit %s is back to %s/%s on %s.", name, u.Active, u.Sub, source),
					selfSource,
				)
				if err == nil {
					note = &n
					newAlerted = false
				}
			}
		} else {
			// Silent host: never push, and keep alerted clear so re-enabling
			// monitoring later doesn't dump a backlog of stale alerts.
			newAlerted = false
		}

		newAlertedInt := 0
		if newAlerted {
			newAlertedInt = 1
		}

		if _, err := db.Exec(`
			INSERT INTO unit_status (source, unit, active, sub, failed, alerted, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
			ON CONFLICT(source, unit) DO UPDATE SET
				active=excluded.active, sub=excluded.sub, failed=excluded.failed,
				alerted=excluded.alerted, updated_at=CURRENT_TIMESTAMP
		`, source, name, u.Active, u.Sub, failedInt, newAlertedInt); err != nil {
			log.Printf("unit status: upsert %q/%q: %v", source, name, err)
			continue
		}

		if note != nil {
			broadcastNotification(h, *note)
			log.Printf("unit: source=%q unit=%q %s→%s", source, name,
				boolWord(prevFailed, known), boolWord(failed, true))
		}
	}
}

func boolWord(failed, known bool) string {
	if !known {
		return "new"
	}
	if failed {
		return "failed"
	}
	return "ok"
}

// loadUnitStatus returns the current units for a source, newest-updated first.
func loadUnitStatus(source string) []UnitStatus {
	rows, err := db.Query(
		`SELECT unit, active, sub, failed, updated_at FROM unit_status WHERE source=? ORDER BY failed DESC, unit ASC`,
		source,
	)
	if err != nil {
		log.Printf("unit status: load %q: %v", source, err)
		return nil
	}
	defer rows.Close()
	var out []UnitStatus
	for rows.Next() {
		var u UnitStatus
		var failedInt int
		if err := rows.Scan(&u.Unit, &u.Active, &u.Sub, &failedInt, &u.UpdatedAt); err != nil {
			continue
		}
		u.Failed = failedInt != 0
		u.UpdatedAt = normalizeTS(u.UpdatedAt)
		out = append(out, u)
	}
	return out
}

// ── Machines registry ──────────────────────────────────────────────────────────

type MachineInfo struct {
	Source             string          `json:"source"`
	Kind               string          `json:"kind"` // "heartbeat" | "event"
	Interval           int             `json:"interval,omitempty"`
	LastSeen           string          `json:"last_seen"`
	Status             string          `json:"status"` // live | stale | down | unknown
	Alerted            bool            `json:"alerted"`
	Monitor            bool            `json:"monitor"` // false = intermittent, no down/up alerts
	Health             json.RawMessage `json:"health,omitempty"`
	Units              []UnitStatus    `json:"units,omitempty"`
	NotificationCount  int             `json:"notification_count"`
	LastNotificationAt string          `json:"last_notification_at,omitempty"`
}

// machineStatus classifies a heartbeat source from the age of its last beat.
func machineStatus(lastSeen string, interval, missedThreshold int) string {
	t, err := parseSQLiteTime(lastSeen)
	if err != nil {
		return "unknown"
	}
	age := time.Since(t)
	if age > time.Duration(interval*missedThreshold)*time.Second {
		return "down"
	}
	if age > time.Duration(interval*2)*time.Second {
		return "stale"
	}
	return "live"
}

// handleMachines returns the union of heartbeat sources (live infrastructure)
// and notification sources (machines that have only ever sent messages).
func handleMachines(missedThreshold int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		machines := map[string]*MachineInfo{}
		order := []string{}

		hbRows, err := db.Query(
			`SELECT source, interval, last_seen, alerted, monitor, COALESCE(health, '') FROM heartbeats`,
		)
		if err != nil {
			log.Printf("machines: query heartbeats: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		for hbRows.Next() {
			var (
				source     string
				interval   int
				lastSeen   string
				alertedInt int
				monitorInt int
				health     string
			)
			if err := hbRows.Scan(&source, &interval, &lastSeen, &alertedInt, &monitorInt, &health); err != nil {
				continue
			}
			mi := &MachineInfo{
				Source:   source,
				Kind:     "heartbeat",
				Interval: interval,
				LastSeen: lastSeen,
				Status:   machineStatus(lastSeen, interval, missedThreshold),
				Alerted:  alertedInt != 0,
				Monitor:  monitorInt != 0,
			}
			if health != "" {
				mi.Health = json.RawMessage(health)
			}
			mi.Units = loadUnitStatus(source)
			machines[source] = mi
			order = append(order, source)
		}
		hbRows.Close()

		nRows, err := db.Query(
			`SELECT source, COUNT(*), MAX(created_at) FROM notifications
			 WHERE source != '' AND source != ? GROUP BY source`,
			selfSource,
		)
		if err != nil {
			log.Printf("machines: query notifications: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		for nRows.Next() {
			var (
				source string
				count  int
				lastAt string
			)
			if err := nRows.Scan(&source, &count, &lastAt); err != nil {
				continue
			}
			if mi, ok := machines[source]; ok {
				mi.NotificationCount = count
				mi.LastNotificationAt = lastAt
			} else {
				machines[source] = &MachineInfo{
					Source:             source,
					Kind:               "event",
					LastSeen:           lastAt,
					Status:             "unknown",
					NotificationCount:  count,
					LastNotificationAt: lastAt,
				}
				order = append(order, source)
			}
		}
		nRows.Close()

		out := make([]*MachineInfo, 0, len(machines))
		for _, source := range order {
			out = append(out, machines[source])
		}
		// Most recently active first. last_seen arrives in two formats (typed
		// DATETIME columns vs. the MAX(created_at) aggregate), so compare parsed
		// times rather than sorting the strings lexically.
		sort.SliceStable(out, func(i, j int) bool {
			ti, _ := parseSQLiteTime(out[i].LastSeen)
			tj, _ := parseSQLiteTime(out[j].LastSeen)
			return ti.After(tj)
		})

		// Normalise timestamps to a single UTC RFC3339 form so clients never have
		// to disambiguate SQLite's two DATETIME renderings.
		for _, mi := range out {
			if t, err := parseSQLiteTime(mi.LastSeen); err == nil {
				mi.LastSeen = t.Format(time.RFC3339)
			}
			if mi.LastNotificationAt != "" {
				if t, err := parseSQLiteTime(mi.LastNotificationAt); err == nil {
					mi.LastNotificationAt = t.Format(time.RFC3339)
				}
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(out)
	}
}

// ── Health telemetry ───────────────────────────────────────────────────────────

type Sample struct {
	Source string  `json:"source,omitempty"`
	Metric string  `json:"metric"`
	Value  float64 `json:"value"`
	Unit   string  `json:"unit,omitempty"`
	TS     string  `json:"ts"`
}

// normalizeTS parses a timestamp (RFC3339 with offset, RFC3339 UTC, or SQLite
// space format) and returns canonical UTC RFC3339. Falls back to now.
func normalizeTS(s string) string {
	s = strings.TrimSpace(s)
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC().Format(time.RFC3339)
	}
	if t, err := parseSQLiteTime(s); err == nil {
		return t.Format(time.RFC3339)
	}
	return time.Now().UTC().Format(time.RFC3339)
}

// handleMetrics dispatches POST (batch ingest) and GET (time-series query).
func handleMetrics() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			ingestMetrics(w, r)
		case http.MethodGet:
			queryMetrics(w, r)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}
}

func ingestMetrics(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Source  string   `json:"source"`
		Samples []Sample `json:"samples"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if len(body.Samples) == 0 {
		http.Error(w, "samples is required", http.StatusBadRequest)
		return
	}

	tx, err := db.Begin()
	if err != nil {
		log.Printf("metrics ingest: begin: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	stmt, err := tx.Prepare(
		`INSERT INTO samples (source, metric, value, unit, ts) VALUES (?, ?, ?, ?, ?)`,
	)
	if err != nil {
		tx.Rollback()
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer stmt.Close()

	n := 0
	for _, s := range body.Samples {
		if strings.TrimSpace(s.Metric) == "" {
			continue
		}
		src := s.Source
		if src == "" {
			src = body.Source
		}
		if _, err := stmt.Exec(src, s.Metric, s.Value, s.Unit, normalizeTS(s.TS)); err != nil {
			tx.Rollback()
			log.Printf("metrics ingest: insert: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		n++
	}
	if err := tx.Commit(); err != nil {
		log.Printf("metrics ingest: commit: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"ingested": n})
	log.Printf("metrics: ingested %d samples from source=%q", n, body.Source)
}

func queryMetrics(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	metric := strings.TrimSpace(q.Get("metric"))
	if metric == "" {
		http.Error(w, "metric query param is required", http.StatusBadRequest)
		return
	}
	limit := 5000
	if v := q.Get("limit"); v != "" {
		fmt.Sscan(v, &limit)
	}
	if limit < 1 || limit > 50000 {
		limit = 5000
	}

	query := `SELECT source, metric, value, unit, ts FROM samples WHERE metric = ?`
	args := []any{metric}
	if from := q.Get("from"); from != "" {
		query += ` AND ts >= ?`
		args = append(args, normalizeTS(from))
	}
	if to := q.Get("to"); to != "" {
		query += ` AND ts <= ?`
		args = append(args, normalizeTS(to))
	}
	query += ` ORDER BY ts ASC LIMIT ?`
	args = append(args, limit)

	rows, err := db.Query(query, args...)
	if err != nil {
		log.Printf("metrics query: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	writeSamples(w, rows)
}

// handleMetricsLatest returns the most recent sample for each metric — the
// dashboard's "current readings".
func handleMetricsLatest() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		rows, err := db.Query(`
			SELECT source, metric, value, unit, ts FROM samples s
			WHERE ts = (SELECT MAX(ts) FROM samples WHERE metric = s.metric)
			GROUP BY metric
			ORDER BY metric
		`)
		if err != nil {
			log.Printf("metrics latest: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		writeSamples(w, rows)
	}
}

func writeSamples(w http.ResponseWriter, rows *sql.Rows) {
	out := []Sample{}
	for rows.Next() {
		var s Sample
		if err := rows.Scan(&s.Source, &s.Metric, &s.Value, &s.Unit, &s.TS); err != nil {
			continue
		}
		s.TS = normalizeTS(s.TS)
		out = append(out, s)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// ── Fleet command queue ─────────────────────────────────────────────────────────
//
// The relay is a mailbox, not an executor. The phone (control scope) drops a
// request here; the target host's agent (broadcast/host scope) long-polls, runs
// the closed-enum action against its OWN local allowlist, and posts the result
// back. The relay never runs anything on a host and never holds host privileges.

type fleetCommand struct {
	ID     int64  `json:"id"`
	Host   string `json:"host"`
	Action string `json:"action"`
	Unit   string `json:"unit"`
	Lines  int    `json:"lines"`
}

// handleFleetCommand: POST enqueues a command (control scope); GET reports one.
func handleFleetCommand() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			enqueueCommand(w, r)
		case http.MethodGet:
			reportCommand(w, r)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}
}

func enqueueCommand(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Host      string `json:"host"`
		Action    string `json:"action"`
		Unit      string `json:"unit"`
		Lines     int    `json:"lines"`
		Requester string `json:"requester"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	body.Host = strings.TrimSpace(body.Host)
	body.Action = strings.TrimSpace(body.Action)
	body.Unit = strings.TrimSpace(body.Unit)
	if body.Host == "" {
		http.Error(w, "host is required", http.StatusBadRequest)
		return
	}
	if !fleetActions[body.Action] {
		http.Error(w, "unknown action", http.StatusBadRequest)
		return
	}
	// Both current actions target a unit; sanitize before it hits the queue.
	if !validUnitName(body.Unit) {
		http.Error(w, "invalid unit name", http.StatusBadRequest)
		return
	}
	if body.Lines < 1 || body.Lines > 2000 {
		body.Lines = 200
	}
	requester := strings.TrimSpace(body.Requester)
	if requester == "" {
		requester = "app"
	}

	res, err := db.Exec(
		`INSERT INTO commands (host, action, unit, lines, requester, status)
		 VALUES (?, ?, ?, ?, ?, 'pending')`,
		body.Host, body.Action, body.Unit, body.Lines, requester,
	)
	if err != nil {
		log.Printf("fleet: enqueue: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	id, _ := res.LastInsertId()
	// Audit line — every elevated request is logged, whoever made it.
	log.Printf("fleet: ENQUEUE id=%d host=%q action=%q unit=%q lines=%d requester=%q",
		id, body.Host, body.Action, body.Unit, body.Lines, requester)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"id": id})
}

func reportCommand(w http.ResponseWriter, r *http.Request) {
	var id int64
	if v := r.URL.Query().Get("id"); v != "" {
		fmt.Sscan(v, &id)
	}
	if id <= 0 {
		http.Error(w, "id is required", http.StatusBadRequest)
		return
	}
	var (
		host, action, unit, status, result, createdAt string
		resultCode                                    int
		doneAt                                        sql.NullString
	)
	row := db.QueryRow(
		`SELECT host, action, unit, status, result, result_code, created_at, done_at
		 FROM commands WHERE id=?`, id)
	if err := row.Scan(&host, &action, &unit, &status, &result, &resultCode, &createdAt, &doneAt); err != nil {
		if err == sql.ErrNoRows {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		log.Printf("fleet: report %d: %v", id, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	out := map[string]any{
		"id": id, "host": host, "action": action, "unit": unit,
		"status": status, "result": result, "result_code": resultCode,
		"created_at": normalizeTS(createdAt),
	}
	if doneAt.Valid {
		out["done_at"] = normalizeTS(doneAt.String)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(out)
}

// handleFleetPoll: a host agent long-polls for its next pending command and
// atomically claims it. Host scope (broadcast token). Returns 204 on timeout.
func handleFleetPoll() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		host := strings.TrimSpace(r.URL.Query().Get("host"))
		if host == "" {
			http.Error(w, "host is required", http.StatusBadRequest)
			return
		}
		deadline := time.Now().Add(25 * time.Second)
		for {
			var c fleetCommand
			row := db.QueryRow(
				`SELECT id, host, action, unit, lines FROM commands
				 WHERE host=? AND status='pending' ORDER BY id ASC LIMIT 1`, host)
			err := row.Scan(&c.ID, &c.Host, &c.Action, &c.Unit, &c.Lines)
			if err == nil {
				// Atomic claim — only one poller wins even with duplicates.
				res, cerr := db.Exec(
					`UPDATE commands SET status='claimed', claimed_at=CURRENT_TIMESTAMP
					 WHERE id=? AND status='pending'`, c.ID)
				if cerr != nil {
					log.Printf("fleet: claim %d: %v", c.ID, cerr)
					continue // transient (e.g. lock) — retry the whole loop
				}
				if n, _ := res.RowsAffected(); n == 1 {
					log.Printf("fleet: CLAIM id=%d host=%q action=%q unit=%q", c.ID, host, c.Action, c.Unit)
					w.Header().Set("Content-Type", "application/json")
					json.NewEncoder(w).Encode(c)
					return
				}
				continue // lost the race; look again immediately
			} else if err != sql.ErrNoRows {
				log.Printf("fleet: poll %q: %v", host, err)
				http.Error(w, "internal error", http.StatusInternalServerError)
				return
			}
			if time.Now().After(deadline) {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			select {
			case <-r.Context().Done():
				return
			case <-time.After(time.Second):
			}
		}
	}
}

// handleFleetResult: a host agent posts the outcome of a claimed command. Host
// scope. Only a claimed command can transition to done/error.
func handleFleetResult() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			ID         int64  `json:"id"`
			Status     string `json:"status"`
			Result     string `json:"result"`
			ResultCode int    `json:"result_code"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if body.Status != "done" && body.Status != "error" {
			http.Error(w, "status must be done|error", http.StatusBadRequest)
			return
		}
		// Cap stored result so a runaway journal can't bloat the DB.
		const maxResult = 256 * 1024
		if len(body.Result) > maxResult {
			body.Result = body.Result[:maxResult] + "\n…[truncated]"
		}
		res, err := db.Exec(
			`UPDATE commands SET status=?, result=?, result_code=?, done_at=CURRENT_TIMESTAMP
			 WHERE id=? AND status='claimed'`,
			body.Status, body.Result, body.ResultCode, body.ID)
		if err != nil {
			log.Printf("fleet: result %d: %v", body.ID, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if n, _ := res.RowsAffected(); n == 0 {
			http.Error(w, "no claimed command with that id", http.StatusConflict)
			return
		}
		log.Printf("fleet: RESULT id=%d status=%q code=%d bytes=%d", body.ID, body.Status, body.ResultCode, len(body.Result))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"ok": true})
	}
}

func handleWS(h *hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.URL.Query().Get("token")
		if token != authToken {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		if h.connectedCount() >= 15 {
			http.Error(w, "too many connections", http.StatusServiceUnavailable)
			return
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("ws upgrade: %v", err)
			return
		}

		c := &client{conn: conn, send: make(chan []byte, 64)}
		h.reg <- c

		ns, err := queryHistory(100, 0)
		if err != nil {
			log.Printf("ws history: %v", err)
		}
		if ns == nil {
			ns = []Notification{}
		}
		histMsg := wsMessage{Type: "history", Notifications: ns}
		data, _ := json.Marshal(histMsg)
		select {
		case c.send <- data:
		default:
		}

		go writePump(c)
		go pingPump(c)
		readPump(h, c)
		log.Printf("ws: client disconnected from %s", conn.RemoteAddr())
	}
}

// ── Main ──────────────────────────────────────────────────────────────────────

func main() {
	flag.Parse()

	switch {
	case *flagTokenFile != "":
		raw, err := os.ReadFile(*flagTokenFile)
		if err != nil {
			log.Fatalf("read token file: %v", err)
		}
		authToken = strings.TrimSpace(string(raw))
		if authToken == "" {
			log.Fatal("token file is empty")
		}
	case *flagToken != "":
		authToken = *flagToken
	default:
		log.Fatal("one of --token-file or --token is required")
	}

	// Control scope is optional. When unset, /fleet/command returns 503 and the
	// log/control feature is simply off.
	switch {
	case *flagControlTokenFile != "":
		raw, err := os.ReadFile(*flagControlTokenFile)
		if err != nil {
			log.Fatalf("read control-token file: %v", err)
		}
		controlToken = strings.TrimSpace(string(raw))
	case *flagControlToken != "":
		controlToken = *flagControlToken
	}
	if controlToken == authToken && controlToken != "" {
		log.Fatal("control token must differ from the broadcast token")
	}

	if err := initDB(*flagDB); err != nil {
		log.Fatalf("init db: %v", err)
	}
	log.Printf("database: %s", *flagDB)
	if controlToken != "" {
		log.Printf("fleet control scope: ENABLED")
	} else {
		log.Printf("fleet control scope: disabled (no control token)")
	}

	h := newHub()
	go h.run()
	go startHeartbeatChecker(h, *flagHeartbeatMissed)
	go startCommandReaper()

	mux := http.NewServeMux()
	mux.HandleFunc("/send", requireBearer(handleSend(h)))
	mux.HandleFunc("/heartbeat", requireBearer(handleHeartbeat(h)))
	mux.HandleFunc("/history", requireBearer(handleHistory()))
	mux.HandleFunc("/mark-seen", requireBearer(handleMarkSeen()))
	mux.HandleFunc("/notifications", requireBearer(handleDeleteNotifications()))
	mux.HandleFunc("/machines", requireBearer(handleMachines(*flagHeartbeatMissed)))
	mux.HandleFunc("/metrics", requireBearer(handleMetrics()))
	mux.HandleFunc("/metrics/latest", requireBearer(handleMetricsLatest()))
	// Fleet command queue: /command is elevated (control scope); the host-facing
	// /poll and /result use the broadcast token the agents already hold.
	mux.HandleFunc("/fleet/command", requireControl(handleFleetCommand()))
	mux.HandleFunc("/fleet/poll", requireBearer(handleFleetPoll()))
	mux.HandleFunc("/fleet/result", requireBearer(handleFleetResult()))
	mux.HandleFunc("/ws", handleWS(h))
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	addr := "127.0.0.1:" + *flagPort
	log.Printf("aisthetron listening on %s (heartbeat-missed=%d)", addr, *flagHeartbeatMissed)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("listen: %v", err)
	}
}
