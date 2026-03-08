package main

import (
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
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
)

var authToken string

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
	db, err = sql.Open("sqlite", path)
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
			alerted   INTEGER NOT NULL DEFAULT 0
		)
	`)
	return err
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

func checkHeartbeats(h *hub, missedThreshold int) {
	rows, err := db.Query(
		`SELECT source, interval, last_seen, alerted FROM heartbeats`,
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
	}
	var sources []hbRow

	for rows.Next() {
		var (
			source      string
			interval    int
			lastSeenStr string
			alertedInt  int
		)
		if err := rows.Scan(&source, &interval, &lastSeenStr, &alertedInt); err != nil {
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
		})
	}

	for _, hb := range sources {
		deadline := hb.lastSeen.Add(time.Duration(hb.interval*missedThreshold) * time.Second)
		isDown := time.Now().UTC().After(deadline)

		if isDown && !hb.alerted {
			silence := time.Since(hb.lastSeen).Round(time.Second)
			n, err := insertNotification(
				hb.source+" unreachable",
				fmt.Sprintf("No heartbeat for %s (%d missed × %ds interval).", silence, missedThreshold, hb.interval),
				"andrNoti",
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

func requireBearer(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		v := r.Header.Get("Authorization")
		if !strings.HasPrefix(v, "Bearer ") || strings.TrimPrefix(v, "Bearer ") != authToken {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

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
			Source   string `json:"source"`
			Interval int    `json:"interval"`
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

		// Check if this source was previously marked as down.
		var alertedInt int
		wasAlerted := false
		row := db.QueryRow(`SELECT alerted FROM heartbeats WHERE source = ?`, body.Source)
		if err := row.Scan(&alertedInt); err == nil {
			wasAlerted = alertedInt != 0
		}

		// Upsert — resets last_seen and clears alerted.
		_, err := db.Exec(`
			INSERT INTO heartbeats (source, interval, last_seen, alerted)
			VALUES (?, ?, CURRENT_TIMESTAMP, 0)
			ON CONFLICT(source) DO UPDATE SET
				interval  = excluded.interval,
				last_seen = CURRENT_TIMESTAMP,
				alerted   = 0
		`, body.Source, body.Interval)
		if err != nil {
			log.Printf("heartbeat: upsert %q: %v", body.Source, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		if wasAlerted {
			// Send recovery notification.
			n, err := insertNotification(
				body.Source+" recovered",
				"Heartbeat resumed after outage.",
				"andrNoti",
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

	if err := initDB(*flagDB); err != nil {
		log.Fatalf("init db: %v", err)
	}
	log.Printf("database: %s", *flagDB)

	h := newHub()
	go h.run()
	go startHeartbeatChecker(h, *flagHeartbeatMissed)

	mux := http.NewServeMux()
	mux.HandleFunc("/send", requireBearer(handleSend(h)))
	mux.HandleFunc("/heartbeat", requireBearer(handleHeartbeat(h)))
	mux.HandleFunc("/history", requireBearer(handleHistory()))
	mux.HandleFunc("/mark-seen", requireBearer(handleMarkSeen()))
	mux.HandleFunc("/notifications", requireBearer(handleDeleteNotifications()))
	mux.HandleFunc("/ws", handleWS(h))
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	addr := "127.0.0.1:" + *flagPort
	log.Printf("andrNoti listening on %s (heartbeat-missed=%d)", addr, *flagHeartbeatMissed)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("listen: %v", err)
	}
}
