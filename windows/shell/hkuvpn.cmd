@echo off
rem hkuvpn - HKU campus VPN, one command.
rem
rem   hkuvpn                 terminal mode (-t) + orphan guard: the tunnel
rem                          runs in a hidden elevated worker, the MFA code
rem                          is typed here, and closing this window after
rem                          "Connected" does not stop the VPN
rem   hkuvpn --status        layered health check
rem   hkuvpn --stop          stop the session (no UAC for a live worker)
rem   hkuvpn --logs          follow the OpenConnect log
rem   hkuvpn -f / -d / --mfa CODE / -t   passed through unchanged
rem
rem Any argument is forwarded to hkuvpn.ps1 verbatim, so the launcher stays
rem the single source of truth. This folder is separate from bin\ on purpose:
rem PowerShell runs a .ps1 script in preference to a .cmd with the same base
rem name, so hkuvpn.cmd must not sit next to hkuvpn.ps1 or the bare command
rem would mean something else in PowerShell than it does in cmd.
rem
rem Run install-path.ps1 once to put this folder on the user PATH.

if "%~1"=="" goto connect
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\bin\hkuvpn.ps1" %*
exit /b %errorlevel%

:connect
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hkuvpn-connect.ps1"
exit /b %errorlevel%
