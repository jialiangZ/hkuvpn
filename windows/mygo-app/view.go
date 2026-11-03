package main

import (
	"github.com/egoist/mygo/ui"
)

// theme copies the official light/dark theme and only swaps the accent for
// HKU green, so every control keeps the stock MyGo metrics and colors.
func (a *app) theme(c *ui.Context) *ui.Theme {
	if a.uiTheme == nil {
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
						ui.Text(c, a.headline).FontSize(26).Bold()
					}
					detailRow(c, t, "Proxy", "socks5://127.0.0.1:1080 · http://127.0.0.1:1088")
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

				ui.Button(c, "View log").Width(140).OnClick(a.openLog)

				ui.Text(c, a.hint).FontSize(12).TextColor(t.TextMuted)
			})
		})

		a.mfaDialog(c, t)
		a.logDialog(c, t)
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
		ui.Text(c, "Connection log").FontSize(18).Bold()
		ui.Scroll(c).Height(320).TrackScroll(&a.logScroll).Children(func() {
			for _, line := range a.logLines {
				ui.Text(c, line).Font("monospace").FontSize(12)
			}
		})
		ui.Row(c).Justify(ui.End).Gap(8).Children(func() {
			ui.Button(c, "Clear").OnClick(a.clearLog)
			ui.PrimaryButton(c, "Close").OnClick(func() { a.logOpen = false })
		})
	})
}
