package main

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

// The view runs without a window, which is how MyGo tests native UI.
func TestViewShowsTheDisconnectedState(t *testing.T) {
	a := newApp()
	tt := ui.NewTester(a.view, 480, 600)

	for _, want := range []string{"HKU VPN", "Disconnected", "Not connected", "Connect", "View log"} {
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
