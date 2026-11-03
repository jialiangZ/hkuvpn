//go:build !windows

package main

// Stubs so the app still builds and its view can be tested off Windows.

func processAlive(pid int) bool { return false }

func shellExecuteRunAs(exe, params string) (int, error) { return 0, nil }

func shellExecuteHidden(exe, params string) {}

func acpDecode(b []byte) string { return string(b) }
