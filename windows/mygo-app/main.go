package main

import (
	"embed"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

//go:embed assets/*.png
var assets embed.FS

var (
	win      *mygo.Window
	tray     *mygo.Tray
	quitting bool
)

func main() {
	a := newApp()

	mygo.App.WhenReady(func() {
		win = mygo.NewWindow(mygo.WindowOptions{
			Title: "HKU VPN",
			// The window has one size: the app has little to show, and
			// a window that cannot grow has no empty space in it. The
			// size is the page area, the title bar is drawn in it.
			Width:          452,
			Height:         376,
			UseContentSize: true,
			// No resizing, and no maximizing: the window is the size
			// it needs. The caption is the system's own; Windows 11
			// keeps drawing the maximize button, greyed out.
			DisableResize:   true,
			DisableMaximize: true,
			Content:         ui.View(a.view),
		})
		// The HKU crest is the app icon: title bar, taskbar and Alt+Tab
		// all show assets/app-icon.png. The tray carries the same crest
		// with a state-coloured badge.
		if icon, err := assets.ReadFile("assets/app-icon.png"); err == nil {
			_ = win.SetIcon(icon)
		} else {
			logf("app icon: %v", err)
		}

		win.OnClose(func(e *mygo.CloseEvent) {
			// Closing the window keeps the tunnel alive in the tray.
			if !quitting {
				e.PreventDefault()
				win.Hide()
			}
		})

		setupTray(a)
		go a.poll()

		// The user asked for the app to connect when it starts: do it now,
		// unless a session is already running.
		if a.prefs.ConnectOnStart && !workerAlive() {
			a.connect()
		}
	})

	mygo.App.OnBeforeQuit(func(*mygo.QuitEvent) { quitting = true })
	if err := mygo.App.Run(); err != nil {
		fatal("HKU VPN", "The app could not start: "+err.Error())
	}
}

func setupTray(a *app) {
	menu := mygo.NewMenu([]*mygo.MenuItem{
		{Label: "Open HKU VPN", Click: func(*mygo.MenuItem, *mygo.Window) { win.Show() }},
		mygo.Separator(),
		{Label: "Exit", Click: func(*mygo.MenuItem, *mygo.Window) { mygo.App.Quit() }},
	})
	icon, err := assets.ReadFile(a.trayIconName())
	if err != nil {
		logf("tray icon: %v", err)
		return
	}
	t, err := mygo.NewTray(mygo.TrayOptions{
		ID:      "hkuvpn",
		Icon:    icon,
		ToolTip: "HKU VPN: disconnected",
		Menu:    menu,
	})
	if err != nil {
		logf("tray: %v", err)
		return
	}
	tray = t
}

// poll feeds the worker protocol into the view twice a second.
func (a *app) poll() {
	ticker := time.NewTicker(500 * time.Millisecond)
	for range ticker.C {
		now := time.Now()
		win.Update(func() { a.tick(now) })
		a.refreshPanels()
	}
}
