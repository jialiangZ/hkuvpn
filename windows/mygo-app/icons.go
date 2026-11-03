package main

import (
	_ "embed"

	"github.com/egoist/mygo/ui"
)

// The icons of the panels under the window. They are outlines in the
// text color, so they follow the theme (light or dark) on their own.
var (
	//go:embed assets/ui/log.svg
	logSVG []byte
	//go:embed assets/ui/diagnostics.svg
	diagnosticsSVG []byte
	//go:embed assets/ui/routes.svg
	routesSVG []byte
	//go:embed assets/ui/settings.svg
	settingsSVG []byte
)

var (
	iconLog         = ui.MustParseSVG(logSVG)
	iconDiagnostics = ui.MustParseSVG(diagnosticsSVG)
	iconRoutes      = ui.MustParseSVG(routesSVG)
	iconSettings    = ui.MustParseSVG(settingsSVG)
)
