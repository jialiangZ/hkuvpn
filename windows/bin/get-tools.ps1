#Requires -Version 5.1
<#
get-tools.ps1 - fetch the native Windows dependencies for hkuvpn.ps1.

  1. gost v3.3.0 (windows/amd64) - the SOCKS5/HTTP proxy listeners.
     Download is verified against a SHA256 pinned from the official
     go-gost checksums.txt, the same way docker/Dockerfile pins it.
  2. OpenConnect command-line installer (64-bit, GnuTLS build, includes
     the Wintun driver since OpenConnect v9.00). It is the official GitLab
     CI build of the v9.21 TAG, whose artifacts never expire, so the
     download is SHA256-verified too.

Usage (elevated PowerShell recommended, so the installer can run):
  powershell -ExecutionPolicy Bypass -File get-tools.ps1
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# Tools live next to this script's parent directory (windows/tools), which is
# where hkuvpn.ps1 looks for them.
$ToolsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools'
$GostVersion = '3.3.0'
$GostUrl = "https://github.com/go-gost/gost/releases/download/v${GostVersion}/gost_${GostVersion}_windows_amd64.zip"
$GostSha256 = 'CC8AC946F86994A3AED47EF1F838CFB6B7649D9245C91FCB9899654B33D61170'

# OpenConnect for Windows comes from the official GitLab CI build of the
# v9.21 tag. That tag pipeline keeps its Windows artifacts forever
# ("persist-windows-builds-for-tagged-releases", expire_in: never), so the
# URL stays valid - unlike the moving "master" artifacts, which expire after
# a week. The SHA-256 is pinned, so this download is verified like gost's.
$OcVersion = 'v9.21'
$OcJobId   = '14877945030'    # MinGW64/GnuTLS job of the v9.21 tag pipeline
$OcFile    = 'openconnect-installer-MinGW64-GnuTLS.exe'
$OcUrl     = "https://gitlab.com/api/v4/projects/openconnect%2Fopenconnect/jobs/$OcJobId/artifacts/$OcFile"
$OcSha256  = '6EE9E8EB9BC59EF70BB0717DF7F99703F8A2CCD11D8E45D58A61F9A2E6EF7D00'

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Path $ToolsDir)) {
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
}
Write-Host "Tools directory: $ToolsDir"

# --- gost --------------------------------------------------------------------

$gostExe = Join-Path $ToolsDir 'gost.exe'
if (Test-Path $gostExe) {
    Write-Host "gost.exe already present: $gostExe"
} else {
    Write-Host "Downloading gost $GostVersion (windows/amd64)..."
    $gostZip = Join-Path $ToolsDir "gost_$GostVersion`_windows_amd64.zip"
    Invoke-WebRequest -Uri $GostUrl -OutFile $gostZip -UseBasicParsing
    $hash = (Get-FileHash -Path $gostZip -Algorithm SHA256).Hash
    if ($hash -ne $GostSha256) {
        Remove-Item $gostZip -Force
        throw "gost archive hash mismatch: got $hash, expected $GostSha256"
    }
    Write-Host 'gost archive hash verified.'
    $extractDir = Join-Path $ToolsDir 'gost-extract'
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $gostZip -DestinationPath $extractDir -Force
    $found = Get-ChildItem -Path $extractDir -Recurse -Filter 'gost.exe' |
        Select-Object -First 1
    if (-not $found) { throw 'gost.exe not found inside the archive' }
    Copy-Item $found.FullName $gostExe -Force
    Remove-Item $extractDir -Recurse -Force
    Remove-Item $gostZip -Force
    Write-Host "gost installed: $gostExe"
}

# --- OpenConnect -------------------------------------------------------------

$ocCandidates = @(
    (Join-Path $ToolsDir 'openconnect.exe'),
    (Join-Path $env:ProgramFiles 'OpenConnect\openconnect.exe'),
    (Join-Path $env:ProgramFiles 'OpenConnect\bin\openconnect.exe')
)
$ocPresent = $ocCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($ocPresent) {
    Write-Host "openconnect.exe already present: $ocPresent"
} else {
    $installer = Join-Path $ToolsDir 'openconnect-installer.exe'
    Write-Host "Downloading OpenConnect $OcVersion installer (GitLab CI tag build, 64-bit)..."
    Invoke-WebRequest -Uri $OcUrl -OutFile $installer -UseBasicParsing
    $ocHash = (Get-FileHash -Path $installer -Algorithm SHA256).Hash
    if ($ocHash -ne $OcSha256) {
        Remove-Item $installer -Force
        throw "OpenConnect installer hash mismatch: got $ocHash, expected $OcSha256 (pinned for $OcVersion)"
    }
    Write-Host 'OpenConnect installer hash verified.'

    if (Test-IsAdmin) {
        Write-Host 'Running the installer silently (/S)...'
        $p = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
        Write-Host ("installer exit code: {0}" -f $p.ExitCode)
        $ocPresent = $ocCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($ocPresent) {
            Write-Host "openconnect installed: $ocPresent"
            if (Test-Path $installer) { Remove-Item $installer -Force; Write-Host 'installer downloaded for install, removed after install.' }
        } else {
            Write-Warning "Installer finished but openconnect.exe was not found in the usual locations."
            Write-Warning "Run the installer manually: $installer"
        }
    } else {
        Write-Host 'Not elevated; run the installer manually (double-click or from an admin shell):'
        Write-Host "  $installer"
    }
}

# --- vpnc script check --------------------------------------------------------

$vpnc = Join-Path (Split-Path -Parent $PSScriptRoot) 'etc\vpnc-script-win.js'
if (Test-Path $vpnc) {
    Write-Host "vpnc script ok: $vpnc"
} else {
    Write-Warning "vpnc script missing: $vpnc"
}

Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. mkdir %USERPROFILE%\.vpn ; copy windows\examples\hku.env.example there as hku.env'
Write-Host '     and set HKU_USER=<youruid>@connect.hku.hk'
Write-Host '  2. Put your static Portal PIN (no trailing newline needed) in %USERPROFILE%\.vpn\hku.pass'
Write-Host '  3. powershell -ExecutionPolicy Bypass -File windows\bin\hkuvpn.ps1 --check'
Write-Host '  4. powershell -ExecutionPolicy Bypass -File windows\bin\hkuvpn.ps1'
