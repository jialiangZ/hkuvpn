// Syntax + unit check for vpnc-script-win.js's pure helpers.
// Run with: cscript.exe //nologo vpnc-helper-test.js
// It does NOT call doConnect (that would touch the real network); it only
// checks the pure functions, which is where the DNS fix lives.

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

WScript.Echo("");
if (fails === 0) {
    WScript.Echo("all checks passed");
    WScript.Quit(0);
} else {
    WScript.Echo(fails + " check(s) failed");
    WScript.Quit(1);
}
