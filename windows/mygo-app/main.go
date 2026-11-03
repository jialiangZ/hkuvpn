package main

import (
	"bytes"
	"embed"
	"image"
	"image/png"
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
			Title:     "HKU VPN",
			Width:     480,
			Height:    600,
			MinWidth:  440,
			MinHeight: 540,
			Content:   ui.View(a.view),
		})
		// The app carries no icon: a fully transparent image keeps the title
		// bar and the taskbar button blank.
		_ = win.SetIcon(blankPNG())

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

func blankPNG() []byte {
	img := image.NewRGBA(image.Rect(0, 0, 16, 16))
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
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
		win.Update(func() { a.tick(time.Now()) })
	}
}
