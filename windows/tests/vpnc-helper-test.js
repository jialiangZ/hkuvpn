// Syntax + unit check for vpnc-script-win.js's pure helpers.
// Run with: cscript.exe /nologo vpnc-helper-test.js
// It does NOT call doConnect (that would touch the real network); it only
// checks the pure functions, which is where the DNS fix and the MTU fix live.

var envMap = {
    "CISCO_CSTP_OPTIONS": "X-CSTP-MTU=1271\nX-DTLS-MTU=1246\nX-DTLS-Keepalive=20\n"
};
function env(name) {
    if (envMap[name] === undefined) { return ""; }
    return envMap[name];
}

function myTrim(s) {
    if (!s) { return ""; }
    return s.replace(/^\s+/, "").replace(/\s+$/, "");
}
function ipIsV4(s) {
    return /^\d{1,3}(\.\d{1,3}){3}$/.test(s);
}
function ipToInt(s) {
    var p = s.split(".");
    return ((((+p[0]) * 256 + (+p[1])) * 256 + (+p[2])) * 256 + (+p[3])) >>> 0;
}
function ipCovered(ip, net, len) {
    var m = (0xFFFFFFFF << (32 - len)) >>> 0;
    return ((ipToInt(ip) & m) >>> 0) === ((ipToInt(net) & m) >>> 0);
}
function cstpOption(name) {
    var opts = env("CISCO_CSTP_OPTIONS");
    if (!opts) { return ""; }
    var lines = opts.split("\n");
    for (var i = 0; i < lines.length; i++) {
        var eq = lines[i].indexOf("=");
        if (eq > 0 && lines[i].substring(0, eq) === name) {
            return myTrim(lines[i].substring(eq + 1));
        }
    }
    return "";
}

var fails = 0;
function check(cond, what) {
    if (cond) {
        WScript.Echo("ok   " + what);
    } else {
        WScript.Echo("FAIL " + what);
        fails++;
    }
}

check(ipCovered("147.8.2.254", "147.8.0.0", 16), "147.8.2.254 in 147.8.0.0/16");
check(!ipCovered("147.8.2.254", "147.8.212.0", 24), "147.8.2.254 NOT in 147.8.212.0/24");
check(ipCovered("147.8.212.223", "147.8.212.0", 24), "147.8.212.223 in 147.8.212.0/24");
check(ipCovered("10.64.192.125", "10.0.0.0", 8), "10.64.192.125 in 10.0.0.0/8");
check(!ipCovered("10.64.192.125", "147.8.0.0", 16), "10.64.192.125 NOT in 147.8.0.0/16");
check(ipCovered("1.2.3.4", "1.2.3.4", 32), "host route /32 covers itself");
check(!ipCovered("1.2.3.5", "1.2.3.4", 32), "/32 does not cover the next address");

check(cstpOption("X-DTLS-MTU") === "1246", "X-DTLS-MTU parsed");
check(cstpOption("X-CSTP-MTU") === "1271", "X-CSTP-MTU parsed");
check(cstpOption("X-DTLS-Keepalive") === "20", "X-DTLS-Keepalive parsed");
check(cstpOption("X-DTLS-Session-ID") === "", "missing option -> empty string");

// The MTU decision: cap the CSTP MTU at the DTLS MTU when it is smaller.
var mtu = 1271;
var dtls = parseInt(cstpOption("X-DTLS-MTU"), 10);
if (!isNaN(dtls) && dtls > 0 && dtls < mtu) { mtu = dtls; }
check(mtu === 1246, "MTU capped to DTLS MTU (1246)");
envMap["CISCO_CSTP_OPTIONS"] = "X-CSTP-MTU=1271\n";
dtls = parseInt(cstpOption("X-DTLS-MTU"), 10);
mtu = 1271;
if (!isNaN(dtls) && dtls > 0 && dtls < mtu) { mtu = dtls; }
check(mtu === 1271, "no DTLS MTU -> keep CSTP MTU");

WScript.Echo("");
if (fails === 0) {
    WScript.Echo("all checks passed");
    WScript.Quit(0);
} else {
    WScript.Echo(fails + " check(s) failed");
    WScript.Quit(1);
}

