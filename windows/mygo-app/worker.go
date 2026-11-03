package main

import (
	"bytes"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// The worker protocol: the frontend only reads and writes files under
// %TEMP%\hkuvpn and lets windows/bin/hkuvpn.ps1 do the privileged work.

type paths struct {
	base, markers, log, state, hb, pids, response, stop string
}

var p = loadPaths()

func loadPaths() paths {
	// Windows keeps the session files in %TEMP%; the tests (and any other
	// platform) use the temporary directory of the system.
	tmp := os.Getenv("TEMP")
	if tmp == "" {
		tmp = os.Getenv("TMPDIR")
	}
	if tmp == "" {
		tmp = os.TempDir()
	}
	base := joinPath(tmp, "hkuvpn")
	return paths{
		base:     base,
		markers:  joinPath(base, "markers.log"),
		log:      joinPath(base, "openconnect.log"),
		state:    joinPath(base, "vpnc-state.txt"),
		hb:       joinPath(base, "hb.log"),
		pids:     joinPath(base, "pids.txt"),
		response: joinPath(base, "response.txt"),
		stop:     joinPath(base, "stop.flag"),
	}
}

func joinPath(a, b string) string { return a + string(os.PathSeparator) + b }

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func readText(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return acpDecode(b)
}

func readLines(path string) []string {
	text := readText(path)
	if text == "" {
		return nil
	}
	text = strings.ReplaceAll(text, "\r\n", "\n")
	lines := strings.Split(text, "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	return lines
}

func writeText(path, text string) error {
	if dir := parentDir(path); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	return os.WriteFile(path, []byte(text), 0o644)
}

func parentDir(path string) string {
	if i := strings.LastIndexAny(path, `/\`); i > 0 {
		return path[:i]
	}
	return ""
}

func homeDir() string { return os.Getenv("USERPROFILE") }

// configDir is where the account, the PIN, the learned routes and the
// app's own state live. The worker reads the same place, and both honour
// HKU_CONFIG_DIR.
func configDir() string {
	if dir := os.Getenv("HKU_CONFIG_DIR"); dir != "" {
		return dir
	}
	return joinPath(homeDir(), ".vpn")
}

func vpnDir() string { return configDir() }

func envFile() string  { return joinPath(configDir(), "hku.env") }
func passFile() string { return joinPath(configDir(), "hku.pass") }

// ---------------------------------------------------------------- status

func workerPID() int {
	for _, line := range readLines(p.pids) {
		if strings.HasPrefix(line, "WORKER=") {
			pid, _ := strconv.Atoi(strings.TrimPrefix(line, "WORKER="))
			return pid
		}
	}
	return 0
}

func workerAlive() bool {
	pid := workerPID()
	return pid > 0 && processAlive(pid)
}

func heartbeatFresh() bool {
	info, err := os.Stat(p.hb)
	return err == nil && time.Since(info.ModTime()) < 15*time.Second
}

func stateValue(key string) string {
	prefix := key + "="
	for _, line := range readLines(p.state) {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimSpace(strings.TrimPrefix(line, prefix))
		}
	}
	return ""
}

// ----------------------------------------------------------- credentials

func storedAccount() string {
	for _, line := range readLines(envFile()) {
		if strings.HasPrefix(line, "HKU_USER=") {
			return strings.TrimSpace(strings.TrimPrefix(line, "HKU_USER="))
		}
	}
	return ""
}

func storedPIN() string { return strings.TrimSpace(readText(passFile())) }

func persistCredentials(account, pin string) error {
	account, pin = strings.TrimSpace(account), strings.TrimSpace(pin)
	if account == "" {
		return fmt.Errorf("account is empty")
	}
	_ = os.MkdirAll(vpnDir(), 0o700)

	lines := readLines(envFile())
	out := make([]string, 0, len(lines)+1)
	found := false
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "HKU_USER="):
			out = append(out, "HKU_USER="+account)
			found = true
		case strings.TrimSpace(line) != "":
			out = append(out, line)
		}
	}
	if !found {
		out = append([]string{"HKU_USER=" + account}, out...)
	}
	if err := os.WriteFile(envFile(), []byte(strings.Join(out, "\r\n")+"\r\n"), 0o600); err != nil {
		return err
	}
	if pin != "" {
		return os.WriteFile(passFile(), []byte(pin), 0o600)
	}
	return nil
}

// --------------------------------------------------------------- launcher

func findLauncher() string {
	exe, err := os.Executable()
	if err == nil {
		dir := parentDir(exe)
		for i := 0; i < 6 && dir != ""; i++ {
			candidate := joinPath(joinPath(dir, "bin"), "hkuvpn.ps1")
			if fileExists(candidate) {
				return candidate
			}
			next := parentDir(dir)
			if next == dir {
				break
			}
			dir = next
		}
	}
	candidate := joinPath(homeDir(), joinPath("hkuvpn", joinPath("windows", joinPath("bin", "hkuvpn.ps1"))))
	if fileExists(candidate) {
		return candidate
	}
	return ""
}

func startWorker(script string) (int, error) {
	params := fmt.Sprintf(`-NoProfile -ExecutionPolicy Bypass -File "%s" "--Worker"`, script)
	return shellExecuteRunAs("powershell.exe", params)
}

func stopWorker(script string) {
	params := fmt.Sprintf(`-NoProfile -ExecutionPolicy Bypass -File "%s" "--stop"`, script)
	shellExecuteHidden("powershell.exe", params)
}

// lastCompleteLineEnd returns the offset just past the last '\n' in b, or
// 0 when b holds no complete line (a trailing partial write is excluded).
func lastCompleteLineEnd(b []byte) int64 {
	end := bytes.LastIndexByte(b, '\n')
	if end < 0 {
		return 0
	}
	return int64(end + 1)
}

// newMarkerLines returns the complete marker lines written after offset.
// A trailing partial line (the worker is mid-write) is held back and the
// offset does not advance past it, so a marker is never half-read and then
// skipped.
func newMarkerLines(b []byte, offset int64) ([]string, int64) {
	if int64(len(b)) <= offset {
		return nil, offset
	}
	chunk := b[offset:]
	end := bytes.LastIndexByte(chunk, '\n')
	if end < 0 {
		return nil, offset // no complete line yet
	}
	next := offset + int64(end) + 1
	text := strings.TrimSuffix(string(chunk[:end]), "\r")
	var lines []string
	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	return lines, next
}

// ------------------------------------------------------------------- log

var sixDigits = regexp.MustCompile(`^\d{6}$`)

func (a *app) openLog() {
	a.logOpen = true
	// Load the session's log once. Reopening the window, including after
	// Clear, must not reload lines the user has already dismissed.
	if !a.logLoaded {
		a.logLoaded = true
		a.logLines = nil
		a.logOffset = 0
		a.readWholeLog()
	}
}

func (a *app) readWholeLog() {
	b, err := os.ReadFile(p.log)
	if err != nil {
		return
	}
	// Only complete lines: the tail is held back until it ends with '\n'.
	a.logOffset = lastCompleteLineEnd(b)
	if a.logOffset > 0 {
		a.appendLogBytes(b[:a.logOffset], true)
	}
}

func (a *app) refreshLog() {
	info, err := os.Stat(p.log)
	if err != nil {
		return
	}
	if info.Size() < a.logOffset {
		a.logOffset = 0
		a.logLines = nil
	}
	if info.Size() == a.logOffset {
		return
	}
	f, err := os.Open(p.log)
	if err != nil {
		return
	}
	defer f.Close()
	if _, err := f.Seek(a.logOffset, 0); err != nil {
		return
	}
	buf := make([]byte, 256*1024)
	n, _ := f.Read(buf)
	// Hold back a trailing partial line until it ends with '\n'.
	keep := bytes.LastIndexByte(buf[:n], '\n')
	if keep < 0 {
		return
	}
	a.logOffset += int64(keep + 1)
	a.appendLogBytes(buf[:keep+1], false)
}

// decodeLogLine picks the encoding of one log line: UTF-8 when it is (or
// almost is) valid, the ANSI code page otherwise. The worker writes UTF-8
// from its own code but ANSI for localized tools such as netsh, and a
// truncated multi-byte character can appear at the end of a line.
func decodeLogLine(b []byte) string {
	if utf8.Valid(b) {
		return string(b)
	}
	bad := 0
	for i := 0; i < len(b); {
		r, size := utf8.DecodeRune(b[i:])
		if r == utf8.RuneError && size == 1 {
			bad++
			i++
			continue
		}
		i += size
	}
	if bad*10 <= len(b) {
		return strings.ToValidUTF8(string(b), "?")
	}
	return acpDecode(b)
}

// appendLogBytes decodes the log line by line: the worker mixes UTF-8
// (its own markers and vpnc-script) with the ANSI code page (localized
// netsh output), so a whole-file decode would garble one of them.
func (a *app) appendLogBytes(b []byte, replace bool) {
	if replace {
		a.logLines = nil
	}
	for _, raw := range strings.Split(string(b), "\n") {
		raw = strings.TrimSuffix(raw, "\r")
		if strings.TrimSpace(raw) == "" {
			continue
		}
		line := decodeLogLine([]byte(raw))
		for _, part := range strings.Split(line, "\r") {
			if strings.TrimSpace(part) != "" {
				a.logLines = append(a.logLines, logEntry{text: part, level: classifyLog(part)})
			}
		}
	}
	if n := len(a.logLines); n > 400 {
		a.logLines = a.logLines[n-400:]
	}
}

// classifyLog assigns a severity from the line's own words. The worker's
// log is free text, so this is a heuristic that keeps the important lines
// distinguishable without changing what the worker writes.
func classifyLog(line string) logLevel {
	l := strings.ToLower(line)
	has := func(words ...string) bool {
		for _, word := range words {
			if strings.Contains(l, word) {
				return true
			}
		}
		return false
	}
	// Routine keepalive chatter first: an "error" word in it is rare, and
	// these lines are the ones a reader wants hidden by default.
	if has("keepalive", "cstp dpd", "dtls dpd", "mtu probe", "mtu ") {
		return lvlDebug
	}
	// "timeout:" / "-Timeout" are server settings, and "disconnect done"
	// is a normal teardown line: only failures count as errors.
	if has("failed", "error", "fatal", "cannot ", "could not", "unable to",
		"denied", "rejected", "refused", "no route", "timed out",
		"connection reset", "unexpected eof") {
		return lvlError
	}
	if has("warning", "warn", "retry", "retrying", "stale", "deprecated",
		"falling back", "reconnect", "ignored", "aborted") {
		return lvlWarn
	}
	return lvlInfo
}

func (a *app) clearLog() {
	a.logLines = nil
	if info, err := os.Stat(p.log); err == nil {
		a.logOffset = info.Size()
	}
}
