// aisthetron-agent is the host-side worker for the fleet command queue.
//
// It long-polls the relay for a command addressed to this host, and — crucially —
// is the FINAL authority on what runs here. Every command is checked against a
// closed action set AND a locally-declared unit allowlist before anything is
// executed. Commands are run with an explicit argv via os/exec (never a shell),
// so there is no string-interpolation / injection surface.
//
// This phase is READ-ONLY by construction: the only actions are `journal`
// (journalctl) and `unit-status` (systemctl status). There is deliberately NO
// start/stop/restart code path. Adding one is a reviewed change that also needs a
// matching polkit grant — reading journals/status needs no privilege at all.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

var (
	flagRelay      = flag.String("relay", "", "relay base URL, e.g. https://notify.ilios.dev")
	flagHost       = flag.String("host", "", "this host's source name (must match its heartbeat source)")
	flagTokenFile  = flag.String("token-file", "", "path to the relay bearer token file")
	flagUnits      = flag.String("units", "", "comma-separated allowlist of systemd units this agent may inspect")
	flagJournalctl = flag.String("journalctl", "journalctl", "path to the journalctl binary")
	flagSystemctl  = flag.String("systemctl", "systemctl", "path to the systemctl binary")
)

// allowedActions mirrors the server's closed enum. Read-only, by design.
var allowedActions = map[string]bool{
	"journal":     true,
	"unit-status": true,
}

type command struct {
	ID     int64  `json:"id"`
	Host   string `json:"host"`
	Action string `json:"action"`
	Unit   string `json:"unit"`
	Lines  int    `json:"lines"`
}

var (
	token   string
	units   map[string]bool
	relay   string
	host    string
	httpCli = &http.Client{Timeout: 40 * time.Second}
)

func main() {
	flag.Parse()
	if *flagRelay == "" || *flagHost == "" || *flagTokenFile == "" {
		log.Fatal("--relay, --host and --token-file are required")
	}
	raw, err := os.ReadFile(*flagTokenFile)
	if err != nil {
		log.Fatalf("read token file: %v", err)
	}
	token = strings.TrimSpace(string(raw))
	if token == "" {
		log.Fatal("token file is empty")
	}
	relay = strings.TrimRight(*flagRelay, "/")
	host = *flagHost

	units = map[string]bool{}
	for _, u := range strings.Split(*flagUnits, ",") {
		if u = strings.TrimSpace(u); u != "" {
			units[u] = true
		}
	}
	log.Printf("aisthetron-agent: host=%q relay=%q units=%d (read-only)", host, relay, len(units))

	for {
		cmd, err := poll()
		if err != nil {
			log.Printf("poll: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}
		if cmd == nil {
			continue // long-poll timed out with nothing to do
		}
		handle(cmd)
	}
}

// poll long-polls the relay for the next command for this host.
func poll() (*command, error) {
	url := fmt.Sprintf("%s/fleet/poll?host=%s", relay, host)
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := httpCli.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusNoContent:
		return nil, nil
	case http.StatusOK:
		var c command
		if err := json.NewDecoder(resp.Body).Decode(&c); err != nil {
			return nil, fmt.Errorf("decode command: %w", err)
		}
		return &c, nil
	default:
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		return nil, fmt.Errorf("relay returned %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
}

// handle validates and executes a command, then reports the result.
func handle(c *command) {
	log.Printf("command id=%d action=%q unit=%q lines=%d", c.ID, c.Action, c.Unit, c.Lines)

	// Gate 1: closed action set.
	if !allowedActions[c.Action] {
		reject(c, fmt.Sprintf("action %q not permitted by this agent", c.Action))
		return
	}
	// Gate 2: local unit allowlist — the host is the final authority.
	if !units[c.Unit] {
		reject(c, fmt.Sprintf("unit %q is not in this host's allowlist", c.Unit))
		return
	}

	lines := c.Lines
	if lines < 1 || lines > 2000 {
		lines = 200
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	var argv []string
	switch c.Action {
	case "journal":
		argv = []string{*flagJournalctl, "-u", c.Unit, "-n", strconv.Itoa(lines),
			"--no-pager", "--output", "short-iso"}
	case "unit-status":
		argv = []string{*flagSystemctl, "status", c.Unit, "--no-pager", "--full",
			"--lines", strconv.Itoa(lines)}
	}

	// Explicit argv, no shell. c.Unit is an exact member of the allowlist, so no
	// interpolation risk even in principle.
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	runErr := cmd.Run()

	code := 0
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			code = ee.ExitCode() // a failed unit legitimately exits non-zero
		} else {
			// Couldn't even spawn (missing binary, timeout) — that's an agent error.
			reject(c, fmt.Sprintf("exec failed: %v", runErr))
			return
		}
	}
	report(c, "done", out.String(), code)
}

func reject(c *command, msg string) {
	log.Printf("REJECT id=%d: %s", c.ID, msg)
	report(c, "error", msg, -1)
}

func report(c *command, status, result string, code int) {
	body, _ := json.Marshal(map[string]any{
		"id": c.ID, "status": status, "result": result, "result_code": code,
	})
	req, _ := http.NewRequest(http.MethodPost, relay+"/fleet/result", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpCli.Do(req)
	if err != nil {
		log.Printf("report id=%d: %v", c.ID, err)
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		log.Printf("report id=%d: relay returned %d", c.ID, resp.StatusCode)
	}
}
