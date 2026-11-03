package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// logf appends a line to the app's own log file. The executable is a GUI
// app (windowsgui subsystem), so there is no console to print to.
func logf(format string, args ...any) {
	path := joinPath(p.base, "app.log")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"),
		fmt.Sprintf(format, args...))
}

// fatal reports a startup failure: the log file keeps the detail and a
// native message box tells the user, since there is no console window.
func fatal(title, msg string) {
	logf("%s: %s", title, msg)
	showMessageBox(title, msg)
	os.Exit(1)
}
