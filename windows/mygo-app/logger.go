package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// The app's own diagnostics: where they live, how long they are kept and
// how they are rolled.
//
// They go to %LOCALAPPDATA%\HKUVPN, not to %TEMP%: a log that is meant
// to be read after a failure has to survive the cleanup Windows does for
// the temporary directory (and the cleanup it does when the disk runs
// low). The settings live in %USERPROFILE%\.vpn, the same way.
const (
	appLogName        = "app.log"
	appLogDirName     = "HKUVPN"
	appLogMaxBytes    = 1 << 20 // a megabyte a day is plenty for this app
	appLogGenerations = 7       // a week
)

// appLogPath is where the app's own log lives.
func appLogPath() string {
	dir := os.Getenv("LOCALAPPDATA")
	if dir == "" {
		// No per-user data directory: fall back to the temporary one.
		return joinPath(p.base, appLogName)
	}
	return filepath.Join(dir, appLogDirName, appLogName)
}

// logf appends a line to the app's own log file.
func logf(format string, args ...any) {
	path := appLogPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	rotateAppLog(path)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339),
		fmt.Sprintf(format, args...))
}

// rotateAppLog rolls the app's log: a new file when the day changes or
// the file grows past its bound, and a week of generations are kept.
func rotateAppLog(path string) {
	info, err := os.Stat(path)
	if err != nil {
		return // no log yet
	}
	sameDay := info.ModTime().Format("2006-01-02") == time.Now().Format("2006-01-02")
	if sameDay && info.Size() < appLogMaxBytes {
		return
	}
	// A generation too many, from an older scheme, goes away.
	_ = os.Remove(path + "." + strconv.Itoa(appLogGenerations+1))
	// Shift the generations: .6 becomes .7, .1 becomes .2, and the
	// current file becomes .1.
	for i := appLogGenerations; i >= 2; i-- {
		_ = os.Remove(path + "." + strconv.Itoa(i))
		_ = os.Rename(path+"."+strconv.Itoa(i-1), path+"."+strconv.Itoa(i))
	}
	_ = os.Rename(path, path+".1")
}

// fatal reports a startup failure: the log file keeps the detail and a
// native message box tells the user, since there is no console window.
func fatal(title, msg string) {
	logf("%s: %s", title, msg)
	showMessageBox(title, msg)
	os.Exit(1)
}
