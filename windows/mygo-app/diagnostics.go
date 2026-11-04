package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"golang.org/x/net/proxy"
)

// checkResult is one line of a diagnostic run.
type checkResult struct {
	Name string
	OK   bool
	Warn bool
	Note string
}

// The proxy self-test talks to the internet through the tunnel, so the
// addresses it uses are plain HTTP services that answer with one line.
var (
	ipServices = []string{
		"https://api.ipify.org",
		"http://ip-api.com/line/?fields=query",
	}
)

// ---------------------------------------------------------------- preflight

// windowsDir is the repo's windows directory, where the worker, the tools
// and the tunnel script live.
func windowsDir() string {
	script := findLauncher()
	if script == "" {
		return ""
	}
	return parentDir(parentDir(script))
}

// findOpenConnect and findGost look for the tools where the worker looks
// for them: the tools directory, the usual install places, then the PATH.
func findOpenConnect() string {
	if v := os.Getenv("HKUVPN_OPENCONNECT"); v != "" && fileExists(v) {
		return v
	}
	var candidates []string
	if dir := windowsDir(); dir != "" {
		candidates = append(candidates, joinPath(joinPath(dir, "tools"), "openconnect.exe"))
	}
	if pf := os.Getenv("ProgramFiles"); pf != "" {
		candidates = append(candidates,
			joinPath(joinPath(pf, "OpenConnect"), "openconnect.exe"),
			joinPath(joinPath(pf, "OpenConnect"), `bin\openconnect.exe`))
	}
	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}
	if path, err := exec.LookPath("openconnect.exe"); err == nil {
		return path
	}
	return ""
}

func findGost() string {
	if v := os.Getenv("HKUVPN_GOST"); v != "" && fileExists(v) {
		return v
	}
	if dir := windowsDir(); dir != "" {
		candidate := joinPath(joinPath(dir, "tools"), "gost.exe")
		if fileExists(candidate) {
			return candidate
		}
	}
	if path, err := exec.LookPath("gost.exe"); err == nil {
		return path
	}
	return ""
}

// portFree says whether nothing listens on the loopback port.
func portFree(port int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 400*time.Millisecond)
	if err != nil {
		return true
	}
	_ = conn.Close()
	return false
}

// runPreflight checks everything the worker needs before it can connect,
// the way "hkuvpn.ps1 --check" does, but in the app so the answers can be
// shown one by one.
func runPreflight(s settings) []checkResult {
	var out []checkResult
	add := func(name string, ok bool, warn bool, note string) {
		out = append(out, checkResult{Name: name, OK: ok, Warn: warn, Note: note})
	}

	// The launcher and the tunnel script.
	script := findLauncher()
	if script == "" {
		add("Launcher", false, false, "hkuvpn.ps1 not found next to the app")
	} else {
		add("Launcher", true, false, script)
	}
	if dir := windowsDir(); dir != "" {
		vpnc := joinPath(joinPath(dir, "etc"), "vpnc-script-win.js")
		if fileExists(vpnc) {
			add("Tunnel script", true, false, vpnc)
		} else {
			add("Tunnel script", false, false, "etc\\vpnc-script-win.js is missing")
		}
	} else {
		add("Tunnel script", false, false, "the hkuvpn repo was not found")
	}

	// The account and the PIN.
	m := envMap()
	user := strings.TrimSpace(m["HKU_USER"])
	switch {
	case user == "":
		add("Account", false, false, "HKU_USER is not set in hku.env")
	case strings.HasPrefix(user, "youruid@"):
		add("Account", false, false, "HKU_USER still holds the placeholder")
	default:
		add("Account", true, false, user)
	}
	if pin := storedPIN(); pin == "" {
		add("Portal PIN", false, false, "hku.pass is missing or empty")
	} else {
		add("Portal PIN", true, false, "stored")
	}

	// The tools.
	if oc := findOpenConnect(); oc != "" {
		add("OpenConnect", true, false, oc)
	} else {
		add("OpenConnect", false, false, "not found - run windows\\bin\\get-tools.ps1")
	}
	if gost := findGost(); gost != "" {
		add("gost", true, false, gost)
	} else {
		add("gost", false, false, "not found - run windows\\bin\\get-tools.ps1")
	}
	if curl, err := exec.LookPath("curl.exe"); err == nil {
		add("curl.exe", true, false, curl)
	} else {
		add("curl.exe", true, true, "missing - the status check cannot test the tunnel")
	}

	// The local proxy ports.
	switch {
	case workerAlive():
		add("Proxy ports", true, false, fmt.Sprintf("%d and %d belong to the running session", s.SocksPort, s.HttpPort))
	case !portFree(s.SocksPort) && !portFree(s.HttpPort):
		add("Proxy ports", false, false, fmt.Sprintf("%d and %d are in use by something else", s.SocksPort, s.HttpPort))
	case !portFree(s.SocksPort):
		add("Proxy ports", false, false, fmt.Sprintf("%d is in use - change HKU_SOCKS_PORT", s.SocksPort))
	case !portFree(s.HttpPort):
		add("Proxy ports", false, false, fmt.Sprintf("%d is in use - change HKU_HTTP_PORT", s.HttpPort))
	default:
		add("Proxy ports", true, false, fmt.Sprintf("%d and %d are free", s.SocksPort, s.HttpPort))
	}

	// The certificate pin cache and the learned routes.
	if fileExists(joinPath(vpnDir(), "pin-hk.cache")) {
		add("Certificate pin", true, false, "cached")
	} else {
		add("Certificate pin", true, true, "not cached yet - it is fetched when connecting")
	}
	add("Learned routes", true, false, fmt.Sprintf("%d cached", len(readLearnedRoutes())))

	return out
}

// -------------------------------------------------------------- proxy test

// httpGetViaSocks fetches a URL through the SOCKS5 proxy.
func httpGetViaSocks(rawurl string, port int) (string, error) {
	dialer, err := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", port), nil, proxy.Direct)
	if err != nil {
		return "", err
	}
	ctxDialer, ok := dialer.(proxy.ContextDialer)
	if !ok {
		return "", fmt.Errorf("the SOCKS5 dialer cannot time out")
	}
	client := &http.Client{
		Timeout: 12 * time.Second,
		Transport: &http.Transport{
			DialContext: ctxDialer.DialContext,
		},
	}
	return fetchText(client, rawurl)
}

// httpGetViaHTTPProxy fetches a URL through the HTTP proxy.
func httpGetViaHTTPProxy(rawurl string, port int) (string, error) {
	proxyURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	if err != nil {
		return "", err
	}
	client := &http.Client{
		Timeout:   12 * time.Second,
		Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)},
	}
	return fetchText(client, rawurl)
}

func fetchText(client *http.Client, rawurl string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawurl, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return strings.TrimSpace(string(body)), nil
}

// runProxyTest checks that the local proxies answer and that the traffic
// leaves through the campus.
func runProxyTest(s settings) []checkResult {
	var out []checkResult
	add := func(name string, ok bool, warn bool, note string) {
		out = append(out, checkResult{Name: name, OK: ok, Warn: warn, Note: note})
	}

	// The ports answer.
	socksUp, httpUp := false, false
	if conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", s.SocksPort), 2*time.Second); err == nil {
		_ = conn.Close()
		socksUp = true
	}
	if conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", s.HttpPort), 2*time.Second); err == nil {
		_ = conn.Close()
		httpUp = true
	}
	if socksUp {
		add("SOCKS5 port", true, false, fmt.Sprintf("127.0.0.1:%d answers", s.SocksPort))
	} else {
		add("SOCKS5 port", false, false, fmt.Sprintf("nothing listens on 127.0.0.1:%d", s.SocksPort))
	}
	if httpUp {
		add("HTTP port", true, false, fmt.Sprintf("127.0.0.1:%d answers", s.HttpPort))
	} else {
		add("HTTP port", false, false, fmt.Sprintf("nothing listens on 127.0.0.1:%d", s.HttpPort))
	}
	if !socksUp && !httpUp {
		return out
	}

	// The proxies carry a request.
	if socksUp {
		if body, err := httpGetViaSocks(ipServices[0], s.SocksPort); err == nil {
			add("SOCKS5 request", true, false, "the tunnel answered "+ipServices[0])
			add("Egress address", true, false, body)
		} else {
			add("SOCKS5 request", false, false, err.Error())
			add("Egress address", false, true, "unknown - the request did not get through")
		}
	}
	if httpUp {
		if _, err := httpGetViaHTTPProxy(ipServices[1], s.HttpPort); err == nil {
			add("HTTP request", true, false, "the tunnel answered "+ipServices[1])
		} else {
			add("HTTP request", false, false, err.Error())
		}
	}
	return out
}

// --------------------------------------------------------------- autostart

const (
	runKey   = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
	runValue = "HKUVPN"
)

// autostartEnabled says whether the app is registered to start with
// Windows.
func autostartEnabled() bool {
	out, err := exec.Command("reg.exe", "query", runKey, "/v", runValue).CombinedOutput()
	return err == nil && strings.Contains(string(out), runValue)
}

// setAutostart registers or removes the app in the Run key, so it starts
// with Windows.
func setAutostart(enabled bool) error {
	if !enabled {
		return deleteAutostartValue(runKey, runValue)
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	out, err := exec.Command("reg.exe", "add", runKey, "/v", runValue, "/t", "REG_SZ",
		"/d", `"`+exe+`"`, "/f").CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s", strings.TrimSpace(acpDecode(out)))
	}
	return nil
}

// deleteAutostartValue removes a value from the Run key. A value that is
// not there is not an error: the state the user asked for is already the
// state on disk.
func deleteAutostartValue(key, name string) error {
	out, err := exec.Command("reg.exe", "delete", key, "/v", name, "/f").CombinedOutput()
	if err != nil && !valueMissing(acpDecode(out)) {
		return fmt.Errorf("%s", strings.TrimSpace(acpDecode(out)))
	}
	return nil
}

// valueMissing says whether reg.exe only complained that the value is not
// there, which is what deleting an absent value says - the state the user
// asked for is already the state on disk. The message is in the console's
// code page, so it is compared after decoding it.
func valueMissing(msg string) bool {
	m := strings.ToLower(msg)
	return strings.Contains(m, "cannot find") ||
		strings.Contains(m, "unable to find") ||
		strings.Contains(m, "not found") ||
		strings.Contains(m, "找不到") ||
		strings.Contains(m, "无法找到")
}
