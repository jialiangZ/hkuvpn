package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// logEntry is one line of the session log with its severity.
type logEntry struct {
	text  string
	level logLevel
}

type logLevel int

const (
	lvlDebug logLevel = iota
	lvlInfo
	lvlWarn
	lvlError
)

type session int

const (
	idle session = iota
	connecting
	connected
)

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
	markersOffset int64
	retry         bool
	subOverride   string
	connectedAt   time.Time
	disconnecting bool
	disconnectAt  time.Time
	cancelling    bool
	cancelAt      time.Time
	connectAt     time.Time
	mfaShown      bool
	reconnectAt   time.Time
	reconnectTry  int

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
	mfaOpen    bool
	mfaPending bool
	mfaCode    string
	mfaNote    string

	logOpen        bool
	logLines       []logEntry
	logOffset      int64
	logLoaded      bool
	logFilter      int
	logList        ui.ListState
	copiedAt       time.Time
	lastLogRefresh time.Time

	// Credential autosave.
	credDirty  bool
	credEditAt time.Time

	// A message waiting to be shown over the window.
	pendingToast    string
	pendingToastErr bool

	// Settings and preferences.
	settings     settings
	settingsForm settingsForm
	prefs        appState

	// Panels.
	routesNote   panelNote
	settingsNote panelNote
	logNote      panelNote
	routesOpen   bool
	routeList    []learnedRoute
	routeInput   string
	diagOpen     bool
	diagRunning  bool
	diagResults  []checkResult
	settingsOpen bool
	logSearch    string

	uiTheme   *ui.Theme
	trayState string
	statusLog string
}

// maxReconnectTries bounds the automatic reconnects after a session drops,
// so a gateway that keeps refusing does not ask for UAC over and over.
const maxReconnectTries = 3

func newApp() *app {
	a := &app{
		account: storedAccount(),
		pin:     storedPIN(),
	}
	a.prefs = loadAppState()
	a.settings = loadSettings()
	a.settingsForm = newSettingsForm(a.settings, a.prefs)
	// The log follows its newest line until the user scrolls away.
	a.logList.FollowEnd = true
	// Default to hiding the keepalive noise but keeping info lines.
	a.logFilter = 1
	// Adopt a session that survived a frontend restart, with the start
	// time the last run remembered, so the timer does not start at zero.
	if workerAlive() && heartbeatFresh() {
		a.state = connected
		a.connectedAt = a.prefs.SessionStart
		if a.connectedAt.IsZero() {
			a.connectedAt = time.Now()
		}
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
		a.mfaPending = false
		a.disconnecting = false
		a.cancelling = false
	case connecting:
		a.connectedAt = time.Time{}
		a.subOverride = ""
	case connected:
		a.mfaPending = false
		if a.connectedAt.IsZero() {
			a.connectedAt = time.Now()
		}
	}
}

func (a *app) connect() {
	account := strings.TrimSpace(a.account)
	if account == "" {
		a.say("Enter your HKU account first.", true)
		return
	}
	if err := persistCredentials(account, a.pin); err != nil {
		go mygo.Dialog.Error("HKU VPN", "Could not save the credentials: "+err.Error())
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
		a.say("Cleaning up a stale session - try again in a moment.", true)
		return
	}
	script := findLauncher()
	if script == "" {
		go mygo.Dialog.Error("HKU VPN",
			"hkuvpn.ps1 was not found. Place HKUVPN.exe inside the hkuvpn repo "+
				`(windows\mygo-app\publish) or clone the repo to %USERPROFILE%\hkuvpn.`)
		return
	}
	code, err := startWorker(script)
	if err != nil {
		if code == 5 { // SE_ERR_ACCESSDENIED
			a.say("Elevation was declined.", true)
		} else {
			go mygo.Dialog.Error("HKU VPN", fmt.Sprintf("Could not start the worker (ShellExecute=%d).", code))
		}
		return
	}
	// The worker deletes markers.log when it starts, so the cursor begins
	// at zero for the new session.
	// Skip the previous session's markers (the file still exists at this
	// point; the worker deletes and rewrites it as it starts). Advance past
	// complete lines only, so nothing half-written is ever counted.
	if b, err := os.ReadFile(p.markers); err == nil {
		a.markersOffset = lastCompleteLineEnd(b)
	} else {
		a.markersOffset = 0
	}
	a.retry = false
	// A new session starts its timer over.
	a.prefs.SessionStart = time.Time{}
	_ = saveAppState(a.prefs)
	// The worker starts a fresh log for every session: read it from the top
	// the next time the log window opens.
	a.logLoaded = false
	a.connectAt = time.Now()
	a.setState(connecting)
}

func (a *app) cancel() {
	if script := findLauncher(); script != "" {
		stopWorker(script)
	}
	_ = writeText(p.stop, "stop")
	a.mfaOpen = false
	// Do not jump to idle: a Cancel in the first seconds races with the
	// worker's own startup, which erases stop.flag. Watch the worker and
	// keep re-asserting the flag until it is really gone.
	a.cancelling = true
	a.cancelAt = time.Now()
	a.subOverride = "Cancelling - waiting for the worker to exit..."
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
	a.mfaPending = false
	a.mfaNote = ""
	a.mfaCode = ""
	a.subOverride = "MFA code accepted - establishing tunnel (this can take ~30s)..."
}

func (a *app) credentialsEdited() {
	a.credDirty = true
	a.credEditAt = time.Now()
}

// say queues a message for the window, which shows it as a toast over the
// app.
func (a *app) say(text string, isErr bool) {
	a.pendingToast = text
	a.pendingToastErr = isErr
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
		// The session died on its own. Remember when it was, and offer to
		// bring it back when the user asked for that.
		a.setState(idle)
		a.prefs.SessionStart = time.Time{}
		_ = saveAppState(a.prefs)
		if a.prefs.AutoReconnect && a.reconnectTry < maxReconnectTries {
			a.reconnectTry++
			a.reconnectAt = now.Add(3 * time.Second)
		}
	}
	// Reconciliation: a rewritten markers file can leave the cursor past
	// the CONNECTED line, so trust the file while the worker is alive.
	if a.state == connecting && alive && markerContains("HKUVPN_CONNECTED") {
		if b, err := os.ReadFile(p.markers); err == nil {
			a.markersOffset = lastCompleteLineEnd(b)
		}
		a.mfaOpen = false
		a.markedConnected(now)
		a.setState(connected)
	}
	// A cancel in progress: keep asking the worker to stop (its start-up
	// cleanup erases an early flag) and wait until it is really gone.
	switch cancelOutcome(a.cancelling, alive, now.Sub(a.cancelAt)) {
	case cancelIdle:
		a.cancelling = false
		a.setState(idle)
	case cancelTimedOut:
		a.cancelling = false
		a.setState(connecting)
		a.subOverride = "Cancel timed out - the worker is still running."
	}
	// The worker stopped before the tunnel came up. The marker is the
	// normal way to hear it; the clock covers a worker that died without
	// writing one (the grace period covers its slow start).
	if a.state == connecting && !alive && !a.cancelling {
		if markerContains("HKUVPN_EXITED") || now.Sub(a.connectAt) > 20*time.Second {
			a.setState(idle)
			a.say("The worker stopped before the tunnel came up - see the log.", true)
		}
	}
	// A dropped session comes back on its own when the user asked for that.
	if !a.reconnectAt.IsZero() && now.After(a.reconnectAt) {
		a.reconnectAt = time.Time{}
		if !workerAlive() {
			a.connect()
		}
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

	// A code is needed: bring the window forward, whoever hid it.
	if a.mfaOpen && !a.mfaShown {
		a.mfaShown = true
		a.showWindow()
	}
	if !a.mfaOpen {
		a.mfaShown = false
	}

	a.refreshStatus(now, alive, fresh)

	if a.credDirty && now.Sub(a.credEditAt) > 700*time.Millisecond {
		a.credDirty = false
		if strings.TrimSpace(a.account) != "" {
			// The credentials are saved without a word: the fields show
			// what was saved, and a toast after every edit would be noise.
			_ = persistCredentials(a.account, a.pin)
		}
	}
	if a.logOpen && now.Sub(a.lastLogRefresh) > 800*time.Millisecond {
		a.lastLogRefresh = now
		a.refreshLog()
	}
	if !a.copiedAt.IsZero() && now.Sub(a.copiedAt) > 1500*time.Millisecond {
		a.copiedAt = time.Time{}
	}
	a.syncTray(alive, fresh)
	a.writeStatus(alive, fresh)
}

// writeStatus records what the app is doing in %TEMP%\hkuvpn\app-status.txt,
// so a script (or a person at the console) can see the state of the app
// without its window. It is written when something changes.
func (a *app) writeStatus(alive, fresh bool) {
	state := "idle"
	switch a.state {
	case connecting:
		state = "connecting"
	case connected:
		state = "connected"
	}
	status := fmt.Sprintf("updated=%s\nstate=%s\nworker=%t\nheartbeat=%t\ncancelling=%t\ndisconnecting=%t\nmfa=%t\nmfaOpen=%t\naddress=%s\n",
		time.Now().Format(time.RFC3339), state, alive, fresh,
		a.cancelling, a.disconnecting, a.mfaPending, a.mfaOpen, stateValue("IP4"))
	if status == a.statusLog {
		return
	}
	a.statusLog = status
	_ = writeText(joinPath(p.base, "app-status.txt"), status)
}

func (a *app) processMarkers() {
	b, err := os.ReadFile(p.markers)
	if err != nil {
		return
	}
	// A file shorter than the cursor means the worker started a new session
	// (markers.log is deleted and rewritten): restart the cursor at zero.
	if int64(len(b)) < a.markersOffset {
		a.markersOffset = 0
	}
	lines, next := newMarkerLines(b, a.markersOffset)
	if next == a.markersOffset {
		return
	}
	a.markersOffset = next
	for _, line := range lines {
		a.applyMarker(line)
	}
}

// applyMarker reads one marker line and moves the session on.
func (a *app) applyMarker(line string) {
	switch {
	case strings.Contains(line, "HKUVPN_CONNECTED"):
		a.mfaOpen = false
		a.markedConnected(time.Now())
		a.setState(connected)
	case strings.Contains(line, "HKUVPN_MFA_RESPONSE_REQUIRED") && a.state == connecting:
		a.mfaOpen = true
		a.mfaPending = true
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

// What a cancel in progress leads to.
const (
	cancelNone = iota
	cancelIdle
	cancelTimedOut
)

// cancelOutcome says what the app does while a cancel is in progress:
// idle once the worker is really gone, a timeout when it did not stop in
// time. It is a plain function, so the state machine can be tested.
func cancelOutcome(cancelling, alive bool, elapsed time.Duration) int {
	if !cancelling {
		return cancelNone
	}
	if !alive {
		return cancelIdle
	}
	if elapsed > 30*time.Second {
		return cancelTimedOut
	}
	return cancelNone
}

// markedConnected remembers when the session started, so the timer keeps
// running when the app is restarted.
func (a *app) markedConnected(now time.Time) {
	a.connectedAt = now
	a.prefs.SessionStart = now
	a.reconnectTry = 0
	_ = saveAppState(a.prefs)
}

// showWindow brings the app window forward.
func (a *app) showWindow() {
	if win == nil {
		return
	}
	if !win.IsVisible() {
		win.Show()
	}
	win.Focus()
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
		if !a.reconnectAt.IsZero() {
			a.statusText = "Reconnecting"
			a.statusColor = colorAmber
			secs := int(time.Until(a.reconnectAt).Seconds()) + 1
			if secs < 1 {
				secs = 1
			}
			a.headline = fmt.Sprintf("Reconnecting in %d s", secs)
		}
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
		routes := len(readLearnedRoutes())
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
	if a.cancelling {
		a.statusText = "Cancelling"
		a.statusColor = colorAmber
	}
	if a.disconnecting {
		a.statusText = "Disconnecting"
		a.statusColor = colorAmber
	}
}

// visibleLog applies the level filter and the search text chosen in the
// dialog.
func (a *app) visibleLog() []logEntry {
	needle := strings.ToLower(strings.TrimSpace(a.logSearch))
	out := make([]logEntry, 0, len(a.logLines))
	for _, entry := range a.logLines {
		if a.logFilter > 0 && int(entry.level) < a.logFilter {
			continue
		}
		if needle != "" && !strings.Contains(strings.ToLower(entry.text), needle) {
			continue
		}
		out = append(out, entry)
	}
	return out
}

// copyLog puts the lines currently shown on the clipboard.
func (a *app) copyLog() {
	entries := a.visibleLog()
	if len(entries) == 0 {
		return
	}
	var b strings.Builder
	for i, entry := range entries {
		if i > 0 {
			b.WriteString("\r\n")
		}
		b.WriteString(entry.text)
	}
	mygo.Clipboard.WriteText(b.String())
	a.copiedAt = time.Now()
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

// panelNote is a message a panel shows under its buttons: a toast would
// hide behind the modal it belongs to.
type panelNote struct {
	text  string
	isErr bool
}

// ---------------------------------------------------------------- panels

// openRoutes loads the learned routes and shows the panel.
func (a *app) openRoutes() {
	a.routeList = readLearnedRoutes()
	a.routesOpen = true
}

// addRoute adds a prefix to the learned routes.
func (a *app) addRoute() {
	cidr := strings.TrimSpace(a.routeInput)
	if cidr == "" {
		return
	}
	if err := addLearnedRoute(cidr, "added by hand"); err != nil {
		a.routesNote = panelNote{text: err.Error(), isErr: true}
		return
	}
	a.routeInput = ""
	a.routeList = readLearnedRoutes()
	a.routesNote = panelNote{text: "Added - it is installed on the next connect."}
}

// removeRoute drops one learned route.
func (a *app) removeRoute(base string) {
	if err := deleteLearnedRoute(base); err != nil {
		a.routesNote = panelNote{text: "Could not remove the route: " + err.Error(), isErr: true}
		return
	}
	a.routeList = readLearnedRoutes()
	a.routesNote = panelNote{text: "Removed - it goes away on the next connect."}
}

// clearRoutes drops every learned route.
func (a *app) clearRoutes() {
	if err := writeLearnedRoutes(nil); err != nil {
		a.routesNote = panelNote{text: "Could not clear the routes: " + err.Error(), isErr: true}
		return
	}
	a.routeList = readLearnedRoutes()
	a.routesNote = panelNote{text: "All learned routes removed."}
}

// openDiagnostics shows the panel and runs the checks.
func (a *app) openDiagnostics() {
	a.diagOpen = true
	a.runDiagnostics()
}

// runDiagnostics checks the setup and the local proxies. The checks talk to
// the network, so they run off the main thread.
func (a *app) runDiagnostics() {
	a.diagRunning = true
	s := a.settings
	go func() {
		results := append(runPreflight(s), runProxyTest(s)...)
		if win == nil || win.IsDestroyed() {
			return
		}
		win.Update(func() {
			a.diagResults = results
			a.diagRunning = false
		})
	}()
}

// openSettings shows the settings panel with the current values.
func (a *app) openSettings() {
	a.settingsForm = newSettingsForm(a.settings, a.prefs)
	a.settingsOpen = true
}

// saveSettings writes the advanced options and the preferences. It says
// whether the panel may close.
func (a *app) saveSettings() bool {
	s, prefs := a.settingsForm.apply()
	if err := saveSettings(s); err != nil {
		a.settingsNote = panelNote{text: "Could not save the settings: " + err.Error(), isErr: true}
		return false
	}
	if prefs.AutoStart != a.prefs.AutoStart {
		if err := setAutostart(prefs.AutoStart); err != nil {
			a.settingsNote = panelNote{text: "Could not update the autostart entry: " + err.Error(), isErr: true}
			return false
		}
	}
	a.settings = s
	a.prefs = prefs
	_ = saveAppState(a.prefs)
	a.settingsOpen = false
	a.settingsNote = panelNote{}
	return true
}

// exportLog writes the lines on screen to a file the user picks.
func (a *app) exportLog() {
	entries := a.visibleLog()
	if len(entries) == 0 {
		return
	}
	path, err := mygo.Dialog.Save(mygo.SaveDialogOptions{
		Title: "Export the connection log",
	})
	if err != nil || path == "" {
		return
	}
	var b strings.Builder
	for i, entry := range entries {
		if i > 0 {
			b.WriteString("\r\n")
		}
		b.WriteString(entry.text)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		a.logNote = panelNote{text: "Could not write the file: " + err.Error(), isErr: true}
		return
	}
	a.logNote = panelNote{text: "Exported to " + path}
}

// jumpToLatest scrolls the log back to its newest line.
func (a *app) jumpToLatest() {
	a.logList.FollowEnd = true
	a.logList.ScrollToEnd()
}
