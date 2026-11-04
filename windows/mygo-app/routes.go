package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// learnedRoute is one entry of the worker's learned-routes file: a prefix
// that goes through the tunnel because a proxied request needed it.
type learnedRoute struct {
	Base   string
	Prefix int
	Seen   time.Time
	Host   string
}

func (r learnedRoute) Cidr() string { return fmt.Sprintf("%s/%d", r.Base, r.Prefix) }

func learnedRoutesPath() string { return joinPath(configDir(), "learned-routes.txt") }

// readLearnedRoutes reads the worker's learned routes, the same way the
// worker's Get-LearnedRoutes does: "base/prefix|lastseen-epoch|host" lines.
func readLearnedRoutes() []learnedRoute {
	var out []learnedRoute
	for _, line := range readLines(learnedRoutesPath()) {
		parts := strings.Split(line, "|")
		if len(parts) < 2 {
			continue
		}
		net := strings.Split(parts[0], "/")
		if len(net) != 2 {
			continue
		}
		prefix, err := strconv.Atoi(net[1])
		if err != nil {
			continue
		}
		seen, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			continue
		}
		host := ""
		if len(parts) >= 3 {
			host = parts[2]
		}
		out = append(out, learnedRoute{
			Base:   net[0],
			Prefix: prefix,
			Seen:   time.Unix(seen, 0),
			Host:   host,
		})
	}
	return out
}

func writeLearnedRoutes(routes []learnedRoute) error {
	lines := make([]string, 0, len(routes))
	for _, r := range routes {
		lines = append(lines, fmt.Sprintf("%s/%d|%d|%s", r.Base, r.Prefix, r.Seen.Unix(), r.Host))
	}
	_ = os.MkdirAll(vpnDir(), 0o700)
	body := strings.Join(lines, "\r\n")
	if body != "" {
		body += "\r\n"
	}
	return os.WriteFile(learnedRoutesPath(), []byte(body), 0o600)
}

// deleteLearnedRoute drops one entry from the learned routes.
func deleteLearnedRoute(base string) error {
	routes := readLearnedRoutes()
	kept := make([]learnedRoute, 0, len(routes))
	for _, r := range routes {
		if r.Base == base {
			continue
		}
		kept = append(kept, r)
	}
	return writeLearnedRoutes(kept)
}

// addLearnedRoute adds a prefix to the learned routes, replacing an entry
// for the same base. It takes effect when the tunnel comes up again.
func addLearnedRoute(cidr, host string) error {
	_, ipnet, err := net.ParseCIDR(strings.TrimSpace(cidr))
	if err != nil {
		return fmt.Errorf("%q is not a CIDR block such as 1.2.3.0/24", cidr)
	}
	base := ipnet.IP.String()
	prefix, _ := ipnet.Mask.Size()
	routes := readLearnedRoutes()
	out := make([]learnedRoute, 0, len(routes)+1)
	for _, r := range routes {
		if r.Base == base {
			continue
		}
		out = append(out, r)
	}
	out = append(out, learnedRoute{
		Base:   base,
		Prefix: prefix,
		Seen:   time.Now(),
		Host:   strings.TrimSpace(host),
	})
	return writeLearnedRoutes(out)
}

// routeAge says how long ago a route was learned, in words.
func routeAge(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%d min ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%d h ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%d d ago", int(d.Hours()/24))
	}
}
