// vpnc-script-win.js — split-tunnel-only variant for the native Windows port
// of hkuvpn (HKU campus VPN).
//
// This is an ORIGINAL implementation written for this project. It speaks the
// documented vpnc-script contract that OpenConnect uses (environment
// variables such as `reason`, `TUNIDX`, `INTERNAL_IP4_ADDRESS`,
// `CISCO_SPLIT_INC_*`, ...). It deliberately does NOT copy upstream
// vpnc-scripts code, and it deliberately diverges from upstream behavior in
// ONE crucial way:
//
//   It never installs a default route through the tunnel and never touches
//   interface metrics or the DNS configuration of other adapters. Only the
//   routes reported by the VPN server (CISCO_SPLIT_INC_*) plus the optional
//   HKU_EXTRA_ROUTES list are added, so the Windows host keeps its normal
//   default route while campus subnets become reachable through the VPN.
//
// OpenConnect runs this file with `cscript.exe /e:JScript` (see script.c in
// the OpenConnect source), so it must remain ECMAScript-3 "JScript":
//   - no `const`/`let`, no arrow functions, no `Array.prototype.indexOf`
//   - no `String.prototype.trim`, no JSON object
//
// Extra environment variables consumed (set by hkuvpn.ps1):
//   HKU_EXTRA_ROUTES   comma-separated CIDR list, e.g. "147.8.0.0/16"
//   HKU_STATE_FILE     where to persist state (routes/DNS) for cleanup
//   HKU_LOG_FILE       append-only log file

var ws = WScript.CreateObject("WScript.Shell");
var env = ws.Environment("Process");
var comspec = ws.ExpandEnvironmentStrings("%comspec%");

// -------------------------------------------------------------- logging

function log(msg) {
    var path = env("HKU_LOG_FILE");
    if (!path) {
        return;
    }
    try {
        var fs = WScript.CreateObject("Scripting.FileSystemObject");
        var f = fs.OpenTextFile(path, 8, true);
        f.WriteLine(new Date().toLocaleString() + " [vpnc] " + msg);
        f.Close();
    } catch (e) {
        // Logging must never break the connection.
    }
}

// -------------------------------------------------------------- helpers

function myTrim(s) {
    if (!s) {
        return "";
    }
    return s.replace(/^\s+/, "").replace(/\s+$/, "");
}

function run(cmd) {
    // Synchronous cmd.exe execution; failure is logged, never fatal — a
    // duplicate `route add` on reconnect is harmless, and a missing DNS
    // entry must not tear down an otherwise working tunnel.
    var fullCmd = comspec + " /C \"" + cmd + "\" 2>&1";
    var out = "";
    var code = 0;
    try {
        var e = ws.Exec(fullCmd);
        out = e.StdOut.ReadAll();
        code = e.ExitCode;
    } catch (ex) {
        log("EXCEPTION: " + cmd + " -> " + ex.message);
        return 1;
    }
    if (code !== 0) {
        log("FAILED (" + code + "): " + cmd + " -> " + myTrim(out));
    } else {
        log("ok: " + cmd);
    }
    return code;
}

function maskToLen(mask) {
    // "255.255.0.0" -> 16 (counts set bits; only used with server-provided
    // contiguous netmasks).
    var parts = mask.split(".");
    var len = 0;
    for (var i = 0; i < parts.length; i++) {
        var o = parseInt(parts[i], 10);
        while (o !== 0) {
            len += (o & 1);
            o = (o >>> 1);
        }
    }
    return len;
}

function cidrToMask(len) {
    // len 1..32 (0 is rejected by the caller as a full-tunnel mistake).
    var m = (0xFFFFFFFF << (32 - len)) >>> 0;
    return ((m >>> 24) & 255) + "." + ((m >>> 16) & 255) + "." +
           ((m >>> 8) & 255) + "." + (m & 255);
}

function ipIsV4(s) {
    return /^\d{1,3}(\.\d{1,3}){3}$/.test(s);
}

// -------------------------------------------------------------- state file

function stateWrite(lines) {
    var path = env("HKU_STATE_FILE");
    if (!path) {
        return;
    }
    try {
        var fs = WScript.CreateObject("Scripting.FileSystemObject");
        var f = fs.CreateTextFile(path, true);
        for (var i = 0; i < lines.length; i++) {
            f.WriteLine(lines[i]);
        }
        f.Close();
    } catch (e) {
        log("cannot write state file: " + e.message);
    }
}

function stateRead() {
    var path = env("HKU_STATE_FILE");
    if (!path) {
        return null;
    }
    var fs = WScript.CreateObject("Scripting.FileSystemObject");
    if (!fs.FileExists(path)) {
        return null;
    }
    var lines = [];
    try {
        var f = fs.OpenTextFile(path, 1);
        while (!f.AtEndOfStream) {
            lines.push(myTrim(f.ReadLine()));
        }
        f.Close();
    } catch (e) {
        return null;
    }
    return lines;
}

function stateDelete() {
    var path = env("HKU_STATE_FILE");
    if (!path) {
        return;
    }
    try {
        var fs = WScript.CreateObject("Scripting.FileSystemObject");
        if (fs.FileExists(path)) {
            fs.DeleteFile(path);
        }
    } catch (e) {
        log("cannot delete state file: " + e.message);
    }
}

function stateValue(lines, key) {
    var prefix = key + "=";
    for (var i = 0; i < lines.length; i++) {
        if (lines[i].indexOf(prefix) === 0) {
            return lines[i].substring(prefix.length);
        }
    }
    return "";
}

// -------------------------------------------------------------- connect

function doConnect() {
    var tunidx = myTrim(env("TUNIDX"));
    var ip4 = myTrim(env("INTERNAL_IP4_ADDRESS"));
    if (!tunidx || !ip4) {
        log("connect: TUNIDX/INTERNAL_IP4_ADDRESS missing; nothing to do");
        return;
    }
    var mask = myTrim(env("INTERNAL_IP4_NETMASK")) || "255.255.255.255";

    // Static address WITHOUT a gateway: this is what keeps the host's
    // default route untouched (upstream adds a gateway/metric in
    // tunnel-all mode; we never do).
    run("netsh interface ipv4 set address " + tunidx + " static " +
        ip4 + " " + mask + " store=active");

    if (myTrim(env("INTERNAL_IP4_MTU"))) {
        run("netsh interface ipv4 set subinterface " + tunidx +
            " mtu=" + myTrim(env("INTERNAL_IP4_MTU")) + " store=active");
    }

    // DNS servers are registered on the tunnel adapter ONLY. Actual use of
    // these resolvers for *.hku.hk is arranged by hkuvpn.ps1 through an
    // NRPT rule, so general name resolution stays with the physical NICs.
    var dnsV4 = [];
    run("netsh interface ipv4 delete dnsservers " + tunidx + " all");
    var dnsRaw = myTrim(env("INTERNAL_IP4_DNS"));
    if (dnsRaw) {
        var dnsAll = dnsRaw.split(/[\s,]+/);
        for (var d = 0; d < dnsAll.length; d++) {
            var srv = myTrim(dnsAll[d]);
            if (!srv) {
                continue;
            }
            if (ipIsV4(srv)) {
                run("netsh interface ipv4 add dnsservers " + tunidx + " " +
                    srv + " validate=no");
                dnsV4.push(srv);
            } else {
                log("skipping non-IPv4 DNS server: " + srv);
            }
        }
    }

    // Split routes pushed by the server.
    var routes = []; // "net/masklen" strings, persisted for cleanup
    var incCount = parseInt(myTrim(env("CISCO_SPLIT_INC")) || "0", 10);
    if (isNaN(incCount) || incCount < 0) {
        incCount = 0;
    }
    for (var i = 0; i < incCount; i++) {
        var net = myTrim(env("CISCO_SPLIT_INC_" + i + "_ADDR"));
        var nmask = myTrim(env("CISCO_SPLIT_INC_" + i + "_MASK"));
        var nlen = myTrim(env("CISCO_SPLIT_INC_" + i + "_MASKLEN"));
        if (!net || !nmask) {
            continue;
        }
        var len = parseInt(nlen, 10);
        if (isNaN(len)) {
            len = maskToLen(nmask);
        }
        if (len === 0) {
            log("ignoring split route " + net + "/" + len +
                " (len 0 would hijack the default route)");
            continue;
        }
        if (len < 0 || len > 32) {
            log("ignoring invalid split route " + net + "/" + len);
            continue;
        }
        run("route add " + net + " mask " + nmask + " " + ip4 +
            " metric 1 if " + tunidx);
        routes.push(net + "/" + len);
    }

    // Extra routes requested by the user (HKU_EXTRA_ROUTES=147.8.0.0/16,...).
    var extraRaw = myTrim(env("HKU_EXTRA_ROUTES"));
    if (extraRaw) {
        var extras = extraRaw.split(",");
        for (var x = 0; x < extras.length; x++) {
            var item = myTrim(extras[x]);
            if (!item) {
                continue;
            }
            var slash = item.indexOf("/");
            if (slash < 1) {
                log("ignoring malformed HKU_EXTRA_ROUTES entry: " + item);
                continue;
            }
            var base = item.substring(0, slash);
            var bits = parseInt(item.substring(slash + 1), 10);
            if (!ipIsV4(base) || isNaN(bits) || bits < 1 || bits > 32) {
                log("ignoring malformed HKU_EXTRA_ROUTES entry: " + item);
                continue;
            }
            run("route add " + base + " mask " + cidrToMask(bits) + " " +
                ip4 + " metric 1 if " + tunidx);
            routes.push(base + "/" + bits);
        }
    }

    // IPv6: configure address and pushed split routes only. As with IPv4,
    // no default route and no DNS is installed.
    var ip6 = myTrim(env("INTERNAL_IP6_ADDRESS"));
    var v6routes = [];
    if (ip6) {
        run("netsh interface ipv6 set address " + tunidx + " " + ip6 +
            " store=active");
        var v6inc = parseInt(myTrim(env("CISCO_IPV6_SPLIT_INC")) || "0", 10);
        if (!isNaN(v6inc)) {
            for (var v = 0; v < v6inc; v++) {
                var v6net = myTrim(env("CISCO_IPV6_SPLIT_INC_" + v + "_ADDR"));
                var v6len = myTrim(env("CISCO_IPV6_SPLIT_INC_" + v + "_MASKLEN"));
                if (v6net && v6len) {
                    run("netsh interface ipv6 add route " + v6net + "/" +
                        v6len + " " + tunidx + " store=active");
                    v6routes.push(v6net + "/" + v6len);
                }
            }
        }
    }

    var lines = [
        "TIME=" + new Date().toLocaleString(),
        "TUNIDX=" + tunidx,
        "IP4=" + ip4,
        "MASK=" + mask,
        "DNS=" + dnsV4.join(" ")
    ];
    for (var r = 0; r < routes.length; r++) {
        lines.push("ROUTE=" + routes[r]);
    }
    for (var r6 = 0; r6 < v6routes.length; r6++) {
        lines.push("ROUTE6=" + v6routes[r6]);
    }
    stateWrite(lines);
    log("connect done: " + routes.length + " v4 route(s), " +
        v6routes.length + " v6 route(s), dns=[" + dnsV4.join(" ") + "]");
}

// -------------------------------------------------------------- disconnect

function doDisconnect() {
    var lines = stateRead();
    if (!lines) {
        log("disconnect: no state file; nothing recorded to clean");
        // Best-effort DNS flush on the (likely gone) adapter is pointless.
        return;
    }
    var tunidx = stateValue(lines, "TUNIDX");
    var ip4 = stateValue(lines, "IP4");
    for (var i = 0; i < lines.length; i++) {
        if (lines[i].indexOf("ROUTE=") === 0) {
            var net = lines[i].substring(6).split("/")[0];
            run("route delete " + net);
        } else if (lines[i].indexOf("ROUTE6=") === 0) {
            var p = lines[i].substring(7);
            if (tunidx) {
                run("netsh interface ipv6 delete route " + p + " " + tunidx +
                    " store=active");
            }
        }
    }
    if (tunidx) {
        run("netsh interface ipv4 delete dnsservers " + tunidx + " all");
        if (ip4) {
            run("netsh interface ipv4 delete address " + tunidx + " " + ip4);
        }
    }
    stateDelete();
    log("disconnect done");
}

// -------------------------------------------------------------- main

var reason = myTrim(env("reason"));
log("invoked: reason=" + reason +
    " tunidx=" + myTrim(env("TUNIDX")) +
    " ip4=" + myTrim(env("INTERNAL_IP4_ADDRESS")));

switch (reason) {
    case "pre-init":
        // OpenConnect creates the wintun adapter itself and passes TUNIDX
        // with the later "connect" call.
        log("pre-init (adapter handled by OpenConnect/wintun)");
        break;
    case "connect":
    case "reconnect":
        doConnect();
        break;
    case "disconnect":
        doDisconnect();
        break;
    default:
        log("unknown reason: " + reason);
        break;
}

WScript.Quit(0);
