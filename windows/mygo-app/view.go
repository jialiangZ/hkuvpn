package main

import (
	"fmt"

	"github.com/egoist/mygo/ui"
)

// theme copies the official light/dark theme and only swaps the accent for
// HKU green, so every control keeps the stock MyGo metrics and colors.
func (a *app) theme(c *ui.Context) *ui.Theme {
	// Re-copy when the system appearance flips, so dark mode is followed
	// instead of freezing the first frame's theme forever.
	if a.uiTheme == nil || a.uiTheme.Dark != c.Theme().Dark {
		t := *c.Theme()
		t.Accent = ui.Hex("#0B6B45")
		t.AccentHover = ui.Hex("#0A5C3C")
		t.AccentPressed = ui.Hex("#084B31")
		t.AccentText = ui.Hex("#FFFFFF")
		a.uiTheme = &t
	}
	return a.uiTheme
}

func (a *app) view(c *ui.Context) {
	t := a.theme(c)

	// Escape gives up an attempt that is being built. In the MFA dialog
	// it closes the dialog instead (the dialog takes the key first), so
	// the session only ends when the user asks twice.
	if a.state == connecting && !a.mfaOpen && c.Shortcut(0, ui.KeyEscape) {
		a.cancel()
	}
	// Ctrl+Enter is the main action: connect, cancel, disconnect.
	if c.Shortcut(ui.Ctrl, ui.KeyEnter) {
		switch {
		case a.state == connecting:
			a.cancel()
		case a.state == connected:
			a.disconnect()
		default:
			a.connect()
		}
	}

	// A message the app queued is shown once, over the window.
	if a.pendingToast != "" {
		text := a.pendingToast
		a.pendingToast = ""
		toast(c, text, a.pendingToastErr)
	}

	ui.Themed(c, t).Fill().Children(func() {
		ui.Scroll(c).Fill().Children(func() {
			ui.Column(c).Padding(t.Space(4)).Gap(t.Space(3)).Children(func() {

				// The state of the session, in one card: what it is, how
				// long it has been up, the address of the tunnel and the
				// local proxies.
				ui.Column(c).Padding(t.Space(3)).Gap(t.Space(2)).Radius(10).
					Background(t.Surface).Border(1, t.Border).Children(func() {
					ui.Row(c).AlignItems(ui.Center).Gap(t.Space(2)).Children(func() {
						ui.Box(c).Size(10, 10).Radius(5).Background(a.statusColor)
						ui.Text(c, a.statusText).Bold()
						if a.statusNote != "" {
							ui.Text(c, a.statusNote).TextColor(t.TextMuted)
						}
						ui.Spacer(c)
						ui.Text(c, a.duration).Font("monospace").TextColor(t.TextMuted)
					})
					// The tunnel address is the adapter address, not the
					// public IP: label it so it reads at a glance.
					detailRow(c, t, "VPN address", a.address)
					detailRow(c, t, "Proxy", fmt.Sprintf("socks5://127.0.0.1:%d · http://127.0.0.1:%d",
						a.settings.SocksPort, a.settings.HttpPort))
					detailRow(c, t, "Routes", a.routes)
				})

				// The credentials, in a form: the labels sit beside the
				// fields, so the window keeps its room for what matters.
				ui.Form(c, func() {
					ui.Field(c, "HKU account", func() {
						ui.TextInput(c, &a.account).
							Placeholder("u1234567@connect.hku.hk").
							OnChange(a.credentialsEdited)
					})
					ui.Field(c, "Portal PIN", func() {
						ui.TextInput(c, &a.pin).
							Password().
							Placeholder("Portal password").
							OnChange(a.credentialsEdited)
					})
				})

				// The main action.
				a.primaryAction(c, t)

				// The panels, as a row of icons: each one names itself in
				// a tip when the pointer rests on it.
				ui.Row(c).Gap(t.Space(2)).Children(func() {
					ui.Spacer(c)
					iconButton(c, iconLog, "View log", a.openLog)
					iconButton(c, iconDiagnostics, "Diagnostics", a.openDiagnostics)
					iconButton(c, iconRoutes, "Routes", a.openRoutes)
					iconButton(c, iconSettings, "Settings", a.openSettings)
				})
			})
		})

		a.mfaDialog(c, t)
	})
}

// iconButton is a button that shows only an icon. The tip names it, and
// so does the label, for the screen readers that do not see the icon.
func iconButton(c *ui.Context, icon *ui.SVG, label string, action func()) {
	// The button's own padding (14 DIPs sideways) leaves a content box
	// narrower than the icon, and the icon then hangs to the right of
	// the center. A smaller, even padding keeps it centered.
	ui.Button(c, "").Label(label).Tooltip(label).
		Width(40).Height(36).
		Padding(4, 6).
		Children(func() {
			ui.Icon(c, icon).FontSize(19)
		}).
		OnClick(action)
}

func detailRow(c *ui.Context, t *ui.Theme, label, value string) {
	ui.Row(c).Gap(t.Space(3)).Children(func() {
		ui.Text(c, label).TextColor(t.TextMuted).Width(92)
		ui.Text(c, value).Grow(1)
	})
}

func (a *app) primaryAction(c *ui.Context, t *ui.Theme) {
	// The tooltip names the shortcut, so the key is discoverable.
	switch a.state {
	case connecting:
		// While the code is asked for, the dialog is the way out: it has
		// to be answered or given up, so there is nothing to decide
		// here.
		ui.Button(c, "Cancel").FillWidth().Height(38).
			Background(t.Warning).TextColor(ui.Hex("#FFFFFF")).
			Tooltip("Give up this attempt (Ctrl+Enter)").
			OnClick(a.cancel)
	case connected:
		ui.Button(c, "Disconnect").FillWidth().Height(38).
			TextColor(t.Danger).Border(1, t.Danger).
			Disabled(a.disconnecting).
			Tooltip("Disconnect (Ctrl+Enter)").
			OnClick(a.disconnect)
	default:
		ui.PrimaryButton(c, "Connect").FillWidth().Height(38).
			Tooltip("Connect (Ctrl+Enter)").
			OnClick(a.connect)
	}
}

func (a *app) mfaDialog(c *ui.Context, t *ui.Theme) {
	dialog := ui.Modal(c, &a.mfaOpen, func() {
		ui.Column(c).Width(320).Gap(t.Space(2)).Children(func() {
			ui.Text(c, "Verification code").FontSize(18).Bold()
			ui.Text(c, "Enter the 6-digit code from Microsoft Authenticator.").
				TextColor(t.TextMuted)
			if a.mfaNote != "" {
				ui.Text(c, a.mfaNote).TextColor(t.Danger)
			}
			// The code is a number: it is shown in a fixed-width font,
			// centered, so a mistyped digit stands out.
			ui.TextInput(c, &a.mfaCode).
				Placeholder("000000").
				AutoFocus().
				Font("monospace").
				FontSize(22).
				TextAlign(ui.Center).
				FillWidth().
				OnSubmit(a.submitMFA)
			ui.Text(c, "The code is good for about 30 seconds.").
				FontSize(12).TextColor(t.TextMuted)
			ui.Text(c, "Enter to submit · Esc gives up").
				FontSize(12).TextColor(t.TextMuted)
			ui.Row(c).Justify(ui.End).Gap(t.Space(2)).Children(func() {
				ui.PrimaryButton(c, "Submit").OnClick(a.submitMFA)
			})
		})
	})
	// The dialog is a gate: a code leads on, and closing it (Escape or a
	// click outside) gives up the attempt. There is no way to leave the
	// code for later.
	if dialog.Dismissed() && a.mfaPending && a.state == connecting {
		a.cancel()
	}
}

func (a *app) logPanel(c *ui.Context) {
	t := a.theme(c)
	entries := a.visibleLog()
	ui.Themed(c, t).Fill().Children(func() {
		ui.Column(c).Grow(1).Padding(t.Space(4)).Gap(t.Space(2)).Children(func() {
			ui.Row(c).AlignItems(ui.Baseline).Gap(t.Space(2)).Children(func() {
				ui.Text(c, "Connection log").FontSize(18).Bold()
				ui.Text(c, "this session").FontSize(12).TextColor(t.TextMuted)
			})
			ui.Row(c).AlignItems(ui.Center).Gap(t.Space(2)).Children(func() {
				ui.Text(c, "Level").FontSize(12).TextColor(t.TextMuted)
				ui.Segmented(c, &a.logFilter, "All", "Info+", "Warnings", "Errors")
			})
			ui.Row(c).Gap(t.Space(2)).Children(func() {
				ui.SearchField(c, &a.logSearch).Placeholder("Search the log").Grow(1)
				ui.Button(c, "Latest").Tooltip("Scroll back to the newest line").
					OnClick(a.jumpToLatest)
			})
			// The official list virtualizes long logs and FollowEnd keeps the
			// newest line in view; a border on each row separates entries.
			ui.List(c, &a.logList, len(entries), func(i int) {
				entry := entries[i]
				color := logLevelColor(entry.level, t)
				ui.Row(c).RowWidth(600).Padding(5, 8).
					BorderWidth(0, 0, 1, 0).BorderColor(t.Border).Children(func() {
					ui.Text(c, logLevelTag(entry.level)).Width(34).
						Font("monospace").FontSize(11).Bold().TextColor(color)
					// A fixed width wraps long lines here instead of
					// widening the row and scrolling sideways.
					ui.Text(c, entry.text).Width(544).
						Font("monospace").FontSize(12).TextColor(color).Selectable()
				})
			}).RowWidth(600).Grow(1).Children(func() {
				if len(a.logLines) == 0 {
					ui.Text(c, "No log lines yet").TextColor(t.TextMuted).Padding(12)
				} else if len(entries) == 0 {
					ui.Text(c, "No lines at this level").TextColor(t.TextMuted).Padding(12)
				}
			})
			ui.Row(c).Justify(ui.End).Gap(t.Space(2)).Children(func() {
				copyLabel := "Copy"
				if !a.copiedAt.IsZero() {
					copyLabel = "Copied"
				}
				ui.Button(c, copyLabel).Disabled(len(entries) == 0).
					Tooltip("Copy the lines shown to the clipboard").
					OnClick(a.copyLog)
				ui.Button(c, "Export...").Disabled(len(entries) == 0).
					Tooltip("Save the lines shown to a file").
					OnClick(a.exportLog)
				ui.Button(c, "Clear").
					Tooltip("Hide the lines shown so far; the session log file is kept").
					OnClick(a.clearLog)
				ui.PrimaryButton(c, "Close").OnClick(a.closeLog)
			})
			noteLine(c, t, a.logNote)
		})
	})
}

func logLevelTag(level logLevel) string {
	switch level {
	case lvlDebug:
		return "DBG"
	case lvlWarn:
		return "WRN"
	case lvlError:
		return "ERR"
	default:
		return "INF"
	}
}

func logLevelColor(level logLevel, t *ui.Theme) ui.Color {
	switch level {
	case lvlDebug:
		return t.TextMuted
	case lvlWarn:
		return t.Warning
	case lvlError:
		return t.Danger
	default:
		return t.Text
	}
}

// ------------------------------------------------------------------ routes

func (a *app) routesPanel(c *ui.Context) {
	t := a.theme(c)
	ui.Themed(c, t).Fill().Children(func() {
		ui.Column(c).Grow(1).Padding(t.Space(4)).Gap(t.Space(2)).Children(func() {
			ui.Text(c, "Routes").FontSize(18).Bold()
			ui.Text(c, "Learned routes go through the tunnel, so the resources that "+
				"need the campus exit are reachable. They are installed when the "+
				"tunnel comes up.").FontSize(12).TextColor(t.TextMuted)
			ui.List(c, nil, len(a.routeList), func(i int) {
				r := a.routeList[i]
				host := r.Host
				if host == "" {
					host = "no host recorded"
				}
				ui.Row(c).RowWidth(440).Gap(t.Space(2)).Padding(4, 6).
					BorderWidth(0, 0, 1, 0).BorderColor(t.Border).Children(func() {
					ui.Column(c).Grow(1).Children(func() {
						ui.Text(c, r.Cidr()).Font("monospace").FontSize(12)
						ui.Text(c, host+" · "+routeAge(r.Seen)).
							FontSize(11).TextColor(t.TextMuted)
					})
					ui.Button(c, "Remove").OnClick(func() { a.removeRoute(r.Base) })
				})
			}).RowWidth(440).Grow(1).Children(func() {
				if len(a.routeList) == 0 {
					ui.Text(c, "No learned routes yet").TextColor(t.TextMuted).Padding(12)
				}
			})
			ui.Row(c).Gap(t.Space(2)).Children(func() {
				ui.TextInput(c, &a.routeInput).Placeholder("1.2.3.0/24").Grow(1)
				ui.Button(c, "Add").OnClick(a.addRoute)
			})
			ui.Row(c).Justify(ui.End).Gap(t.Space(2)).Children(func() {
				ui.Button(c, "Clear all").Disabled(len(a.routeList) == 0).
					OnClick(a.clearRoutes)
				ui.PrimaryButton(c, "Close").OnClick(a.closeRoutes)
			})
			noteLine(c, t, a.routesNote)
		})
	})
}

// ------------------------------------------------------------- diagnostics

func (a *app) diagnosticsPanel(c *ui.Context) {
	t := a.theme(c)
	ui.Themed(c, t).Fill().Children(func() {
		ui.Column(c).Grow(1).Padding(t.Space(4)).Gap(t.Space(2)).Children(func() {
			ui.Row(c).AlignItems(ui.Baseline).Gap(t.Space(2)).Children(func() {
				ui.Text(c, "Diagnostics").FontSize(18).Bold()
				if a.diagRunning {
					ui.Text(c, "running...").FontSize(12).TextColor(t.TextMuted)
				}
			})
			ui.Text(c, "What the app needs to connect, and whether the local "+
				"proxies carry traffic through the campus.").
				FontSize(12).TextColor(t.TextMuted)
			ui.List(c, nil, len(a.diagResults), func(i int) {
				r := a.diagResults[i]
				color, mark := t.Text, "OK"
				switch {
				case !r.OK && r.Warn:
					color, mark = t.Warning, "!"
				case !r.OK:
					color, mark = t.Danger, "X"
				}
				ui.Row(c).RowWidth(440).Gap(t.Space(2)).Padding(4, 6).
					BorderWidth(0, 0, 1, 0).BorderColor(t.Border).Children(func() {
					ui.Text(c, mark).Width(26).Bold().TextColor(color)
					ui.Column(c).Grow(1).Children(func() {
						ui.Text(c, r.Name).FontSize(12).Bold()
						ui.Text(c, r.Note).FontSize(11).TextColor(t.TextMuted)
					})
				})
			}).RowWidth(440).Grow(1).Children(func() {
				if len(a.diagResults) == 0 && !a.diagRunning {
					ui.Text(c, "No checks yet").TextColor(t.TextMuted).Padding(12)
				}
			})
			ui.Row(c).Justify(ui.End).Gap(t.Space(2)).Children(func() {
				ui.PrimaryButton(c, "Run checks").Disabled(a.diagRunning).
					OnClick(a.runDiagnostics)
				ui.Button(c, "Close").OnClick(a.closeDiagnostics)
			})
		})
	})
}

// ---------------------------------------------------------------- settings

func (a *app) settingsPanel(c *ui.Context) {
	t := a.theme(c)
	ui.Themed(c, t).Fill().Children(func() {
		ui.Column(c).Grow(1).Padding(t.Space(4)).Gap(t.Space(2)).Children(func() {
			ui.Text(c, "Settings").FontSize(18).Bold()
			ui.Text(c, "The advanced options are written to hku.env and "+
				"apply to the next connect.").FontSize(12).TextColor(t.TextMuted)
			ui.Scroll(c).Grow(1).Children(func() {
				ui.Column(c).Width(440).Gap(t.Space(2)).Children(func() {
					ui.Field(c, "VPN endpoint", func() {
						ui.TextInput(c, &a.settingsForm.Endpoint).
							Placeholder("vpn2fa.hku.hk")
					})
					ui.Row(c).Gap(t.Space(2)).Children(func() {
						ui.Field(c, "SOCKS port", func() {
							ui.NumberInput(c, &a.settingsForm.SocksPort, 1, 65535, 1)
						}).Grow(1)
						ui.Field(c, "HTTP port", func() {
							ui.NumberInput(c, &a.settingsForm.HttpPort, 1, 65535, 1)
						}).Grow(1)
					})
					ui.Field(c, "DTLS", func() {
						ui.Switch(c, &a.settingsForm.DTLS)
					})
					ui.Field(c, "Auto-learn routes", func() {
						ui.Switch(c, &a.settingsForm.AutoRoutes)
					})
					ui.Row(c).Gap(t.Space(2)).Children(func() {
						ui.Field(c, "Prefix", func() {
							ui.NumberInput(c, &a.settingsForm.RoutePrefix, 8, 32, 1)
						}).Grow(1)
						ui.Field(c, "Max routes", func() {
							ui.NumberInput(c, &a.settingsForm.RouteMax, 1, 10000, 1)
						}).Grow(1)
					})
					ui.Field(c, "TTL days", func() {
						ui.NumberInput(c, &a.settingsForm.RouteTTL, 1, 365, 1)
					})
					ui.Field(c, "Proxy domains", func() {
						ui.TextInput(c, &a.settingsForm.ProxyDomains).
							Placeholder("library.hku.hk, api.hku.hk")
					})
					ui.Field(c, "Extra routes", func() {
						ui.TextInput(c, &a.settingsForm.ExtraRoutes).
							Placeholder("10.0.0.0/8")
					})
					ui.Field(c, "Campus DNS rules", func() {
						ui.Switch(c, &a.settingsForm.NRPT)
					})
					ui.Field(c, "DNS domains", func() {
						ui.TextInput(c, &a.settingsForm.NRPTDomains).
							Placeholder("hku.hk")
					})

					ui.Text(c, "This app").FontSize(13).Bold()
					ui.Field(c, "Start with Windows", func() {
						ui.Switch(c, &a.settingsForm.AutoStart)
					})
					ui.Field(c, "Reconnect if the session drops", func() {
						ui.Switch(c, &a.settingsForm.AutoReconnect)
					})
					ui.Field(c, "Connect when the app starts", func() {
						ui.Switch(c, &a.settingsForm.ConnectOnStart)
					})
				})
			})
			noteLine(c, t, a.settingsNote)
			ui.Row(c).Justify(ui.End).Gap(t.Space(2)).Children(func() {
				ui.Button(c, "Cancel").OnClick(a.closeSettings)
				ui.PrimaryButton(c, "Save").OnClick(func() {
					if a.saveSettings() {
						a.closeSettings()
					}
				})
			})
		})
	})
}

// noteLine says what happened, inside the panel that asked for it.
func noteLine(c *ui.Context, t *ui.Theme, note panelNote) {
	if note.text == "" {
		return
	}
	color := t.TextMuted
	if note.isErr {
		color = t.Danger
	}
	ui.Text(c, note.text).FontSize(11).TextColor(color)
}

// toast says what happened, over the panel that asked for it.
func toast(c *ui.Context, message string, isError bool) {
	if isError {
		c.AddToast(ui.Toast{Title: message, Type: "error"})
		return
	}
	c.Toast(message)
}
