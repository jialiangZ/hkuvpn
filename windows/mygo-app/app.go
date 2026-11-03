package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

type session int

const (
	idle session = iota
	connecting
	connected
)

const defaultHint = "Closing this window keeps the VPN running in the tray."

var (
	colorGray  = ui.Hex("#8A9199")
	colorGreen = ui.Hex("#12873E")
	colorAmber = ui.Hex("#C47F17")
	colorRed   = ui.Hex("#D92D20")
)

// app is the state the view is built from. All fields are read and written
// on the main thread, inside Window.Update or the view itself.
type app struct {
	// Credentials, edited in the account fields.
	account string
	pin     string

	// Session.
	state         session
	seen          int
	retry         bool
	subOverride   string
	connectedAt   time.Time
	disconnecting bool
	disconnectAt  time.Time

	// Derived display values.
	statusText    string
	statusColor   ui.Color
	headline      string
	headlineMuted bool
	duration      string
	routes        string
	workerOK      bool
	hbOK          bool

	// Dialogs.
	mfaOpen bool
	mfaCode string
	mfaNote string

	logOpen        bool
	logLines       []string
	logOffset      int64
	logLoaded      bool
	logList        ui.ListState
	lastLogRefresh time.Time

	// Hints and credential autosave.
	hint       string
	hintUntil  time.Time
	credDirty  bool
	credEditAt time.Time

	uiTheme   *ui.Theme
	trayState string
}

func newApp() *app {
	a := &app{
		account: storedAccount(),
		pin:     storedPIN(),
		hint:    defaultHint,
	}
	// The log follows its newest line until the user scrolls away.
	a.logList.FollowEnd = true
	// Adopt a session that survived a frontend restart.
	if workerAlive() && heartbeatFresh() {
		a.state = connected
		a.connectedAt = time.Now()
	}
	a.refreshStatus(time.Now(), workerAlive(), heartbeatFresh())
	return a
}

// ------------------------------------------------------------- state flow

func (a *app) setState(s session) {
	a.state = s
	switch s {
	case idle:
		a.connectedAt = time.Time{}
		a.subOverride = ""
		a.mfaOpen = false
		a.disconnecting = false
	case connecting:
		a.connectedAt = time.Time{}
		a.subOverride = ""
	case connected:
		if a.connectedAt.IsZero() {
			a.connectedAt = time.Now()
		}
	}
}

func (a *app) connect() {
	account := strings.TrimSpace(a.account)
	if account == "" {
		a.showHint("Enter your HKU account first.")
		return
	}
	if err := persistCredentials(account, a.pin); err != nil {
		mygo.Dialog.Error("HKU VPN", "Could not save the credentials: "+err.Error())
		return
	}
	if workerAlive() {
		if heartbeatFresh() {
			a.setState(connected)
			return
		}
		// A wedged leftover would make the UI claim a session that is not
		// usable: ask the worker to clean up instead.
		if script := findLauncher(); script != "" {
			stopWorker(script)
		}
		a.showHint("Cleaning up a stale session - try again in a moment.")
		return
	}
	script := findLauncher()
	if script == "" {
		mygo.Dialog.Error("HKU VPN",
			"hkuvpn.ps1 was not found. Place HKUVPN.exe inside the hkuvpn repo "+
				`(windows\app\publish) or clone the repo to %USERPROFILE%\hkuvpn.`)
		return
	}
	code, err := startWorker(script)
	if err != nil {
		if code == 5 { // SE_ERR_ACCESSDENIED
			a.showHint("Elevation was declined.")
		} else {
			mygo.Dialog.Error("HKU VPN", fmt.Sprintf("Could not start the worker (ShellExecute=%d).", code))
		}
		return
	}
	a.seen = len(readLines(p.markers))
	a.retry = false
	// The worker starts a fresh log for every session: read it from the top
	// the next time the log window opens.
	a.logLoaded = false
	a.setState(connecting)
}

func (a *app) cancel() {
	_ = writeText(p.stop, "stop")
	a.setState(idle)
}

func (a *app) disconnect() {
	if a.state != connected || a.disconnecting {
		return
	}
	a.disconnecting = true
	a.disconnectAt = time.Now()
	a.subOverride = ""
	script := findLauncher()
	if script != "" {
		stopWorker(script)
	}
}

func (a *app) submitMFA() {
	code := strings.TrimSpace(a.mfaCode)
	if !sixDigits.MatchString(code) {
		a.mfaNote = "The code must be exactly 6 digits."
		return
	}
	if err := writeText(p.response, code); err != nil {
		a.mfaNote = "Could not deliver the code."
		return
	}
	a.mfaOpen = false
	a.mfaNote = ""
	a.mfaCode = ""
	a.subOverride = "MFA code accepted - establishing tunnel (this can take ~30s)..."
}

func (a *app) credentialsEdited() {
	a.credDirty = true
	a.credEditAt = time.Now()
}

func (a *app) showHint(text string) {
	a.hint = text
	a.hintUntil = time.Now().Add(2500 * time.Millisecond)
}

// ------------------------------------------------------------------ tick

func (a *app) tick(now time.Time) {
	a.processMarkers()

	alive := workerAlive()
	fresh := heartbeatFresh()

	if a.state == connecting && !alive && markerContains("HKUVPN_EXITED") {
		a.setState(idle)
	}
	if a.state == connected && !alive {
		a.setState(idle)
	}
	// Reconciliation: a rewritten markers file can leave the cursor past
	// the CONNECTED line, so trust the file while the worker is alive.
	if a.state == connecting && alive && markerContains("HKUVPN_CONNECTED") {
		a.seen = len(readLines(p.markers))
		a.connectedAt = now
		a.mfaOpen = false
		a.setState(connected)
	}
	if a.disconnecting {
		if !alive {
			a.disconnecting = false
			a.setState(idle)
		} else if now.Sub(a.disconnectAt) > 30*time.Second {
			a.disconnecting = false
			a.setState(connected)
			a.subOverride = "Disconnect timed out - the worker is still running; retry."
		}
	}

	a.refreshStatus(now, alive, fresh)

	if a.credDirty && now.Sub(a.credEditAt) > 700*time.Millisecond {
		a.credDirty = false
		if strings.TrimSpace(a.account) != "" {
			if err := persistCredentials(a.account, a.pin); err == nil {
				a.showHint("Account details saved.")
			}
		}
	}
	if !a.hintUntil.IsZero() && now.After(a.hintUntil) {
		a.hint = defaultHint
		a.hintUntil = time.Time{}
	}
	if a.logOpen && now.Sub(a.lastLogRefresh) > 800*time.Millisecond {
		a.lastLogRefresh = now
		a.refreshLog()
	}
	a.syncTray(alive, fresh)
}

func (a *app) processMarkers() {
	lines := readLines(p.markers)
	if len(lines) <= a.seen {
		return
	}
	for _, line := range lines[a.seen:] {
		switch {
		case strings.Contains(line, "HKUVPN_CONNECTED"):
			a.mfaOpen = false
			a.connectedAt = time.Now()
			a.setState(connected)
		case strings.Contains(line, "HKUVPN_MFA_RESPONSE_REQUIRED") && a.state == connecting:
			a.mfaOpen = true
			a.mfaCode = ""
			if a.retry {
				a.mfaNote = "Previous code rejected - enter the current one."
			} else {
				a.mfaNote = ""
			}
			a.retry = false
		case strings.Contains(line, "HKUVPN_MFA_RETRY"):
			a.retry = true
		case strings.Contains(line, "HKUVPN_EXITED"):
			if a.state == connecting {
				a.mfaOpen = false
				a.setState(idle)
			}
		}
	}
	a.seen = len(lines)
}

func markerContains(marker string) bool {
	for _, line := range readLines(p.markers) {
		if strings.Contains(line, marker) {
			return true
		}
	}
	return false
}

func (a *app) refreshStatus(now time.Time, alive, fresh bool) {
	a.workerOK, a.hbOK = alive, fresh
	a.duration = "--:--:--"
	switch a.state {
	case idle:
		a.statusText = "Disconnected"
		a.statusColor = colorGray
		a.headline = "Not connected"
		a.headlineMuted = true
		a.routes = "-"
	case connecting:
		a.statusText = "Connecting"
		a.statusColor = colorAmber
		a.headline = "Waiting for sign-in"
		if a.subOverride != "" {
			a.headline = a.subOverride
		}
		a.headlineMuted = true
		a.routes = "-"
	case connected:
		if alive && fresh {
			a.statusText = "Connected"
			a.statusColor = colorGreen
		} else {
			a.statusText = "Worker unresponsive"
			a.statusColor = colorRed
		}
		if ip := stateValue("IP4"); ip != "" {
			a.headline = ip
		} else {
			a.headline = "Connected"
		}
		a.headlineMuted = false
		if !a.connectedAt.IsZero() {
			el := int(now.Sub(a.connectedAt).Seconds())
			if el < 0 {
				el = 0
			}
			a.duration = fmt.Sprintf("%02d:%02d:%02d", el/3600, el/60%60, el%60)
		}
		routes := learnedRoutes()
		plural := "s"
		if routes == 1 {
			plural = ""
		}
		hb := "OK"
		if !fresh {
			hb = "stale"
		}
		a.routes = fmt.Sprintf("%d learned route%s · heartbeat %s", routes, plural, hb)
	}
	if a.disconnecting {
		a.statusText = "Disconnecting"
		a.statusColor = colorAmber
	}
}

func (a *app) trayIconName() string {
	switch {
	case a.disconnecting, a.state == connecting:
		return "assets/tray-amber.png"
	case a.state == connected:
		if a.workerOK && a.hbOK {
			return "assets/tray-green.png"
		}
		return "assets/tray-red.png"
	default:
		return "assets/tray-gray.png"
	}
}

func (a *app) trayToolTip() string {
	switch {
	case a.disconnecting:
		return "HKU VPN: disconnecting"
	case a.state == connecting:
		return "HKU VPN: connecting"
	case a.state == connected:
		if a.workerOK && a.hbOK {
			return "HKU VPN: connected"
		}
		return "HKU VPN: worker unresponsive"
	default:
		return "HKU VPN: disconnected"
	}
}

func (a *app) syncTray(alive, fresh bool) {
	if tray == nil {
		return
	}
	name := a.trayIconName()
	if name != a.trayState {
		a.trayState = name
		if icon, err := assets.ReadFile(name); err == nil {
			_ = tray.SetIcon(icon, false)
		}
		tray.SetToolTip(a.trayToolTip())
	}
}
