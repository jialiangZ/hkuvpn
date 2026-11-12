#Requires -Version 5.1
<#
bootstrap.ps1 - create the per-machine configuration once.

The launcher reads %USERPROFILE%\.vpn\hku.env (settings, including your HKU
account) and %USERPROFILE%\.vpn\hku.pass (the static Portal PIN). Those two
files hold your credentials, so they are deliberately not in the repository:
this script writes them from the template in examples\ and asks for the
values. Every other file the VPN needs is in the checkout or the release
bundle.

Existing files are left alone unless -Force is given, with one exception:
-ExtraRoutes always updates just that key, even in an existing hku.env -
it is not a secret, and re-running bootstrap to add a lab subnet should not
have to rewrite the account too (clearing it again means editing the file
or re-running with -Force).
Parameters that are omitted are asked for interactively, so the usual run
is just:

  powershell -ExecutionPolicy Bypass -File bootstrap.ps1

Non-interactive use (CI, a scripted new machine):

  powershell -ExecutionPolicy Bypass -File bootstrap.ps1 `
      -User youruid -Pin <portal-pin> -ExtraRoutes 10.128.0.0/16

-User may be the bare uid: @connect.hku.hk is appended when no @ is given.
-ExtraRoutes is the comma-separated CIDR list for campus-only hosts (the
same value as HKU_EXTRA_ROUTES in hku.env). Leave it out for the default
empty list.
#>
param(
    [string]$User,
    [string]$Pin,
    [string]$ExtraRoutes,
    # Same override the launcher honours.
    [string]$ConfigDir = $env:HKU_CONFIG_DIR,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Fail {
    param([string]$Message)
    Write-Host ("bootstrap: {0}" -f $Message) -ForegroundColor Red
    exit 1
}

function Read-Secret {
    param([string]$Prompt)
    $sec = Read-Host -AsSecureString $Prompt
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# Replaces (or appends) one KEY= line in a file's line list. Defined before
# any early exit so both write paths can use it.
$setKey = {
    param([string[]]$All, [string]$Key, [string]$Value)
    $hit = $false
    $out = foreach ($l in $All) {
        if ($l -match ('^' + [regex]::Escape($Key) + '=')) { $hit = $true; "$Key=$Value" }
        else { $l }
    }
    if (-not $hit) { $out = @($out) + "$Key=$Value" }
    return ,@($out)
}

# --- where things live ------------------------------------------------------

$shellDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$template = [IO.Path]::GetFullPath((Join-Path $shellDir '..\examples\hku.env.example'))
if (-not (Test-Path $template)) {
    Fail ("no template at {0} - keep the shell folder beside examples\, or run this from a checkout or release bundle." -f $template)
}

$vpnDir = if ($ConfigDir) { $ConfigDir } else { Join-Path $env:USERPROFILE '.vpn' }
$envFile = Join-Path $vpnDir 'hku.env'
$passFile = Join-Path $vpnDir 'hku.pass'
if (-not (Test-Path $vpnDir)) {
    New-Item -ItemType Directory -Path $vpnDir -Force | Out-Null
}

# Both files are written as plain ASCII, no BOM: Windows PowerShell 5.1
# reads a BOM-less file as the system code page, and a stray multi-byte
# character can swallow the newline and glue the next value onto a comment.
# ASCII cannot represent anything else, so non-ASCII input is rejected
# instead of silently written as '?'.
function Test-Ascii {
    param([string]$Value, [string]$What)
    if ("$Value" -match '[^\x00-\x7F]') {
        Fail ("the {0} contains non-ASCII characters; edit the file by hand instead." -f $What)
    }
}

# --- account ----------------------------------------------------------------

$writeEnv = $Force -or -not (Test-Path $envFile)
if (-not $writeEnv) {
    Write-Host ("bootstrap: keeping the existing {0}" -f $envFile)
    Write-Host '  (to change the campus subnets only, pass -ExtraRoutes; -Force rewrites everything)'
}

$userValue = $User
if ($writeEnv -and -not $userValue) {
    if ($env:HKU_USER) {
        $userValue = $env:HKU_USER
    } else {
        $userValue = Read-Host 'HKU account (uid or uid@connect.hku.hk)'
    }
}
if ($writeEnv) {
    $userValue = "$userValue".Trim()
    if (-not $userValue) { Fail 'an HKU account is required.' }
    if ($userValue -notmatch '@') {
        $userValue = $userValue + '@connect.hku.hk'
        Write-Host ("bootstrap: using {0}" -f $userValue)
    } elseif ($userValue -notmatch '^[^@\s]+@[^@\s]+$') {
        Fail ("'{0}' does not look like an account." -f $userValue)
    }
    Test-Ascii $userValue 'HKU account (HKU_USER)'
}

# --- extra routes (campus-only hosts) --------------------------------------

$routeValue = $ExtraRoutes
if ($writeEnv -and $null -eq $routeValue) {
    $routeValue = Read-Host ('Extra subnets for campus-only hosts, comma-separated CIDR (Enter for none)')
}
$routeValue = "$routeValue".Trim()
if ($routeValue) {
    foreach ($cidr in ($routeValue -split ',')) {
        $c = $cidr.Trim()
        if ($c -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
            Fail ("'{0}' is not a CIDR, e.g. 10.128.0.0/16" -f $c)
        }
        $o = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
        $bits = [int]$Matches[5]
        if (@($o | Where-Object { $_ -gt 255 }).Count -gt 0 -or $bits -gt 32) {
            Fail ("'{0}' is out of range." -f $c)
        }
    }
    $routeValue = (($routeValue -split ',') | ForEach-Object { $_.Trim() }) -join ','
}

# --- portal PIN -------------------------------------------------------------
# Collected before anything is written: a rejected value must not leave half
# a configuration behind.

$writePass = $Force -or -not (Test-Path $passFile)
if (-not $writePass) {
    Write-Host ("bootstrap: keeping the existing {0}" -f $passFile)
} else {
    $pinValue = $Pin
    if (-not $pinValue) { $pinValue = Read-Secret 'Portal PIN (input is hidden)' }
    $pinValue = "$pinValue".Trim()
    if (-not $pinValue) { Fail 'a Portal PIN is required.' }
    if ($pinValue -match '\s') { Fail 'the Portal PIN contains a space.' }
    Test-Ascii $pinValue 'Portal PIN'
}

# --- write hku.env ----------------------------------------------------------

if ($writeEnv) {
    $lines = @(Get-Content $template)
    $lines = & $setKey $lines 'HKU_USER' $userValue
    $lines = & $setKey $lines 'HKU_EXTRA_ROUTES' $routeValue
    [IO.File]::WriteAllLines($envFile, [string[]]$lines, (New-Object Text.ASCIIEncoding))
    Write-Host ("bootstrap: wrote {0}" -f $envFile)
} elseif ($null -ne $ExtraRoutes) {
    # An explicit -ExtraRoutes updates only that key in the existing file.
    $lines = @(Get-Content $envFile)
    $lines = & $setKey $lines 'HKU_EXTRA_ROUTES' $routeValue
    [IO.File]::WriteAllLines($envFile, [string[]]$lines, (New-Object Text.ASCIIEncoding))
    Write-Host ("bootstrap: updated HKU_EXTRA_ROUTES in {0}" -f $envFile)
}

# --- write hku.pass ---------------------------------------------------------

if ($writePass) {
    [IO.File]::WriteAllText($passFile, $pinValue, (New-Object Text.ASCIIEncoding))
    Write-Host ("bootstrap: wrote {0} ({1} characters)" -f $passFile, $pinValue.Length)
    Write-Host '  The launcher needs this file in plain text; it stays in your profile.'
}

# --- next steps -------------------------------------------------------------

Write-Host ''
Write-Host 'Configuration ready. Next:'
Write-Host '  hkuvpn --check      # pre-flight: config, PIN file, tools, ports'
Write-Host '  hkuvpn              # connect; type the MFA code when asked'
exit 0
