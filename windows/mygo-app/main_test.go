package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

// The view runs without a window, which is how MyGo tests native UI.
func TestViewShowsTheDisconnectedState(t *testing.T) {
	a := newApp()
	tt := ui.NewTester(a.view, 480, 600)

	for _, want := range []string{"Disconnected", "VPN address", "Proxy", "Routes", "Connect", "HKU account", "Portal PIN"} {
		if !tt.HasText(want) {
			t.Errorf("missing text %q", want)
		}
	}
}

func TestTrayIconFollowsTheSession(t *testing.T) {
	a := newApp()
	if got := a.trayIconName(); got != "assets/tray-gray.png" {
		t.Errorf("idle icon = %q", got)
	}
	a.state = connecting
	if got := a.trayIconName(); got != "assets/tray-amber.png" {
		t.Errorf("connecting icon = %q", got)
	}
	a.state = connected
	a.workerOK, a.hbOK = true, true
	if got := a.trayIconName(); got != "assets/tray-green.png" {
		t.Errorf("connected icon = %q", got)
	}
	a.hbOK = false
	if got := a.trayIconName(); got != "assets/tray-red.png" {
		t.Errorf("unresponsive icon = %q", got)
	}
}

// A read that lands while the worker is mid-write must not swallow a
// marker: the trailing partial line is held back until it is complete.
func TestNewMarkerLinesHoldsBackPartialLines(t *testing.T) {
	first := "HKUVPN_MFA_RESPONSE_REQUIRED"
	b := []byte(first + "\nHKUVPN_CONN")
	lines, next := newMarkerLines(b, 0)
	if len(lines) != 1 || lines[0] != first {
		t.Fatalf("lines %q, want %q", lines, first)
	}
	if next != int64(len(first)+1) {
		t.Fatalf("next %d, want %d", next, len(first)+1)
	}
	b = []byte(first + "\nHKUVPN_CONNECTED\n")
	lines, next = newMarkerLines(b, next)
	if len(lines) != 1 || lines[0] != "HKUVPN_CONNECTED" {
		t.Fatalf("lines %q after completion", lines)
	}
}

// ------------------------------------------------------------ state machine

// isolatedConfig points the config files at a temporary directory, so the
// tests never touch the account of the user running them.
func isolatedConfig(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HKU_CONFIG_DIR", dir)
	return dir
}

// The markers drive the session: a code is asked for, the tunnel comes up,
// the worker gives up.
func TestMarkerDrivesTheSession(t *testing.T) {
	isolatedConfig(t)
	a := newApp()

	a.state = connecting
	a.applyMarker("2026-01-01 00:00:00 HKUVPN_MFA_RESPONSE_REQUIRED")
	if !a.mfaOpen {
		t.Fatal("the MFA dialog did not open")
	}
	if a.state != connecting {
		t.Fatalf("state = %v, want connecting", a.state)
	}

	// A rejected code asks for the current one.
	a.applyMarker("2026-01-01 00:00:01 HKUVPN_MFA_RETRY")
	a.applyMarker("2026-01-01 00:00:02 HKUVPN_MFA_RESPONSE_REQUIRED")
	if a.mfaNote == "" {
		t.Error("the retry was not mentioned")
	}

	a.applyMarker("2026-01-01 00:00:03 HKUVPN_CONNECTED")
	if a.state != connected {
		t.Fatalf("state = %v, want connected", a.state)
	}
	if a.mfaOpen {
		t.Error("the MFA dialog stayed open after the tunnel came up")
	}
	if a.connectedAt.IsZero() {
		t.Error("the session start time was not remembered")
	}
	// The start time is kept, so the timer survives a restart of the app.
	if a.prefs.SessionStart.IsZero() {
		t.Error("the session start was not written to the app state")
	}

	a.state = connecting
	a.applyMarker("2026-01-01 00:00:04 HKUVPN_EXITED")
	if a.state != idle {
		t.Fatalf("state = %v, want idle", a.state)
	}
}

// The MFA dialog opens only while a session is being built.
func TestMfaMarkerIsIgnoredWhenNotConnecting(t *testing.T) {
	isolatedConfig(t)
	a := newApp()
	a.state = connected
	a.applyMarker("2026-01-01 00:00:00 HKUVPN_MFA_RESPONSE_REQUIRED")
	if a.mfaOpen {
		t.Error("the MFA dialog opened outside a connection")
	}
}

// ----------------------------------------------------------------- settings

func TestSettingsRoundTrip(t *testing.T) {
	isolatedConfig(t)

	// A file with a comment and a key the app does not know.
	body := "# a comment\r\nHKU_USER=u1234567@connect.hku.hk\r\nSOMETHING_ELSE=keep me\r\n"
	if err := os.WriteFile(envFile(), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	s := defaultSettings()
	s.Endpoint = "vpn2fa.hku.hk"
	s.SocksPort = 1081
	s.HttpPort = 1089
	s.DTLS = false
	s.NRPT = false
	s.AutoRoutes = false
	s.RoutePrefix = 20
	s.RouteMax = 64
	s.RouteTTL = 7
	s.ProxyDomains = "library.hku.hk"
	s.ExtraRoutes = "10.0.0.0/8"
	if err := saveSettings(s); err != nil {
		t.Fatal(err)
	}

	got := loadSettings()
	if got.Endpoint != s.Endpoint || got.SocksPort != s.SocksPort || got.HttpPort != s.HttpPort {
		t.Errorf("endpoint/ports = %+v", got)
	}
	if got.DTLS || got.NRPT || got.AutoRoutes {
		t.Errorf("the switches did not survive: %+v", got)
	}
	if got.RoutePrefix != 20 || got.RouteMax != 64 || got.RouteTTL != 7 {
		t.Errorf("the route knobs did not survive: %+v", got)
	}
	if got.ProxyDomains != "library.hku.hk" || got.ExtraRoutes != "10.0.0.0/8" {
		t.Errorf("the text knobs did not survive: %+v", got)
	}

	// The account and the lines the app does not know are kept.
	lines := readLines(envFile())
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "HKU_USER=u1234567@connect.hku.hk") {
		t.Error("the account was lost")
	}
	if !strings.Contains(joined, "SOMETHING_ELSE=keep me") {
		t.Error("an unknown line was lost")
	}
	if !strings.Contains(joined, "# a comment") {
		t.Error("the comment was lost")
	}
}

// An empty value unsets its key, so the worker falls back to its default.
func TestEmptyValueUnsetsTheKey(t *testing.T) {
	isolatedConfig(t)
	if err := os.WriteFile(envFile(), []byte("HKU_ENDPOINT=vpn2fa.hku.hk\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := setEnvValues(map[string]string{"HKU_ENDPOINT": ""}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.Join(readLines(envFile()), "\n"), "HKU_ENDPOINT") {
		t.Error("the key was not unset")
	}
	if loadSettings().Endpoint != "" {
		t.Error("the endpoint was not cleared")
	}
}

// The form clamps the numbers to what the worker accepts.
func TestSettingsFormClampsTheNumbers(t *testing.T) {
	f := settingsForm{
		SocksPort:   99999,
		HttpPort:    0,
		RoutePrefix: 4,
		RouteMax:    0,
		RouteTTL:    1000,
	}
	s, _ := f.apply()
	if s.SocksPort != 1080 || s.HttpPort != 1088 {
		t.Errorf("ports = %d/%d", s.SocksPort, s.HttpPort)
	}
	if s.RoutePrefix != 24 || s.RouteMax != 512 || s.RouteTTL != 14 {
		t.Errorf("route knobs = %d/%d/%d", s.RoutePrefix, s.RouteMax, s.RouteTTL)
	}
}

// ------------------------------------------------------------------- routes

func TestLearnedRoutesRoundTrip(t *testing.T) {
	isolatedConfig(t)

	if err := addLearnedRoute("10.20.0.0/16", "library.hku.hk"); err != nil {
		t.Fatal(err)
	}
	if err := addLearnedRoute("10.30.0.0/16", "api.hku.hk"); err != nil {
		t.Fatal(err)
	}
	routes := readLearnedRoutes()
	if len(routes) != 2 {
		t.Fatalf("routes = %d, want 2", len(routes))
	}
	if routes[0].Cidr() != "10.20.0.0/16" || routes[0].Host != "library.hku.hk" {
		t.Errorf("route = %+v", routes[0])
	}
	if time.Since(routes[0].Seen) > time.Minute {
		t.Errorf("the learned time is wrong: %v", routes[0].Seen)
	}

	if err := deleteLearnedRoute("10.20.0.0"); err != nil {
		t.Fatal(err)
	}
	routes = readLearnedRoutes()
	if len(routes) != 1 || routes[0].Base != "10.30.0.0" {
		t.Fatalf("routes after delete = %+v", routes)
	}

	if err := addLearnedRoute("not a cidr", "x"); err == nil {
		t.Error("a bad CIDR was accepted")
	}
}

// The learned routes survive the worker reading them back: the format is
// the one the worker's Get-LearnedRoutes expects.
func TestLearnedRoutesUseTheWorkerFormat(t *testing.T) {
	isolatedConfig(t)
	if err := addLearnedRoute("10.20.0.0/16", "library.hku.hk"); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(learnedRoutesPath())
	if err != nil {
		t.Fatal(err)
	}
	line := strings.TrimSpace(string(body))
	parts := strings.Split(line, "|")
	if len(parts) != 3 {
		t.Fatalf("line %q", line)
	}
	if parts[0] != "10.20.0.0/16" || parts[2] != "library.hku.hk" {
		t.Errorf("line = %q", line)
	}
}

// --------------------------------------------------------------------- log

func TestVisibleLogFiltersByLevelAndText(t *testing.T) {
	a := newApp()
	a.logLines = []logEntry{
		{text: "Connected to vpn2fa.hku.hk", level: lvlInfo},
		{text: "Send DTLS Keepalive", level: lvlDebug},
		{text: "WARNING: Wintun is experimental", level: lvlWarn},
		{text: "DTLS handshake failed", level: lvlError},
	}

	a.logFilter = 1
	if got := len(a.visibleLog()); got != 3 {
		t.Errorf("Info+ shows %d lines, want 3", got)
	}
	a.logFilter = 2
	if got := len(a.visibleLog()); got != 2 {
		t.Errorf("Warnings shows %d lines, want 2", got)
	}
	a.logFilter = 3
	if got := len(a.visibleLog()); got != 1 {
		t.Errorf("Errors shows %d lines, want 1", got)
	}
	a.logFilter = 0
	a.logSearch = "keepalive"
	if got := len(a.visibleLog()); got != 1 {
		t.Errorf("the search shows %d lines, want 1", got)
	}
	a.logSearch = "KEEPALIVE"
	if got := len(a.visibleLog()); got != 1 {
		t.Errorf("the search is not case insensitive: %d lines", got)
	}
	a.logSearch = "nothing here"
	if got := len(a.visibleLog()); got != 0 {
		t.Errorf("the search shows %d lines, want 0", got)
	}
}

// ------------------------------------------------------------------ prefab

func TestAppStateRoundTrip(t *testing.T) {
	isolatedConfig(t)
	state := appState{
		AutoStart:      true,
		AutoReconnect:  true,
		ConnectOnStart: true,
		SessionStart:   time.Now().Round(time.Second),
	}
	if err := saveAppState(state); err != nil {
		t.Fatal(err)
	}
	got := loadAppState()
	if !got.AutoStart || !got.AutoReconnect || !got.ConnectOnStart {
		t.Errorf("the preferences did not survive: %+v", got)
	}
	if got.SessionStart.IsZero() {
		t.Error("the session start did not survive")
	}
}

// The app finds its own files: the config directory is honoured, so the
// tests and the worker agree on where the account lives.
func TestConfigDirFollowsTheEnvironment(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HKU_CONFIG_DIR", dir)
	if got := configDir(); got != dir {
		t.Errorf("configDir = %q, want %q", got, dir)
	}
	if got := envFile(); got != filepath.Join(dir, "hku.env") {
		t.Errorf("envFile = %q", got)
	}
	if got := learnedRoutesPath(); got != filepath.Join(dir, "learned-routes.txt") {
		t.Errorf("learnedRoutesPath = %q", got)
	}
}

// ------------------------------------------------------------- cancelling

// A cancel waits for the worker to be really gone, and gives up with a
// timeout when the worker does not stop in time.
func TestCancelOutcome(t *testing.T) {
	if got := cancelOutcome(false, true, time.Minute); got != cancelNone {
		t.Errorf("without a cancel: %v", got)
	}
	if got := cancelOutcome(true, true, time.Second); got != cancelNone {
		t.Errorf("while the worker lives: %v", got)
	}
	if got := cancelOutcome(true, false, time.Second); got != cancelIdle {
		t.Errorf("when the worker is gone: %v", got)
	}
	if got := cancelOutcome(true, true, 31*time.Second); got != cancelTimedOut {
		t.Errorf("after the timeout: %v", got)
	}
}

// The worker asks for a code: the app waits for it, and a closed dialog
// does not end the session.
func TestMfaPendingSurvivesTheDialog(t *testing.T) {
	isolatedConfig(t)
	a := newApp()
	a.state = connecting
	a.applyMarker("2026-11-04 06:23:00 HKUVPN_MFA_RESPONSE_REQUIRED")
	if !a.mfaPending {
		t.Fatal("the app does not know a code is needed")
	}
	if !a.mfaOpen {
		t.Fatal("the dialog did not open")
	}
	// The dialog is closed, the way a click outside it does.
	a.mfaOpen = false
	if !a.mfaPending {
		t.Error("closing the dialog dropped the pending code")
	}
	if a.state != connecting {
		t.Errorf("state = %v, want connecting", a.state)
	}
	// The code goes in.
	a.mfaCode = "123456"
	a.submitMFA()
	if a.mfaPending || a.mfaOpen {
		t.Error("the app still waits for a code it already got")
	}
}

// The session start time is kept, so the uptime survives a restart.
func TestSessionStartIsRemembered(t *testing.T) {
	isolatedConfig(t)
	a := newApp()
	a.state = connecting
	before := time.Now()
	a.applyMarker("2026-11-04 06:23:00 HKUVPN_CONNECTED")
	if a.prefs.SessionStart.Before(before.Add(-time.Minute)) {
		t.Errorf("the session start was not remembered: %v", a.prefs.SessionStart)
	}
	// A new app over the same state file keeps the timer.
	b := newApp()
	if b.prefs.SessionStart.IsZero() {
		t.Error("the session start did not survive")
	}
}
