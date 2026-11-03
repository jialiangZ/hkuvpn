package main

import (
	"encoding/json"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The knobs the worker reads from hku.env. The app edits them so the
// advanced options do not need a text editor.
type settings struct {
	Endpoint     string
	SocksPort    int
	HttpPort     int
	DTLS         bool
	NRPT         bool
	NRPTDomains  string
	AutoRoutes   bool
	RoutePrefix  int
	RouteMax     int
	RouteTTL     int
	ProxyDomains string
	ExtraRoutes  string
}

func defaultSettings() settings {
	return settings{
		SocksPort:   1080,
		HttpPort:    1088,
		DTLS:        true,
		NRPT:        true,
		NRPTDomains: "hku.hk",
		AutoRoutes:  true,
		RoutePrefix: 24,
		RouteMax:    512,
		RouteTTL:    14,
	}
}

// envMap reads the key=value pairs of the worker's env file, the way the
// worker's Read-EnvFile does: comments and blank lines are skipped and a
// quoted value loses its quotes.
func envMap() map[string]string {
	out := map[string]string{}
	for _, line := range readLines(envFile()) {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		eq := strings.Index(t, "=")
		if eq < 1 {
			continue
		}
		key := strings.TrimSpace(t[:eq])
		val := strings.TrimSpace(t[eq+1:])
		if len(val) >= 2 && ((strings.HasPrefix(val, `"`) && strings.HasSuffix(val, `"`)) ||
			(strings.HasPrefix(val, "'") && strings.HasSuffix(val, "'"))) {
			val = val[1 : len(val)-1]
		}
		out[key] = val
	}
	return out
}

func loadSettings() settings {
	s := defaultSettings()
	m := envMap()
	if v := strings.TrimSpace(m["HKU_ENDPOINT"]); v != "" {
		s.Endpoint = v
	}
	if v, err := strconv.Atoi(m["HKU_SOCKS_PORT"]); err == nil && v > 0 && v < 65536 {
		s.SocksPort = v
	}
	if v, err := strconv.Atoi(m["HKU_HTTP_PORT"]); err == nil && v > 0 && v < 65536 {
		s.HttpPort = v
	}
	s.DTLS = m["HKU_DTLS"] != "0"
	s.NRPT = m["HKU_NRPT"] != "0"
	if v := strings.TrimSpace(m["HKU_NRPT_DOMAINS"]); v != "" {
		s.NRPTDomains = v
	}
	s.AutoRoutes = m["HKU_AUTO_ROUTES"] != "0"
	if v, err := strconv.Atoi(m["HKU_AUTO_ROUTES_PREFIX"]); err == nil && v >= 8 && v <= 32 {
		s.RoutePrefix = v
	}
	if v, err := strconv.Atoi(m["HKU_AUTO_ROUTES_MAX"]); err == nil && v >= 1 && v <= 10000 {
		s.RouteMax = v
	}
	if v, err := strconv.Atoi(m["HKU_AUTO_ROUTES_TTL"]); err == nil && v >= 1 && v <= 365 {
		s.RouteTTL = v
	}
	s.ProxyDomains = strings.TrimSpace(m["HKU_PROXY_DOMAINS"])
	s.ExtraRoutes = strings.TrimSpace(m["HKU_EXTRA_ROUTES"])
	return s
}

// setEnvValues rewrites the worker's env file with the given keys and
// keeps every line it does not know about. An empty value unsets its key.
func setEnvValues(values map[string]string) error {
	lines := readLines(envFile())
	out := make([]string, 0, len(lines)+len(values))
	seen := map[string]bool{}
	for _, line := range lines {
		key := ""
		t := strings.TrimSpace(line)
		if !strings.HasPrefix(t, "#") {
			if eq := strings.Index(t, "="); eq > 0 {
				key = strings.TrimSpace(t[:eq])
			}
		}
		if v, ok := values[key]; ok && key != "" {
			seen[key] = true
			if v == "" {
				continue // unset
			}
			out = append(out, key+"="+v)
			continue
		}
		out = append(out, line)
	}
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if seen[k] || values[k] == "" {
			continue
		}
		out = append(out, k+"="+values[k])
	}
	_ = os.MkdirAll(vpnDir(), 0o700)
	body := strings.Join(out, "\r\n")
	if body != "" {
		body += "\r\n"
	}
	return os.WriteFile(envFile(), []byte(body), 0o600)
}

// saveSettings writes the advanced options back to the worker's env file.
// The account and the PIN are left alone.
func saveSettings(s settings) error {
	values := map[string]string{
		"HKU_ENDPOINT":           s.Endpoint,
		"HKU_SOCKS_PORT":         strconv.Itoa(s.SocksPort),
		"HKU_HTTP_PORT":          strconv.Itoa(s.HttpPort),
		"HKU_AUTO_ROUTES_PREFIX": strconv.Itoa(s.RoutePrefix),
		"HKU_AUTO_ROUTES_MAX":    strconv.Itoa(s.RouteMax),
		"HKU_AUTO_ROUTES_TTL":    strconv.Itoa(s.RouteTTL),
		"HKU_PROXY_DOMAINS":      s.ProxyDomains,
		"HKU_EXTRA_ROUTES":       s.ExtraRoutes,
		"HKU_NRPT_DOMAINS":       s.NRPTDomains,
	}
	if !s.DTLS {
		values["HKU_DTLS"] = "0"
	}
	if !s.NRPT {
		values["HKU_NRPT"] = "0"
	}
	if !s.AutoRoutes {
		values["HKU_AUTO_ROUTES"] = "0"
	}
	return setEnvValues(values)
}

// appState is what the app keeps for itself: the preferences the user set
// and the start time of the running session, so the timer survives a
// restart of the app.
type appState struct {
	AutoStart      bool      `json:"autoStart"`
	AutoReconnect  bool      `json:"autoReconnect"`
	ConnectOnStart bool      `json:"connectOnStart"`
	SessionStart   time.Time `json:"sessionStart,omitempty"`
}

func appStatePath() string { return joinPath(configDir(), "app-state.json") }

func loadAppState() appState {
	var s appState
	b, err := os.ReadFile(appStatePath())
	if err != nil {
		return s
	}
	_ = json.Unmarshal(b, &s)
	return s
}

func saveAppState(s appState) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	_ = os.MkdirAll(vpnDir(), 0o700)
	return os.WriteFile(appStatePath(), b, 0o600)
}

// settingsForm is the editable copy of the settings, with the numbers as
// the number inputs want them.
type settingsForm struct {
	Endpoint     string
	SocksPort    float64
	HttpPort     float64
	DTLS         bool
	NRPT         bool
	NRPTDomains  string
	AutoRoutes   bool
	RoutePrefix  float64
	RouteMax     float64
	RouteTTL     float64
	ProxyDomains string
	ExtraRoutes  string

	// The app's own preferences.
	AutoStart      bool
	AutoReconnect  bool
	ConnectOnStart bool
}

func newSettingsForm(s settings, prefs appState) settingsForm {
	return settingsForm{
		Endpoint:       s.Endpoint,
		SocksPort:      float64(s.SocksPort),
		HttpPort:       float64(s.HttpPort),
		DTLS:           s.DTLS,
		NRPT:           s.NRPT,
		NRPTDomains:    s.NRPTDomains,
		AutoRoutes:     s.AutoRoutes,
		RoutePrefix:    float64(s.RoutePrefix),
		RouteMax:       float64(s.RouteMax),
		RouteTTL:       float64(s.RouteTTL),
		ProxyDomains:   s.ProxyDomains,
		ExtraRoutes:    s.ExtraRoutes,
		AutoStart:      prefs.AutoStart,
		AutoReconnect:  prefs.AutoReconnect,
		ConnectOnStart: prefs.ConnectOnStart,
	}
}

// apply turns the form back into the settings and the preferences, with
// the numbers clamped to what the worker accepts.
func (f settingsForm) apply() (settings, appState) {
	s := defaultSettings()
	s.Endpoint = strings.TrimSpace(f.Endpoint)
	s.SocksPort = clampInt(int(f.SocksPort), 1, 65535, 1080)
	s.HttpPort = clampInt(int(f.HttpPort), 1, 65535, 1088)
	s.DTLS = f.DTLS
	s.NRPT = f.NRPT
	s.NRPTDomains = strings.TrimSpace(f.NRPTDomains)
	if s.NRPTDomains == "" {
		s.NRPTDomains = "hku.hk"
	}
	s.AutoRoutes = f.AutoRoutes
	s.RoutePrefix = clampInt(int(f.RoutePrefix), 8, 32, 24)
	s.RouteMax = clampInt(int(f.RouteMax), 1, 10000, 512)
	s.RouteTTL = clampInt(int(f.RouteTTL), 1, 365, 14)
	s.ProxyDomains = strings.TrimSpace(f.ProxyDomains)
	s.ExtraRoutes = strings.TrimSpace(f.ExtraRoutes)

	prefs := appState{
		AutoStart:      f.AutoStart,
		AutoReconnect:  f.AutoReconnect,
		ConnectOnStart: f.ConnectOnStart,
	}
	return s, prefs
}

func clampInt(v, low, high, fallback int) int {
	if v < low || v > high {
		return fallback
	}
	return v
}
