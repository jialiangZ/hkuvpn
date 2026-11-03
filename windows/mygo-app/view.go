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

	ui.Themed(c, t).Fill().Children(func() {
		ui.Scroll(c).Fill().Children(func() {
			ui.Column(c).Padding(24).Gap(16).Children(func() {

				// Header.
				ui.Column(c).Gap(3).Children(func() {
					ui.Text(c, "HKU VPN").FontSize(22).Bold()
					ui.Text(c, "HKU Portal VPN · vpn2fa.hku.hk").TextColor(t.TextMuted)
				})

				// Status card.
				ui.Column(c).Padding(16).Gap(10).Radius(12).
					Background(t.Surface).Border(1, t.Border).Children(func() {
					ui.Row(c).AlignItems(ui.Center).Gap(8).Children(func() {
						ui.Box(c).Size(10, 10).Radius(5).Background(a.statusColor)
						ui.Text(c, a.statusText).Bold()
						ui.Spacer(c)
						ui.Text(c, a.duration).Font("monospace").TextColor(t.TextMuted)
					})
					if a.headlineMuted {
						ui.Text(c, a.headline).FontSize(17).TextColor(t.TextMuted)
					} else {
						// The big number is the tunnel adapter address, not
						// the public IP: label it so it reads at a glance.
						ui.Row(c).AlignItems(ui.Baseline).Gap(10).Children(func() {
							ui.Text(c, "VPN address").FontSize(13).TextColor(t.TextMuted)
							ui.Text(c, a.headline).FontSize(26).Bold()
						})
					}
					detailRow(c, t, "Proxy", fmt.Sprintf("socks5://127.0.0.1:%d · http://127.0.0.1:%d",
						a.settings.SocksPort, a.settings.HttpPort))
					detailRow(c, t, "Routes", a.routes)
				})

				// Credentials: editing persists them automatically.
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

				// Primary action.
				a.primaryAction(c, t)

				// Panels.
				ui.Row(c).Gap(8).Children(func() {
					ui.Button(c, "View log").Grow(1).OnClick(a.openLog)
					ui.Button(c, "Diagnostics").Grow(1).OnClick(a.openDiagnostics)
				})
				ui.Row(c).Gap(8).Children(func() {
					ui.Button(c, "Routes").Grow(1).OnClick(a.openRoutes)
					ui.Button(c, "Settings").Grow(1).OnClick(a.openSettings)
				})

				ui.Text(c, a.hint).FontSize(12).TextColor(t.TextMuted)
			})
		})

		a.mfaDialog(c, t)
		a.logDialog(c, t)
		a.routesDialog(c, t)
		a.diagnosticsDialog(c, t)
		a.settingsDialog(c, t)
	})
}

func detailRow(c *ui.Context, t *ui.Theme, label, value string) {
	ui.Row(c).Gap(12).Children(func() {
		ui.Text(c, label).TextColor(t.TextMuted).Width(56)
		ui.Text(c, value).TextColor(t.TextMuted).Grow(1)
	})
}

func (a *app) primaryAction(c *ui.Context, t *ui.Theme) {
	switch a.state {
	case connecting:
		ui.Button(c, "Cancel").FillWidth().Height(38).
			Background(t.Warning).TextColor(ui.Hex("#FFFFFF")).
			OnClick(a.cancel)
	case connected:
		ui.Button(c, "Disconnect").FillWidth().Height(38).
			TextColor(t.Danger).Border(1, t.Danger).
			Disabled(a.disconnecting).
			OnClick(a.disconnect)
	default:
		ui.PrimaryButton(c, "Connect").FillWidth().Height(38).
			OnClick(a.connect)
	}
}

func (a *app) mfaDialog(c *ui.Context, t *ui.Theme) {
	dialog := ui.Modal(c, &a.mfaOpen, func() {
		ui.Text(c, "Verification code").FontSize(18).Bold()
		ui.Text(c, "Enter the 6-digit code from Microsoft Authenticator.").
			TextColor(t.TextMuted)
		if a.mfaNote != "" {
			ui.Text(c, a.mfaNote).TextColor(t.Danger)
		}
		ui.TextInput(c, &a.mfaCode).
			Placeholder("000000").
			AutoFocus().
			Font("monospace").
			FontSize(20).
			Width(200).
			OnSubmit(a.submitMFA)
		ui.Row(c).Justify(ui.End).Gap(8).Children(func() {
			ui.PrimaryButton(c, "Submit").OnClick(a.submitMFA)
		})
		ui.Text(c, "Enter to submit · Esc to cancel").FontSize(12).TextColor(t.TextMuted)
	})
	// Escape or a click outside aborts a session that is still being built.
	if dialog.Dismissed() && a.state != connected {
		a.cancel()
	}
}

func (a *app) logDialog(c *ui.Context, t *ui.Theme) {
	ui.Modal(c, &a.logOpen, func() {
		entries := a.visibleLog()
		// A fixed width keeps the dialog from resizing with the log content.
		ui.Column(c).Width(380).Gap(10).Children(func() {
			ui.Row(c).AlignItems(ui.Baseline).Gap(8).Children(func() {
				ui.Text(c, "Connection log").FontSize(18).Bold()
				ui.Text(c, "this session").FontSize(12).TextColor(t.TextMuted)
			})
			ui.Row(c).AlignItems(ui.Center).Gap(10).Children(func() {
				ui.Text(c, "Level").FontSize(12).TextColor(t.TextMuted)
				ui.Segmented(c, &a.logFilter, "All", "Info+", "Warnings", "Errors")
			})
			ui.Row(c).Gap(8).Children(func() {
				ui.SearchField(c, &a.logSearch).Placeholder("Search the log").Grow(1)
				ui.Button(c, "Latest").Tooltip("Scroll back to the newest line").
					OnClick(a.jumpToLatest)
			})
			// The official list virtualizes long logs and FollowEnd keeps the
			// newest line in view; a border on each row separates entries.
			ui.List(c, &a.logList, len(entries), func(i int) {
				entry := entries[i]
				color := logLevelColor(entry.level, t)
				ui.Row(c).RowWidth(372).Padding(5, 8).
					BorderWidth(0, 0, 1, 0).BorderColor(t.Border).Children(func() {
					ui.Text(c, logLevelTag(entry.level)).Width(34).
						Font("monospace").FontSize(11).Bold().TextColor(color)
					// A fixed width wraps long lines here instead of
					// widening the row and scrolling sideways.
					ui.Text(c, entry.text).Width(316).
						Font("monospace").FontSize(12).TextColor(color).Selectable()
				})
			}).RowWidth(372).Height(250).Children(func() {
				if len(a.logLines) == 0 {
					ui.Text(c, "No log lines yet").TextColor(t.TextMuted).Padding(12)
				} else if len(entries) == 0 {
					ui.Text(c, "No lines at this level").TextColor(t.TextMuted).Padding(12)
				}
			})
			ui.Row(c).Justify(ui.End).Gap(8).Children(func() {
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
				ui.PrimaryButton(c, "Close").OnClick(func() { a.logOpen = false })
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

func (a *app) routesDialog(c *ui.Context, t *ui.Theme) {
	ui.Modal(c, &a.routesOpen, func() {
		ui.Column(c).Width(376).Gap(10).Children(func() {
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
				ui.Row(c).RowWidth(368).Gap(8).Padding(4, 6).
					BorderWidth(0, 0, 1, 0).BorderColor(t.Border).Children(func() {
					ui.Column(c).Grow(1).Children(func() {
						ui.Text(c, r.Cidr()).Font("monospace").FontSize(12)
						ui.Text(c, host+" · "+routeAge(r.Seen)).
							FontSize(11).TextColor(t.TextMuted)
					})
					ui.Button(c, "Remove").OnClick(func() { a.removeRoute(r.Base) })
				})
			}).RowWidth(368).Height(220).Children(func() {
				if len(a.routeList) == 0 {
					ui.Text(c, "No learned routes yet").TextColor(t.TextMuted).Padding(12)
				}
			})
			ui.Row(c).Gap(8).Children(func() {
				ui.TextInput(c, &a.routeInput).Placeholder("1.2.3.0/24").Grow(1)
				ui.Button(c, "Add").OnClick(a.addRoute)
			})
			ui.Row(c).Justify(ui.End).Gap(8).Children(func() {
				ui.Button(c, "Clear all").Disabled(len(a.routeList) == 0).
					OnClick(a.clearRoutes)
				ui.PrimaryButton(c, "Close").OnClick(func() { a.routesOpen = false })
			})
			noteLine(c, t, a.routesNote)
		})
	})
}

// ------------------------------------------------------------- diagnostics

func (a *app) diagnosticsDialog(c *ui.Context, t *ui.Theme) {
	ui.Modal(c, &a.diagOpen, func() {
		ui.Column(c).Width(376).Gap(10).Children(func() {
			ui.Row(c).AlignItems(ui.Baseline).Gap(8).Children(func() {
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
				ui.Row(c).RowWidth(368).Gap(8).Padding(4, 6).
					BorderWidth(0, 0, 1, 0).BorderColor(t.Border).Children(func() {
					ui.Text(c, mark).Width(26).Bold().TextColor(color)
					ui.Column(c).Grow(1).Children(func() {
						ui.Text(c, r.Name).FontSize(12).Bold()
						ui.Text(c, r.Note).FontSize(11).TextColor(t.TextMuted)
					})
				})
			}).RowWidth(368).Height(300).Children(func() {
				if len(a.diagResults) == 0 && !a.diagRunning {
					ui.Text(c, "No checks yet").TextColor(t.TextMuted).Padding(12)
				}
			})
			ui.Row(c).Justify(ui.End).Gap(8).Children(func() {
				ui.PrimaryButton(c, "Run checks").Disabled(a.diagRunning).
					OnClick(a.runDiagnostics)
				ui.Button(c, "Close").OnClick(func() { a.diagOpen = false })
			})
		})
	})
}

// ---------------------------------------------------------------- settings

func (a *app) settingsDialog(c *ui.Context, t *ui.Theme) {
	ui.Modal(c, &a.settingsOpen, func() {
		// The title and the buttons stay put; only the fields scroll.
		ui.Column(c).Width(376).Gap(10).Children(func() {
			ui.Text(c, "Settings").FontSize(18).Bold()
			ui.Text(c, "The advanced options are written to hku.env and "+
				"apply to the next connect.").FontSize(12).TextColor(t.TextMuted)
			ui.Scroll(c).Height(360).Children(func() {
				ui.Column(c).Width(376).Gap(10).Children(func() {
					ui.Field(c, "VPN endpoint", func() {
						ui.TextInput(c, &a.settingsForm.Endpoint).
							Placeholder("vpn2fa.hku.hk")
					})
					ui.Row(c).Gap(10).Children(func() {
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
					ui.Row(c).Gap(10).Children(func() {
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
			ui.Row(c).Justify(ui.End).Gap(8).Children(func() {
				ui.Button(c, "Cancel").OnClick(func() { a.settingsOpen = false })
				ui.PrimaryButton(c, "Save").OnClick(func() {
					if a.saveSettings() {
						toast(c, "Settings saved - they apply to the next connect.", false)
					}
				})
			})
		})
	})
}

// noteLine says what happened, inside the panel that asked for it: a
// toast would hide behind the modal it belongs to.
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
