#Requires -Version 5.1
<#
hkuvpn.ps1 - Native Windows launcher for hkuvpn - HKU campus VPN.

Runs OpenConnect (Windows CLI build) + gost directly on Windows, without
WSL or Docker. Mirrors docker/bin/hkuvpn of the Docker edition:

  (no arg)/hk   smart connect: pre-flight, start tunnel + proxy, prompt for
                the MFA code, wait until connected. Stays attached; Ctrl+C
                stops the VPN
  -f            foreground connect: same flow, echoes the raw OpenConnect log
  -d            background connect: MFA delivered via 'hkuvpn.ps1 --mfa CODE'
  --mfa CODE    send the 6-digit Authenticator code to a detached worker
  --check       pre-flight check (config, PIN file, tools, ports, cert pin)
  --status      layered health check (exit 0/2/3/4/5)
  --logs        follow the OpenConnect log
  --stop        stop the VPN, remove routes and NRPT rules

Routing model: unlike the Docker edition (where the whole container gets
its default route via the tunnel), the native port installs ONLY the split
routes the VPN server pushes (plus optional HKU_EXTRA_ROUTES). Proxied
requests to campus subnets go through HKU; everything else keeps using
your normal connection. Campus-only name resolution (*.hku.hk) is wired
through an NRPT rule pointing at the VPN's DNS servers.

Requires: Windows 10 1803+ (curl.exe), PowerShell 5.1, admin rights for
connect/stop (self-elevates), tools installed by get-tools.ps1.
#>

# --- console / TLS setup ---------------------------------------------------

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$ErrorActionPreference = 'Continue'

# --- paths and constants ----------------------------------------------------

$Script:VpnHome    = Split-Path -Parent $PSScriptRoot          # ...\hkuvpn\windows
$Script:ConfigDir  = if ($env:HKU_CONFIG_DIR) { $env:HKU_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.vpn' }
$Script:EnvFile    = Join-Path $Script:ConfigDir 'hku.env'
$Script:PassFile   = Join-Path $Script:ConfigDir 'hku.pass'
$Script:PinCache   = Join-Path $Script:ConfigDir 'pin-hk.cache'
$Script:ToolsDir   = Join-Path $Script:VpnHome 'tools'
$Script:VpncScript = Join-Path $Script:VpnHome 'etc\vpnc-script-win.js'

$Script:TempBase     = Join-Path $env:TEMP 'hkuvpn'
$Script:LogFile      = Join-Path $Script:TempBase 'openconnect.log'
$Script:GostLogFile  = Join-Path $Script:TempBase 'gost.log'
$Script:MarkerFile   = Join-Path $Script:TempBase 'markers.log'
$Script:PidFile      = Join-Path $Script:TempBase 'pids.txt'
$Script:StateFile    = Join-Path $Script:TempBase 'vpnc-state.txt'
$Script:ResponseFile = Join-Path $Script:TempBase 'response.txt'

# Auto-learned licensed-resource routes (HKU_AUTO_ROUTES=1), persisted
# across sessions as "base/prefix|lastseen-epoch|host" lines.
$Script:LearnedFile  = Join-Path $Script:ConfigDir 'learned-routes.txt'

$Script:VpnHost      = 'vpn2fa.hku.hk'
$Script:ControlHosts = @('vpn2fa.hku.hk', 'vpn2fa-a.hku.hk', 'vpn2fa-b.hku.hk')
$Script:EmptySha256Pin = '47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='
$Script:NrptTag      = 'hkuvpn'

# --- output helpers ---------------------------------------------------------

function Write-Info { param([string]$Text) Write-Host $Text }
function Write-Err  { param([string]$Text) Write-Host $Text -ForegroundColor Red }

function Write-Marker {
    param([string]$Text)
    try {
        $dir = Split-Path -Parent $Script:MarkerFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $Script:MarkerFile -Value ("{0} {1}" -f (Get-Date -Format s), $Text) -ErrorAction SilentlyContinue
    } catch {}
}

function Write-PidFile {
    param([int]$WorkerPid, [int]$OpenConnectPid, [int]$GostPid)
    try {
        $dir = Split-Path -Parent $Script:PidFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $Script:PidFile -Value @(
            "WORKER=$WorkerPid",
            "OPENCONNECT=$OpenConnectPid",
            "GOST=$GostPid"
        ) -ErrorAction Stop
    } catch {}
}

function Read-PidValue {
    param([string]$Key)
    if (-not (Test-Path $Script:PidFile)) { return 0 }
    $line = Get-Content $Script:PidFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
    if ($line) { return [int]($line.Substring($Key.Length + 1)) }
    return 0
}

function Read-StateValue {
    param([string]$Key)
    if (-not (Test-Path $Script:StateFile)) { return $null }
    $line = Get-Content $Script:StateFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
    if ($line) { return $line.Substring($Key.Length + 1) }
    return $null
}

# --- admin / elevation ------------------------------------------------------

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-RelaunchElevated {
    param([string[]]$ForwardArgs)
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($a in $ForwardArgs) { $parts += ('"{0}"' -f $a) }
    $parts += '"--Elevated"'
    Write-Info 'Requesting administrator rights (UAC prompt)...'
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ($parts -join ' ') -Verb RunAs | Out-Null
}

# --- small utilities --------------------------------------------------------

function Read-EnvFile {
    param([string]$Path)
    $table = @{}
    if (-not (Test-Path $Path)) { return $table }
    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $t.Substring(0, $eq).Trim()
        $val = $t.Substring($eq + 1).Trim()
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or
            ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $table[$key] = $val
    }
    return $table
}

function Test-PortFree {
    param([int]$Port)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $done = $iar.AsyncWaitHandle.WaitOne(400)
        if ($done -and $client.Connected) { return $false }
        return $true
    } catch {
        return $true
    } finally {
        $client.Close()
    }
}

function Invoke-DoH {
    param([string]$Name)
    foreach ($ep in @('1.1.1.1/dns-query', '8.8.8.8/resolve')) {
        try {
            $resp = Invoke-RestMethod -Uri ("https://{0}?name={1}&type=A" -f $ep, $Name) `
                -Headers @{ accept = 'application/dns-json' } -TimeoutSec 6 `
                -ErrorAction Stop
            $answer = $resp.Answer | Where-Object { $_.type -eq 1 } |
                Select-Object -First 1
            if ($answer -and $answer.data) { return [string]$answer.data }
        } catch {}
    }
    return $null
}

function Find-OpenConnect {
    if ($env:HKUVPN_OPENCONNECT -and (Test-Path $env:HKUVPN_OPENCONNECT)) {
        return $env:HKUVPN_OPENCONNECT
    }
    $candidates = @(
        (Join-Path $Script:ToolsDir 'openconnect.exe'),
        (Join-Path $env:ProgramFiles 'OpenConnect\openconnect.exe'),
        (Join-Path $env:ProgramFiles 'OpenConnect\bin\openconnect.exe'),
        # Legacy location: older get-tools.ps1 created <repo>\tools instead of
        # <repo>\windows\tools.
        (Join-Path (Split-Path -Parent $Script:VpnHome) 'tools\openconnect.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command openconnect.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-Gost {
    if ($env:HKUVPN_GOST -and (Test-Path $env:HKUVPN_GOST)) { return $env:HKUVPN_GOST }
    $candidates = @(
        (Join-Path $Script:ToolsDir 'gost.exe'),
        # Legacy location (see Find-OpenConnect).
        (Join-Path (Split-Path -Parent $Script:VpnHome) 'tools\gost.exe')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command gost.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# --- certificate pin (mirrors fetch_certificate_pin in docker/bin/hkuvpn) ---------

function Get-DerLengthBytes {
    param([int]$Length)
    if ($Length -lt 128) { return , [byte[]]@([byte]$Length) }
    $stack = New-Object System.Collections.Generic.List[byte]
    $n = $Length
    while ($n -gt 0) { $stack.Insert(0, [byte]($n -band 0xFF)); $n = $n -shr 8 }
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte](0x80 -bor $stack.Count))
    foreach ($b in $stack) { $out.Add($b) }
    return , $out.ToArray()
}

function New-DerTlv {
    param([byte]$Tag, [byte[]]$Content)
    $list = New-Object System.Collections.Generic.List[byte]
    $list.Add($Tag)
    $lenBytes = Get-DerLengthBytes $Content.Count
    foreach ($b in $lenBytes) { $list.Add($b) }
    foreach ($b in $Content) { $list.Add($b) }
    return , $list.ToArray()
}

function ConvertTo-DerOid {
    # "1.2.840.113549.1.1.1" -> DER OBJECT IDENTIFIER TLV
    param([string]$OidString)
    $arcs = $OidString.Split('.')
    $values = New-Object System.Collections.Generic.List[uint32]
    $values.Add([uint32]((40 * [int]$arcs[0]) + [int]$arcs[1]))
    for ($i = 2; $i -lt $arcs.Count; $i++) { $values.Add([uint32][int]$arcs[$i]) }
    $body = New-Object System.Collections.Generic.List[byte]
    foreach ($v in $values) {
        if ($v -lt 128) { $body.Add([byte]$v); continue }
        $stack = New-Object System.Collections.Generic.List[byte]
        $n = $v
        while ($n -gt 0) {
            $stack.Insert(0, [byte]($n -band 0x7F))
            $n = $n -shr 7
        }
        for ($j = 0; $j -lt $stack.Count - 1; $j++) {
            $body.Add([byte]($stack[$j] -bor 0x80))
        }
        $body.Add($stack[$stack.Count - 1])
    }
    return New-DerTlv 0x06 $body.ToArray()
}

function ConvertTo-DerSequence {
    param([byte[]]$Content)
    return New-DerTlv 0x30 $Content
}

function ConvertTo-DerBitString {
    param([byte[]]$Content)
    $list = New-Object System.Collections.Generic.List[byte]
    $list.Add([byte]0)   # no unused bits
    foreach ($b in $Content) { $list.Add($b) }
    return New-DerTlv 0x03 $list.ToArray()
}

function Get-SpkiDerFromCert {
    # Rebuild SubjectPublicKeyInfo = SEQ( SEQ(oid, params), BIT STRING(key) )
    # from the pieces .NET exposes on X509Certificate2.PublicKey.
    param($Cert)
    $oidRaw = ConvertTo-DerOid ([string]$Cert.PublicKey.Oid.Value)
    $paramsRaw = [byte[]]$Cert.PublicKey.EncodedParameters.RawData
    if ($paramsRaw.Count -eq 0 -and [string]$Cert.PublicKey.Oid.Value -eq '1.2.840.113549.1.1.1') {
        $paramsRaw = [byte[]](5, 0)   # NULL for RSA when .NET omits it
    }
    $alg = ConvertTo-DerSequence ($oidRaw + $paramsRaw)
    $key = [byte[]]$Cert.PublicKey.EncodedKeyValue.RawData
    return ConvertTo-DerSequence ($alg + (ConvertTo-DerBitString $key))
}

function Get-CertPin {
    # Returns "pin-sha256:..." for the TLS server $HostName, optionally
    # connecting to a pinned $ConnectIp to bypass polluted local DNS.
    param([string]$HostName, [string]$ConnectIp)
    $target = if ($ConnectIp) { $ConnectIp } else { $HostName }
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $tcp.Connect($target, 443)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false,
            { param($sender, $cert, $chain, $errors) $true })
        try {
            $ssl.AuthenticateAsClient($HostName)
            $cert2 = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
            $spki = Get-SpkiDerFromCert $cert2
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = $sha.ComputeHash($spki)
                return 'pin-sha256:' + [Convert]::ToBase64String($hash)
            } finally { $sha.Dispose() }
        } finally { $ssl.Dispose() }
    } catch {
        return $null
    } finally {
        $tcp.Close()
    }
}

function Get-ServerCertPin {
    # Cache-or-fetch wrapper; writes $Script:PinCache like docker/bin/hkuvpn.
    param([string]$PrimaryIp)
    $pin = $null
    if (Test-Path $Script:PinCache) {
        $pin = (Get-Content $Script:PinCache -Raw -ErrorAction SilentlyContinue) -replace "`r|`n", ''
    }
    $pattern = '^pin-sha256:[A-Za-z0-9+/]{43}=$'
    if (-not $pin -or $pin -notmatch $pattern -or $pin -eq ("pin-sha256:" + $Script:EmptySha256Pin)) {
        Write-Info ("Fetching the certificate pin for {0}..." -f $Script:VpnHost)
        $pin = Get-CertPin -HostName $Script:VpnHost -ConnectIp $PrimaryIp
        if (-not $pin -or $pin -notmatch $pattern) {
            throw "Could not obtain a valid certificate from $Script:VpnHost."
        }
        $dir = Split-Path -Parent $Script:PinCache
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $Script:PinCache -Value $pin -ErrorAction SilentlyContinue
    }
    return $pin
}

# --- NRPT management (campus-only DNS through the VPN resolvers) ------------

function Test-IpInPrefix {
    param([string]$Ip, [string]$Net, [int]$MaskLen)
    try {
        if ($MaskLen -eq 0) { return $true }
        if ($MaskLen -gt 32) { $MaskLen = 32 }
        $ipBytes  = ([Net.IPAddress]::Parse($Ip)).GetAddressBytes()
        $netBytes = ([Net.IPAddress]::Parse($Net)).GetAddressBytes()
        [Array]::Reverse($ipBytes); [Array]::Reverse($netBytes)
        $ipI  = [int64][BitConverter]::ToUInt32($ipBytes, 0)
        $netI = [int64][BitConverter]::ToUInt32($netBytes, 0)
        # Build the mask in positive 64-bit arithmetic. PowerShell's -shl
        # operator narrows its operand to 32 bits, and casting 0xFFFFFFFF to
        # [uint32] throws, so neither [uint32] nor -shl may be used here.
        $mask = [int64]4294967295 - ([int64][math]::Pow(2, 32 - $MaskLen) - 1)
        return (($ipI -band $mask) -eq ($netI -band $mask))
    } catch {
        return $false
    }
}

function Add-HkuNrptFromState {
    if (-not (Test-Path $Script:StateFile)) { return }
    $envMap = Read-EnvFile $Script:EnvFile
    if ([string]$envMap['HKU_NRPT'] -eq '0') {
        Write-Marker 'HKUVPN_NRPT_DISABLED'
        return
    }
    $domainsRaw = [string]$envMap['HKU_NRPT_DOMAINS']
    if (-not $domainsRaw) { $domainsRaw = 'hku.hk' }
    $domains = @($domainsRaw -split '[,\s]+' | Where-Object { $_ })
    $dns = (Read-StateValue 'DNS') -split '\s+' | Where-Object { $_ }
    if ($dns.Count -eq 0) {
        Write-Marker 'HKUVPN_NRPT_SKIPPED no-vpn-dns'
        return
    }
    # Safety: only use VPN resolvers that are actually reachable through a
    # pushed split route; otherwise *.hku.hk lookups would black-hole.
    $routes = @(Get-Content $Script:StateFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -like 'ROUTE=*' } | ForEach-Object {
            $p = $_.Substring(6).Split('/'); @{ Net = $p[0]; Len = [int]$p[1] }
        })
    $usable = @()
    foreach ($srv in $dns) {
        $covered = $false
        foreach ($r in $routes) {
            if (Test-IpInPrefix -Ip $srv -Net $r.Net -MaskLen $r.Len) { $covered = $true; break }
        }
        if ($covered) { $usable += $srv }
    }
    if ($usable.Count -eq 0) {
        Write-Marker 'HKUVPN_NRPT_SKIPPED dns-not-routed'
        return
    }
    try {
        foreach ($dom in $domains) {
            Add-DnsClientNrptRule -Namespace ".$dom" -NameServers $usable `
                -Comment $Script:NrptTag -ErrorAction Stop | Out-Null
        }
        Write-Marker ("HKUVPN_NRPT_ADDED servers={0}" -f ($usable -join ','))
    } catch {
        Write-Marker ("HKUVPN_NRPT_FAILED {0}" -f $_.Exception.Message)
    }
}

function Remove-HkuNrpt {
    try {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Comment -eq $Script:NrptTag -or $_.Comment -eq 'docker-vpn-hkuvpn' } |
            Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue
    } catch {}
}

# --- auto-learned routes (HKU-licensed resources on external networks) ------
#
# Windows has no policy routing, so per-process tunneling is impossible.
# What we CAN do automatically: every proxied connection is observable in
# gost's default (info-level) log as a `"... <-> host:port"` line that also
# carries the resolved `"dst"` IP. Whenever such a destination is NOT
# covered by the server-pushed campus subnets, we route its prefix (default
# /24) through the tunnel and remember it in %USERPROFILE%\.vpn\learned-
# routes.txt for future sessions. Result: proxied external resources start
# working on the SECOND request (refresh once for a brand-new site), and
# everything outside the proxy keeps using the physical adapter.

function Test-RoutablePublicIp {
    # Reject RFC1918/loopback/link-local/CGNAT/multicast and the 198.18.0.0/15
    # fake-IP range a rules client on the host may leak into proxy targets.
    param([string]$Ip)
    $p = @($Ip.Split('.'))
    if ($p.Count -ne 4) { return $false }
    $oct = @()
    foreach ($o in $p) {
        $v = 0
        if (-not [int]::TryParse($o, [ref]$v)) { return $false }
        if ($v -lt 0 -or $v -gt 255) { return $false }
        $oct += $v
    }
    $a, $b, $c = $oct[0], $oct[1], $oct[2]
    if ($a -eq 0 -or $a -eq 10 -or $a -eq 127) { return $false }
    if ($a -eq 169 -and $b -eq 254) { return $false }
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $false }
    if ($a -eq 192 -and $b -eq 168) { return $false }
    if ($a -eq 192 -and $b -eq 0 -and $c -eq 2) { return $false }
    if ($a -eq 198 -and ($b -eq 18 -or $b -eq 19)) { return $false }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return $false }
    if ($a -ge 224) { return $false }
    return $true
}

function Get-PrefixMaskDotted {
    param([int]$MaskLen)
    if ($MaskLen -le 0) { return '0.0.0.0' }
    if ($MaskLen -gt 32) { $MaskLen = 32 }
    # NOTE: 0xFFFFFFFF is [int]-1 in PowerShell, and casting a negative value
    # to [uint32] throws, so the mask is built in 64-bit arithmetic.
    $mask = ([int64]0xFFFFFFFF) -shl (32 - $MaskLen)
    return ('{0}.{1}.{2}.{3}' -f (($mask -shr 24) -band 255),
        (($mask -shr 16) -band 255), (($mask -shr 8) -band 255), ($mask -band 255))
}

function Get-NetPrefixBase {
    param([string]$Ip, [int]$MaskLen)
    if ($MaskLen -le 0) { return '0.0.0.0' }
    if ($MaskLen -gt 32) { $MaskLen = 32 }
    $b = ([Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    # 64-bit arithmetic: [uint32] casts of a negative int throw in PowerShell.
    $mask = ([int64]0xFFFFFFFF) -shl (32 - $MaskLen)
    $v = (([int64]$b[0] -shl 24) -bor ([int64]$b[1] -shl 16) -bor
          ([int64]$b[2] -shl 8) -bor ([int64]$b[3]))
    $v = $v -band $mask
    return ('{0}.{1}.{2}.{3}' -f (($v -shr 24) -band 255),
        (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255))
}

function Get-LearnedRoutes {
    if (-not (Test-Path $Script:LearnedFile)) { return @() }
    $out = @()
    foreach ($line in @(Get-Content $Script:LearnedFile -ErrorAction SilentlyContinue)) {
        $parts = @($line -split '\|')
        if ($parts.Count -lt 2) { continue }
        $net = @($parts[0] -split '/')
        if ($net.Count -ne 2) { continue }
        $prefix = 0
        if (-not [int]::TryParse($net[1], [ref]$prefix)) { continue }
        $seen = 0
        if (-not [int]::TryParse($parts[1], [ref]$seen)) { continue }
        $out += @{ Base = $net[0]; Prefix = $prefix; LastSeen = $seen;
                   Host = $(if ($parts.Count -ge 3) { $parts[2] } else { '' }) }
    }
    return ,$out
}

function Save-LearnedRoutes {
    param([array]$Entries)
    try {
        $dir = Split-Path -Parent $Script:LearnedFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lines = @($Entries | ForEach-Object {
            '{0}/{1}|{2}|{3}' -f $_.Base, $_.Prefix, $_.LastSeen, $_.Host
        })
        if ($lines.Count -gt 0) { Set-Content -Path $Script:LearnedFile -Value $lines }
        else { Set-Content -Path $Script:LearnedFile -Value '' }
    } catch {}
}

function Test-TargetCovered {
    param([string]$Ip, [array]$CoveredList)
    foreach ($c in $CoveredList) {
        if (Test-IpInPrefix -Ip $Ip -Net $c.Net -MaskLen $c.Len) { return $true }
    }
    return $false
}

function Add-TunnelRoute {
    param([string]$Base, [int]$MaskLen, [int]$TunIdx, [string]$TunIp)
    & route.exe add $Base mask (Get-PrefixMaskDotted $MaskLen) $TunIp metric 1 if $TunIdx 2>$null | Out-Null
}

function Add-LearnedTarget {
    param([string]$Ip, [string]$Label, [hashtable]$Lrn)
    if (-not (Test-RoutablePublicIp $Ip)) { return $null }
    if ($Lrn.Seen.ContainsKey($Ip)) { return $null }
    $Lrn.Seen[$Ip] = $true
    if (Test-TargetCovered -Ip $Ip -CoveredList $Lrn.Covered) { return $null }

    $base = Get-NetPrefixBase -Ip $Ip -MaskLen $Lrn.Cfg.RoutePrefix
    # Refresh TTL when the same prefix shows up again.
    for ($i = 0; $i -lt $Lrn.Entries.Count; $i++) {
        if ($Lrn.Entries[$i].Base -eq $base) {
            $Lrn.Entries[$i].LastSeen = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            Save-LearnedRoutes $Lrn.Entries
            return $null
        }
    }
    Add-TunnelRoute -Base $base -MaskLen $Lrn.Cfg.RoutePrefix `
        -TunIdx $Lrn.TunIdx -TunIp $Lrn.TunIp
    $Lrn.Covered += @{ Net = $base; Len = $Lrn.Cfg.RoutePrefix }
    $entry = @{ Base = $base; Prefix = $Lrn.Cfg.RoutePrefix;
                LastSeen = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); Host = $Label }
    $Lrn.Entries = @($Lrn.Entries + $entry)
    if ($Lrn.Entries.Count -gt $Lrn.Cfg.RouteMax) {
        $Lrn.Entries = @($Lrn.Entries | Sort-Object { $_.LastSeen } -Descending |
            Select-Object -First $Lrn.Cfg.RouteMax)
    }
    Save-LearnedRoutes $Lrn.Entries
    Write-Info ("autoroute: {0}/{1} now routed through the tunnel ({2})" -f $base, $Lrn.Cfg.RoutePrefix, $Label)
    Write-Marker ("HKUVPN_ROUTE_ADDED {0}/{1} <- {2}" -f $base, $Lrn.Cfg.RoutePrefix, $Label)
    return $entry
}

function Initialize-AutoRoutes {
    param([psobject]$Cfg)
    $idx = Read-StateValue 'TUNIDX'
    $tunip = Read-StateValue 'IP4'
    if (-not $idx -or -not $tunip) {
        Write-Marker 'HKUVPN_AUTOROUTE_NO_TUN'
        return
    }
    $lrn = @{ TunIdx = [int]$idx; TunIp = $tunip; Cfg = $Cfg; Seen = @{};
              Entries = @(); Covered = @() }

    # The campus subnets the server pushed are always covered.
    foreach ($line in @(Get-Content $Script:StateFile -ErrorAction SilentlyContinue)) {
        if ($line -like 'ROUTE=*') {
            $net = @($line.Substring(6).Split('/'))
            $len = 0
            if ($net.Count -eq 2 -and [int]::TryParse($net[1], [ref]$len)) {
                $lrn.Covered += @{ Net = $net[0]; Len = $len }
            }
        }
    }

    # Reload persisted entries: drop expired ones and ones the server now
    # covers, cap the total, then re-install the survivors.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $ttl = $Cfg.RouteTtl * 86400
    $entries = @()
    foreach ($e in (Get-LearnedRoutes)) {
        if (($now - $e.LastSeen) -gt $ttl) { continue }
        if (Test-TargetCovered -Ip $e.Base -CoveredList $lrn.Covered) { continue }
        $entries += $e
    }
    if ($entries.Count -gt $Cfg.RouteMax) {
        $entries = @($entries | Sort-Object { $_.LastSeen } -Descending |
            Select-Object -First $Cfg.RouteMax)
    }
    foreach ($e in $entries) {
        Add-TunnelRoute -Base $e.Base -MaskLen $e.Prefix -TunIdx $lrn.TunIdx -TunIp $lrn.TunIp
        $lrn.Covered += @{ Net = $e.Base; Len = $e.Prefix }
    }
    $lrn.Entries = $entries

    # Optional pre-seed: domains whose routes are installed BEFORE the
    # first request, so even the first connection goes through HKU.
    foreach ($d in $Cfg.ProxyDomains) {
        $ip = Invoke-DoH $d
        if ($ip) {
            $null = Add-LearnedTarget -Ip $ip -Label $d -Lrn $lrn
        } else {
            Write-Info ("autoroute preseed: could not resolve {0}" -f $d)
        }
    }
    Save-LearnedRoutes $lrn.Entries
    $Script:Lrn = $lrn
    Write-Marker ("HKUVPN_AUTOROUTE_ON entries={0} prefix=/{1}" -f $lrn.Entries.Count, $Cfg.RoutePrefix)
}

function Learn-FromGostLine {
    # gost (info level) logs each completed proxy connection as JSON with
    # "msg":"<client> <-> <target>" and the resolved "dst":"ip:port".
    param([string]$Line)
    if (-not $Script:Lrn) { return }
    if ($Line -notmatch ' <-> ') { return }
    if ($Line -notmatch '"dst"\s*:\s*"((?:\d{1,3}\.){3}\d{1,3}):\d+"') { return }
    $ip = $Matches[1]
    $label = $ip
    if ($Line -match '"host"\s*:\s*"([^"]+)"') { if ($Matches[1]) { $label = $Matches[1] } }
    $null = Add-LearnedTarget -Ip $ip -Label $label -Lrn $Script:Lrn
}

function Get-CompleteLines {
    # Split a StringBuilder into complete "\n"-terminated lines, leaving the
    # unterminated tail in place for the next round.
    param([System.Text.StringBuilder]$Buffer)
    $s = $Buffer.ToString()
    if ($s.Length -gt 131072) { $null = $Buffer.Clear(); return @() }  # junk guard
    $lastNl = $s.LastIndexOf("`n")
    if ($lastNl -lt 0) { return @() }
    $done = $s.Substring(0, $lastNl)
    $rest = $s.Substring($lastNl + 1)
    $null = $Buffer.Clear()
    [void]$Buffer.Append($rest)
    return @($done -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
}

function Remove-LearnedTunnelRoutes {
    # File-based so it also works from `--stop` in another process.
    foreach ($e in (Get-LearnedRoutes)) {
        & route.exe delete $e.Base 2>$null | Out-Null
    }
}

# --- disconnect cleanup -----------------------------------------------------

function Invoke-DisconnectScript {
    # Runs our vpnc-script with reason=disconnect using the persisted state,
    # mirroring what OpenConnect does on a graceful exit (belt and braces
    # for the cases where it was killed).
    if (-not (Test-Path $Script:VpncScript)) { return }
    if (-not (Test-Path $Script:StateFile)) { return }
    $old = @{}
    foreach ($k in @('reason', 'TUNIDX', 'INTERNAL_IP4_ADDRESS', 'HKU_STATE_FILE', 'HKU_LOG_FILE')) {
        $old[$k] = [Environment]::GetEnvironmentVariable($k)
    }
    try {
        $env:reason = 'disconnect'
        $env:TUNIDX = Read-StateValue 'TUNIDX'
        $env:INTERNAL_IP4_ADDRESS = Read-StateValue 'IP4'
        $env:HKU_STATE_FILE = $Script:StateFile
        $env:HKU_LOG_FILE = $Script:LogFile
        & cscript.exe //nologo $Script:VpncScript 2>$null | Out-Null
    } catch {
    } finally {
        foreach ($k in $old.Keys) {
            if ($null -ne $old[$k]) { Set-Item -Path "Env:$k" -Value $old[$k] }
            else { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-CleanupSession {
    param([bool]$RemovePidFile = $true)
    Invoke-DisconnectScript
    Remove-HkuNrpt
    Remove-LearnedTunnelRoutes
    foreach ($f in @($Script:ResponseFile, $Script:StateFile, $Script:MarkerFile, $Script:PidFile)) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
    if ($RemovePidFile) {
        Remove-Item $Script:PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Stop-TreeProcess {
    param([int]$Id)
    if ($Id -le 0) { return }
    try {
        $p = Get-Process -Id $Id -ErrorAction Stop
        Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
        Write-Info ("stopped pid {0} ({1})" -f $Id, $p.ProcessName)
    } catch {}
}

# --- pre-flight -------------------------------------------------------------

function Invoke-Preflight {
    $failures = 0
    $envMap = @{}
    $socksPort = 1080
    $httpPort = 1088

    if (Test-IsAdmin) {
        Write-Info 'admin    : ok'
    } else {
        Write-Info 'admin    : not elevated (connect self-elevates via UAC)'
    }

    if (-not (Test-Path $Script:EnvFile)) {
        Write-Err ("config   : missing ({0})" -f $Script:EnvFile)
        $failures++
    } else {
        $envMap = Read-EnvFile $Script:EnvFile
        $user = [string]$envMap['HKU_USER']
        if ($user -and $user -notlike 'youruid@*') {
            Write-Info ("config   : ok (HKU_USER={0})" -f $user)
        } else {
            Write-Err "config   : HKU_USER missing or still the placeholder in $Script:EnvFile"
            $failures++
        }
        if ($envMap['HKU_SOCKS_PORT']) { $socksPort = [int]$envMap['HKU_SOCKS_PORT'] }
        if ($envMap['HKU_HTTP_PORT']) { $httpPort = [int]$envMap['HKU_HTTP_PORT'] }
    }

    if (Test-Path $Script:PassFile) {
        $pinText = ''
        try { $pinText = (Get-Content $Script:PassFile -Raw -ErrorAction Stop).Trim() } catch {}
        if ($pinText) {
            Write-Info ("pin file : ok ({0})" -f $Script:PassFile)
        } else {
            Write-Err ("pin file : empty ({0})" -f $Script:PassFile)
            $failures++
        }
    } else {
        Write-Err ("pin file : missing ({0})" -f $Script:PassFile)
        $failures++
    }

    $oc = Find-OpenConnect
    if ($oc) { Write-Info ("openconn.: ok ({0})" -f $oc) }
    else {
        Write-Err 'openconn.: not found (run get-tools.ps1, or set HKUVPN_OPENCONNECT)'
        $failures++
    }

    $gost = Find-Gost
    if ($gost) { Write-Info ("gost     : ok ({0})" -f $gost) }
    else {
        Write-Err 'gost     : not found (run get-tools.ps1, or set HKUVPN_GOST)'
        $failures++
    }

    if (Test-Path $Script:VpncScript) {
        Write-Info 'script   : ok (etc\vpnc-script-win.js)'
    } else {
        Write-Err ("script   : missing ({0})" -f $Script:VpncScript)
        $failures++
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) { Write-Info 'curl.exe : ok' }
    else { Write-Info 'curl.exe : missing (status e2e check disabled; Windows 10 1803+ has it)' }

    # NOTE: PID 0 is the Windows System Idle process and Get-Process returns
    # it happily, so a missing pid file (Read-PidValue -> 0) must never be
    # treated as a live session.
    $ocPid = Read-PidValue 'OPENCONNECT'
    if ($ocPid -gt 0 -and (Get-Process -Id $ocPid -ErrorAction SilentlyContinue)) {
        Write-Info 'ports    : session appears to be running (hkuvpn.ps1 --status verifies health)'
    } elseif ((Test-PortFree $socksPort) -and (Test-PortFree $httpPort)) {
        Write-Info ("ports    : 127.0.0.1:{0} and {1} free" -f $socksPort, $httpPort)
    } else {
        if (-not (Test-PortFree $socksPort)) {
            Write-Err ("ports    : 127.0.0.1:{0} in use (set HKU_SOCKS_PORT in {1})" -f $socksPort, $Script:EnvFile)
        }
        if (-not (Test-PortFree $httpPort)) {
            Write-Err ("ports    : 127.0.0.1:{0} in use (set HKU_HTTP_PORT in {1})" -f $httpPort, $Script:EnvFile)
        }
        $failures++
    }

    if (Test-Path $Script:PinCache) {
        Write-Info 'cert pin : cached (reused at connect)'
    } else {
        Write-Info 'cert pin : not cached (fetched at connect)'
    }

    $autoOn = 'on'
    if ([string]$envMap['HKU_AUTO_ROUTES'] -eq '0') { $autoOn = 'off' }
    $learnedCount = 0
    if (Test-Path $Script:LearnedFile) {
        $learnedCount = @(Get-Content $Script:LearnedFile -ErrorAction SilentlyContinue).Count
    }
    Write-Info ("autoroute: {0} ({1} learned route(s) cached; external HKU resources are routed on demand)" -f $autoOn, $learnedCount)

    if ($failures -gt 0) {
        Write-Err ("result   : NOT ready - {0} problem(s) listed above" -f $failures)
        return 1
    }
    Write-Info 'result   : ready to connect (hkuvpn.ps1 or hkuvpn.ps1 -d)'
    return 0
}

# --- status -----------------------------------------------------------------

function Get-StatusText {
    $lines = @()

    $ocPid = Read-PidValue 'OPENCONNECT'
    $ocProc = if ($ocPid -gt 0) { Get-Process -Id $ocPid -ErrorAction SilentlyContinue } else { $null }
    if (-not $ocProc) {
        $lines += 'process  : not running'
        return @{ Text = $lines; Code = 2 }
    }
    $lines += 'process  : up'

    $tunIdx = Read-StateValue 'TUNIDX'
    $tunnelOk = $false
    if ($tunIdx) {
        $routes = Get-NetRoute -InterfaceIndex ([int]$tunIdx) -ErrorAction SilentlyContinue
        if ($routes) { $tunnelOk = $true }
    }
    if (-not $tunnelOk) {
        $lines += 'tunnel   : down (no routes on the tunnel interface; still authenticating, or the session failed)'
        return @{ Text = $lines; Code = 3 }
    }
    $lines += 'tunnel   : up (split routes active)'

    $socksPort = 1080
    $envMap = Read-EnvFile $Script:EnvFile
    if ($envMap['HKU_SOCKS_PORT']) { $socksPort = [int]$envMap['HKU_SOCKS_PORT'] }

    $client = New-Object Net.Sockets.TcpClient
    $proxyOk = $false
    try {
        $iar = $client.BeginConnect('127.0.0.1', $socksPort, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(400) -and $client.Connected) { $proxyOk = $true }
    } catch {} finally { $client.Close() }
    if (-not $proxyOk) {
        $lines += ("proxy    : down (nothing listening on 127.0.0.1:{0})" -f $socksPort)
        return @{ Text = $lines; Code = 4 }
    }
    $lines += ("proxy    : ok (127.0.0.1:{0})" -f $socksPort)

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        $lines += 'e2e      : unknown (curl.exe not available)'
        return @{ Text = $lines; Code = 0 }
    }
    $code = & curl.exe -s -m 15 -x "socks5h://127.0.0.1:$socksPort" `
        -o NUL -w '%{http_code}' 'https://www.hku.hk/' 2>$null
    $code = "$code".Trim()
    if ($code -match '^[23]') {
        $lines += ("e2e      : ok (https://www.hku.hk -> HTTP {0} through the HKU tunnel)" -f $code)
        return @{ Text = $lines; Code = 0 }
    }
    $lines += ("e2e      : failed (http={0})" -f ($(if ($code) { $code } else { 'none' })))
    $lines += '           if www.hku.hk is outside the pushed split routes, direct access is'
    $lines += '           expected; check with: hkuvpn.ps1 --logs'
    return @{ Text = $lines; Code = 5 }
}

function Invoke-ShowStatus {
    $s = Get-StatusText
    foreach ($l in $s.Text) { Write-Info $l }
    return $s.Code
}

# --- connect preparation ----------------------------------------------------

function Initialize-ConnectConfig {
    # Returns a config object or throws.
    if (-not (Test-Path $Script:EnvFile)) {
        throw "Missing configuration: $Script:EnvFile (copy windows\examples\hku.env.example and edit HKU_USER)"
    }
    $envMap = Read-EnvFile $Script:EnvFile
    $user = [string]$envMap['HKU_USER']
    if (-not $user -or $user -like 'youruid@*') { throw "Set a real HKU_USER in $Script:EnvFile." }
    $endpoint = [string]$envMap['HKU_ENDPOINT']
    if ($endpoint -and $endpoint -ne 'hk') {
        throw "Only the official HKUVPN server vpn2fa.hku.hk is supported (HKU_ENDPOINT=$endpoint)."
    }

    if (-not (Test-Path $Script:PassFile)) { throw "Missing password file: $Script:PassFile" }
    $pin = ''
    try { $pin = (Get-Content $Script:PassFile -Raw -ErrorAction Stop).Trim() } catch {}
    if (-not $pin) { throw "PIN file is empty: $Script:PassFile (static Portal PIN, not the 6-digit code)" }

    $oc = Find-OpenConnect
    if (-not $oc) { throw 'openconnect.exe not found; run windows\bin\get-tools.ps1 first.' }
    $gost = Find-Gost
    if (-not $gost) { throw 'gost.exe not found; run windows\bin\get-tools.ps1 first.' }
    if (-not (Test-Path $Script:VpncScript)) { throw "vpnc script missing: $Script:VpncScript" }

    # DoH resolution of the control endpoints (immune to fake-IP DNS).
    $resolveArgs = @()
    $primaryIp = $null
    $autoResolve = [string]$envMap['HKU_AUTO_RESOLVE']
    if ($autoResolve -ne '0') {
        Write-Info 'Resolving HKU control endpoints over DoH (immune to fake-IP DNS)...'
        foreach ($h in $Script:ControlHosts) {
            $ip = Invoke-DoH $h
            if ($ip) {
                $resolveArgs += ("--resolve={0}:{1}" -f $h, $ip)
                if ($h -eq $Script:VpnHost -and -not $primaryIp) { $primaryIp = $ip }
            } else {
                Write-Info ("DoH: could not resolve {0}" -f $h)
            }
        }
        if ($resolveArgs.Count -gt 0) {
            Write-Info ("Pinned for this session: {0}" -f (($resolveArgs -join ' ') -replace '--resolve=', ''))
        } else {
            Write-Info 'DoH resolution failed everywhere; continuing with normal DNS.'
        }
    }

    $serverCert = Get-ServerCertPin $primaryIp

    $cfg = New-Object psobject -Property @{
        User         = $user
        Pin          = $pin
        OpenConnect = $oc
        Gost         = $gost
        SocksPort    = 1080
        HttpPort     = 1088
        NoDtls       = ([string]$envMap['HKU_DTLS'] -eq '0')
        ResolveArgs  = $resolveArgs
        ServerCert   = $serverCert
        ExtraRoutes  = [string]$envMap['HKU_EXTRA_ROUTES']
        AutoRoutes   = ([string]$envMap['HKU_AUTO_ROUTES'] -ne '0')
        RoutePrefix  = 24
        RouteMax     = 512
        RouteTtl     = 14
        ProxyDomains = @()
    }
    if ($envMap['HKU_SOCKS_PORT']) { $cfg.SocksPort = [int]$envMap['HKU_SOCKS_PORT'] }
    if ($envMap['HKU_HTTP_PORT']) { $cfg.HttpPort = [int]$envMap['HKU_HTTP_PORT'] }
    $rp = 0
    if ([int]::TryParse([string]$envMap['HKU_AUTO_ROUTES_PREFIX'], [ref]$rp) -and $rp -ge 8 -and $rp -le 32) {
        $cfg.RoutePrefix = $rp
    }
    $rm = 0
    if ([int]::TryParse([string]$envMap['HKU_AUTO_ROUTES_MAX'], [ref]$rm) -and $rm -ge 1 -and $rm -le 10000) {
        $cfg.RouteMax = $rm
    }
    $rt = 0
    if ([int]::TryParse([string]$envMap['HKU_AUTO_ROUTES_TTL'], [ref]$rt) -and $rt -ge 1 -and $rt -le 365) {
        $cfg.RouteTtl = $rt
    }
    $pd = [string]$envMap['HKU_PROXY_DOMAINS']
    if ($pd) { $cfg.ProxyDomains = @($pd -split '[,\s]+' | Where-Object { $_ }) }
    return $cfg
}

# --- the tunnel worker ------------------------------------------------------

function New-PendingRead {
    # Starts a non-blocking read on a child's redirected stream.
    #
    # StreamReader.Peek()/Read() must NOT be used for this: on a redirected
    # pipe, Peek() blocks as soon as the buffered data is consumed, so a
    # "read everything available" loop never returns and the tunnel worker
    # stalls before it can look at the other stream. OpenConnect prints its
    # interactive prompts ("Password:", "Response:") on stderr, so a blocking
    # stdout read hides them completely.
    #
    # ReadAsync() + polling the task is the only safe way to watch a child's
    # output. Only one read may be in flight per stream, so the pending task
    # is kept and re-armed after every completed read.
    param($Reader)
    $buf = New-Object char[] 8192
    return @{
        Reader = $Reader
        Buf    = $buf
        Task   = $Reader.ReadAsync($buf, 0, $buf.Length)
        Eof    = $false
    }
}

function Read-PendingChars {
    # Moves whatever the child has already written into the buffer. Never
    # blocks: if the pending read has not completed, there is simply nothing
    # to collect yet.
    param($Pending, [System.Text.StringBuilder]$Buffer,
          [System.Text.StringBuilder]$Log, [bool]$Echo)
    if (-not $Pending -or $Pending.Eof) { return }
    if (-not $Pending.Task.IsCompleted) { return }
    try { $n = $Pending.Task.Result } catch { $Pending.Eof = $true; return }
    if ($n -le 0) { $Pending.Eof = $true; return }
    # Re-arm the next read before anything else, so the pipe keeps draining.
    $Pending.Task = $Pending.Reader.ReadAsync($Pending.Buf, 0, $Pending.Buf.Length)
    $chunk = New-Object System.Text.StringBuilder
    [void]$chunk.Append($Pending.Buf, 0, $n)
    $text = $chunk.ToString()
    [void]$Buffer.Append($text)
    [void]$Log.Append($text)
    if ($Echo) { Write-Host $text -NoNewline }
}

function Drain-PendingRead {
    # Collects the rest of a stream after the child exited (waits briefly).
    param($Pending, [System.Text.StringBuilder]$Buffer,
          [System.Text.StringBuilder]$Log, [bool]$Echo, [int]$TimeoutMs = 2000)
    if (-not $Pending) { return }
    if (-not $Pending.Eof -and $Pending.Task.IsCompleted) {
        Read-PendingChars $Pending $Buffer $Log $Echo
    }
    if (-not $Pending.Eof) {
        $null = $Pending.Task.Wait($TimeoutMs)
        Read-PendingChars $Pending $Buffer $Log $Echo
    }
}

function Find-AndConsume {
    param([System.Text.StringBuilder]$Buffer, [string]$Pattern)
    $s = $Buffer.ToString()
    $i = $s.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { return $false }
    $rest = $s.Substring($i + $Pattern.Length)
    $null = $Buffer.Clear()
    [void]$Buffer.Append($rest)
    return $true
}

function Get-MfaCode {
    param([bool]$Interactive, $OpenConnectProc)
    if ($Interactive) {
        $code = $null
        while (-not ("$code" -match '^\d{6}$')) {
            $code = Read-Host 'MFA code (6 digits from Authenticator)'
            if ("$code" -notmatch '^\d{6}$') { Write-Info 'Need exactly 6 digits, try again.' }
        }
        return "$code"
    }
    Write-Marker 'HKUVPN_MFA_RESPONSE_REQUIRED'
    Write-Info 'Waiting for the MFA response file (hkuvpn.ps1 --mfa <code>)...'
    while ($true) {
        if (Test-Path $Script:ResponseFile) {
            $c = ''
            try { $c = (Get-Content $Script:ResponseFile -Raw -ErrorAction Stop).Trim() } catch {}
            Remove-Item $Script:ResponseFile -Force -ErrorAction SilentlyContinue
            if ($c -match '^\d{6}$') { return $c }
            Write-Info 'Response file ignored (need exactly 6 digits); still waiting...'
        }
        if ($OpenConnectProc.HasExited) { return $null }
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-TunnelWorker {
    param([psobject]$Cfg, [string]$Mode, [bool]$EchoRaw, [bool]$InteractiveMfa)

    $dir = Split-Path -Parent $Script:LogFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Remove-Item $Script:MarkerFile, $Script:StateFile, $Script:ResponseFile `
        -Force -ErrorAction SilentlyContinue
    # Note: $Script:PidFile is NOT removed here. The --Worker bootstrap wrote
    # it to claim the session; Test-WorkerAlive relies on it, and it is
    # overwritten with the real child pids below.

    Write-Info ("Server: {0}" -f $Script:VpnHost)
    Write-Info ("Local proxies: SOCKS5=127.0.0.1:{0} HTTP=127.0.0.1:{1}" -f $Cfg.SocksPort, $Cfg.HttpPort)

    # gost: both proxy listeners in one process, bound to loopback only.
    $gostPsi = New-Object System.Diagnostics.ProcessStartInfo
    $gostPsi.FileName = $Cfg.Gost
    $gostPsi.Arguments = ('-L socks5://127.0.0.1:{0} -L http://127.0.0.1:{1}' -f $Cfg.SocksPort, $Cfg.HttpPort)
    $gostPsi.UseShellExecute = $false
    $gostPsi.CreateNoWindow = $true
    $gostPsi.RedirectStandardOutput = $true
    $gostPsi.RedirectStandardError = $true
    $gost = [System.Diagnostics.Process]::Start($gostPsi)

    # openconnect: the tunnel; our split-only vpnc-script does the routing.
    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Cfg.ResolveArgs) { $argList.Add($r) }
    if ($Cfg.NoDtls) { $argList.Add('--no-dtls') }
    $argList.Add("--user=$($Cfg.User)")
    $argList.Add('--useragent=AnyConnect')
    $argList.Add("--servercert=$($Cfg.ServerCert)")
    $argList.Add('--verbose')
    $argList.Add('--timestamp')
    $argList.Add('--reconnect-timeout=1800')
    $argList.Add('--no-external-auth')
    $argList.Add(('--script="{0}"' -f $Script:VpncScript))
    $argList.Add($Script:VpnHost)

    $ocPsi = New-Object System.Diagnostics.ProcessStartInfo
    $ocPsi.FileName = $Cfg.OpenConnect
    $ocPsi.Arguments = ($argList -join ' ')
    $ocPsi.UseShellExecute = $false
    $ocPsi.CreateNoWindow = $true
    $ocPsi.RedirectStandardInput = $true
    $ocPsi.RedirectStandardOutput = $true
    $ocPsi.RedirectStandardError = $true
    $ocPsi.EnvironmentVariables['HKU_EXTRA_ROUTES'] = [string]$Cfg.ExtraRoutes
    $ocPsi.EnvironmentVariables['HKU_STATE_FILE'] = $Script:StateFile
    $ocPsi.EnvironmentVariables['HKU_LOG_FILE'] = $Script:LogFile
    $oc = [System.Diagnostics.Process]::Start($ocPsi)

    Write-PidFile -WorkerPid $PID -OpenConnectPid $oc.Id -GostPid $gost.Id
    Write-Info ("started openconnect (pid {0}) and gost (pid {1})" -f $oc.Id, $gost.Id)

    $outBuf = New-Object System.Text.StringBuilder
    $errBuf = New-Object System.Text.StringBuilder
    $logAll = New-Object System.Text.StringBuilder
    # gost streams MUST be consumed: an unread redirected pipe fills its OS
    # buffer (a few KB) and gost would block forever. At the default info
    # level gost emits one JSON line per proxy connection with the resolved
    # "dst" IP, which feeds the auto-route learner.
    $gostBuf  = New-Object System.Text.StringBuilder
    $gostBufE = New-Object System.Text.StringBuilder
    $gostLog  = New-Object System.Text.StringBuilder
    $connected = $false
    $lastFlush = Get-Date
    $exitCode = 0

    try {
        # Non-blocking readers for all four child streams (see New-PendingRead).
        $ocOut  = New-PendingRead $oc.StandardOutput
        $ocErr  = New-PendingRead $oc.StandardError
        $gostOut = New-PendingRead $gost.StandardOutput
        $gostErr = New-PendingRead $gost.StandardError
        while (-not $oc.HasExited) {
            Read-PendingChars $ocOut   $outBuf   $logAll  $EchoRaw
            Read-PendingChars $ocErr   $errBuf   $logAll  $EchoRaw
            Read-PendingChars $gostOut $gostBuf  $gostLog $false
            Read-PendingChars $gostErr $gostBufE $gostLog $false
            foreach ($gl in (Get-CompleteLines $gostBuf)) { Learn-FromGostLine $gl }
            foreach ($gl in (Get-CompleteLines $gostBufE)) { Learn-FromGostLine $gl }

            # Portal PIN prompt (also re-answered when the auth form restarts).
            # Consume from BOTH streams: a leftover match in the other buffer
            # would re-trigger and send the PIN twice.
            $pwOut = Find-AndConsume $outBuf 'Password:'
            $pwErr = Find-AndConsume $errBuf 'Password:'
            if ($pwOut -or $pwErr) {
                $oc.StandardInput.WriteLine($Cfg.Pin)
                $oc.StandardInput.Flush()
                Write-Info 'Portal PIN sent; waiting for the MFA prompt...'
            }

            # MFA prompt; may reappear when a code was rejected or expired.
            $rsOut = Find-AndConsume $outBuf 'Response:'
            $rsErr = Find-AndConsume $errBuf 'Response:'
            if ($rsOut -or $rsErr) {
                $code = Get-MfaCode -Interactive $InteractiveMfa -OpenConnectProc $oc
                if (-not $code) { break }
                $oc.StandardInput.WriteLine($code)
                $oc.StandardInput.Flush()
                Write-Info 'MFA code sent; waiting for the tunnel...'
            }

            if (-not $connected -and
                (($outBuf.ToString().IndexOf('CSTP connected', [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                 ($errBuf.ToString().IndexOf('CSTP connected', [StringComparison]::OrdinalIgnoreCase) -ge 0))) {
                $connected = $true
                Write-Marker 'HKUVPN_CONNECTED'
                Write-Info 'Tunnel established; waiting for split routes...'
                for ($w = 0; $w -lt 20 -and -not (Test-Path $Script:StateFile); $w++) {
                    Start-Sleep -Milliseconds 250
                }
                Add-HkuNrptFromState
                if ($Cfg.AutoRoutes) { Initialize-AutoRoutes -Cfg $Cfg }
                if (Test-Path $Script:StateFile) {
                    Write-Info ("Connected - split routes installed (see hkuvpn.ps1 --logs)" )
                    $code2 = & curl.exe -s -m 15 -x "socks5h://127.0.0.1:$($Cfg.SocksPort)" `
                        -o NUL -w '%{http_code}' 'https://www.hku.hk/' 2>$null
                    $code2 = "$code2".Trim()
                    Write-Info ("e2e check: https://www.hku.hk -> HTTP {0}" -f ($(if ($code2) { $code2 } else { 'none' })))
                    Write-Info '  Check : hkuvpn.ps1 --status'
                    Write-Info '  Logs  : hkuvpn.ps1 --logs'
                    Write-Info '  Stop  : hkuvpn.ps1 --stop (or Ctrl+C in this window)'
                    Write-Marker ("HKUVPN_E2E http={0}" -f ($(if ($code2) { $code2 } else { 'none' })))
                } else {
                    Write-Err 'Tunnel is up but the vpnc-script did not report state; routing may be missing.'
                    Write-Marker 'HKUVPN_STATE_MISSING'
                }
            }

            # Bound buffer growth; keep the tail for pattern context.
            foreach ($b in @($outBuf, $errBuf)) {
                if ($b.Length -gt 16384) {
                    $tail = $b.ToString($b.Length - 8192, 8192)
                    $null = $b.Clear()
                    [void]$b.Append($tail)
                }
            }
            if (((Get-Date) - $lastFlush).TotalSeconds -ge 3) {
                try {
                    [IO.File]::AppendAllText($Script:LogFile, $logAll.ToString())
                    $null = $logAll.Clear()
                    if ($gostLog.Length -gt 0) {
                        [IO.File]::AppendAllText($Script:GostLogFile, $gostLog.ToString())
                        $null = $gostLog.Clear()
                    }
                } catch {}
                $lastFlush = Get-Date
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $oc.HasExited) { Wait-Process -Id $oc.Id -ErrorAction SilentlyContinue }
        try { $oc.Refresh(); $exitCode = $oc.ExitCode } catch {}
        Read-PendingChars $ocOut $outBuf $logAll $EchoRaw
        Read-PendingChars $ocErr $errBuf $logAll $EchoRaw
        Drain-PendingRead $ocOut   $outBuf   $logAll  $EchoRaw
        Drain-PendingRead $ocErr   $errBuf   $logAll  $EchoRaw
        Drain-PendingRead $gostOut $gostBuf  $gostLog $false
        Drain-PendingRead $gostErr $gostBufE $gostLog $false
        Write-Info ("openconnect exited with code {0}" -f $exitCode)
        Write-Marker ("HKUVPN_EXITED code={0}" -f $exitCode)
    }
    finally {
        if (-not $gost.HasExited) { Stop-Process -Id $gost.Id -Force -ErrorAction SilentlyContinue }
        if (-not $oc.HasExited) { Stop-Process -Id $oc.Id -Force -ErrorAction SilentlyContinue }
        try {
            if ($logAll.Length -gt 0) { [IO.File]::AppendAllText($Script:LogFile, $logAll.ToString()) }
            if ($gostLog.Length -gt 0) { [IO.File]::AppendAllText($Script:GostLogFile, $gostLog.ToString()) }
        } catch {}
        if ($Script:Lrn) {
            try { Save-LearnedRoutes $Script:Lrn.Entries } catch {}
        }
        Invoke-CleanupSession
    }
    return $exitCode
}

# --- detached worker bootstrap ----------------------------------------------

function Test-WorkerAlive {
    $wpid = Read-PidValue 'WORKER'
    if ($wpid -le 0) { return $false }
    $p = Get-Process -Id $wpid -ErrorAction SilentlyContinue
    return ($null -ne $p -and $p.ProcessName -match 'powershell')
}

function Start-DetachedWorker {
    param([string[]]$ForwardArgs)
    $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', ('"{0}"' -f $PSCommandPath), '"--Worker"')
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ($parts -join ' ') -WindowStyle Hidden -PassThru
    return $proc
}

function Wait-DetachedMarker {
    param([string[]]$WatchFor, [int]$Seconds)
    for ($i = 0; $i -lt ($Seconds * 2); $i++) {
        if (Test-Path $Script:MarkerFile) {
            $txt = ''
            try { $txt = Get-Content $Script:MarkerFile -Raw -ErrorAction Stop } catch {}
            foreach ($w in $WatchFor) {
                if ($txt -match $w) { return $w }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Invoke-DetachedConnect {
    if (Test-WorkerAlive) {
        Write-Info 'A detached worker is already running (hkuvpn.ps1 --status).'
        return 0
    }
    $null = Start-DetachedWorker
    Write-Info 'Detached worker started; waiting for the MFA prompt...'
    $hit = Wait-DetachedMarker -WatchFor @('HKUVPN_MFA_RESPONSE_REQUIRED', 'HKUVPN_CONNECTED', 'HKUVPN_EXITED') -Seconds 30
    switch ($hit) {
        'HKUVPN_MFA_RESPONSE_REQUIRED' {
            Write-Info 'Ready: the worker is waiting for the MFA code.'
            Write-Info '  Send code   : hkuvpn.ps1 --mfa <6-digit-code> (generate it now)'
        }
        'HKUVPN_CONNECTED' {
            Write-Info 'Connected without an MFA prompt (unexpected but fine).'
        }
        default {
            Write-Err 'No progress within 30s; inspect with: hkuvpn.ps1 --logs'
        }
    }
    Write-Info '  Follow logs : hkuvpn.ps1 --logs'
    Write-Info '  Stop        : hkuvpn.ps1 --stop'
    return 0
}

# --- mfa delivery -----------------------------------------------------------

function Send-MfaCode {
    param([string]$Code)
    if ($Code -notmatch '^\d{6}$') {
        Write-Err 'MFA code must be exactly 6 digits.'
        return 2
    }
    if (-not (Test-WorkerAlive)) {
        Write-Err 'No detached worker is running. Start it first: hkuvpn.ps1 -d'
        return 1
    }
    $dir = Split-Path -Parent $Script:ResponseFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Script:ResponseFile + '.tmp'
    Set-Content -Path $tmp -Value $Code -NoNewline -ErrorAction Stop
    Move-Item -Path $tmp -Destination $Script:ResponseFile -Force -ErrorAction Stop
    Write-Info 'MFA code delivered to the worker.'
    return 0
}

# --- usage ------------------------------------------------------------------

function Show-Usage {
    Write-Info @'
Usage: hkuvpn.ps1 [hk|-f|-d|--mfa CODE|--check|--status|--logs|--stop]

  (no arg)/hk  Smart connect: pre-flight, start the tunnel + proxies, prompt
               for the MFA code, wait until connected. Stays attached
  -f           Foreground connect: same flow, echoes the raw OpenConnect log
  -d           Background connect; deliver the code with --mfa (for scripts)
  --mfa CODE   Send the 6-digit Authenticator code to a detached worker
  --check      Pre-flight check. Exit 0 = ready
  --status     Layered health check. Exit codes: 0 ok, 2 process down,
               3 tunnel down, 4 proxy down, 5 e2e failed
  --logs       Follow the OpenConnect log
  --stop       Stop the VPN, remove routes and NRPT rules
'@
}

# --- entry ------------------------------------------------------------------

$command = ''
if ($args.Count -gt 0) { $command = [string]$args[0] }
$mfaCode = $null
if ($command -eq '--mfa') {
    if ($args.Count -lt 2) { Write-Err 'Usage: hkuvpn.ps1 --mfa <6-digit-code>'; exit 2 }
    $mfaCode = [string]$args[1]
}
$elevated = $false
$worker = $false
foreach ($a in $args) {
    if ("$a" -eq '--Elevated') { $elevated = $true }
    if ("$a" -eq '--Worker') { $worker = $true }
}

switch ($command) {
    '-h' { Show-Usage; exit 0 }
    '--help' { Show-Usage; exit 0 }
    '--mfa' { exit (Send-MfaCode $mfaCode) }
    '--check' { exit (Invoke-Preflight) }
    '--status' { exit (Invoke-ShowStatus) }
    '--logs' {
        if (-not (Test-Path $Script:LogFile)) {
            Write-Err "No log yet: $Script:LogFile"
            exit 1
        }
        Get-Content $Script:LogFile -Tail 40 -Wait
        exit 0
    }
    '--stop' {
        if (-not (Test-IsAdmin)) {
            Invoke-RelaunchElevated @('--stop')
            exit 0
        }
        $ocPid = Read-PidValue 'OPENCONNECT'
        $gostPid = Read-PidValue 'GOST'
        $wPid = Read-PidValue 'WORKER'
        Stop-TreeProcess $ocPid
        Stop-TreeProcess $gostPid
        Invoke-CleanupSession -RemovePidFile $false   # keep pids for the report above
        if ($wPid -gt 0 -and $wPid -ne $PID) { Stop-TreeProcess $wPid }
        Remove-Item $Script:PidFile -Force -ErrorAction SilentlyContinue
        Write-Info 'HKU VPN stopped.'
        exit 0
    }
    '' { }
    'hk' { }
    '-f' { }
    '--foreground' { }
    '-d' { }
    '--detach' { }
    default {
        if (-not $elevated -and -not $worker) {
            Write-Err ("Unknown argument: {0}" -f $command)
            Show-Usage
            exit 2
        }
        # Internal --Worker/--Elevated invocations fall through to the
        # connect logic below.
    }
}

$mode = 'smart'
switch ($command) {
    '-f' { $mode = 'foreground' }
    '--foreground' { $mode = 'foreground' }
    '-d' { $mode = 'detach' }
    '--detach' { $mode = 'detach' }
}
if ($worker) { $mode = 'detach' }

# Connect paths need admin (wintun adapter + routes). Self-elevate once.
if (-not (Test-IsAdmin)) {
    Invoke-RelaunchElevated @([string]$args[0])
    exit 0
}

if ($mode -eq 'detach') {
    if ($worker) {
        # Hidden background worker: holds the pipes, delivers MFA via file.
        try {
            $cfg = Initialize-ConnectConfig
            Write-PidFile -WorkerPid $PID -OpenConnectPid 0 -GostPid 0
            Invoke-TunnelWorker -Cfg $cfg -Mode 'detach' -EchoRaw $false -InteractiveMfa $false | Out-Null
            exit 0
        } catch {
            Write-Err $_.Exception.Message
            Write-Marker ('HKUVPN_EXITED error={0}' -f $_.Exception.Message)
            exit 1
        }
    }
    exit (Invoke-DetachedConnect)
}

# Smart / foreground (interactive console session).
try {
    $st = Get-StatusText
    if ($st.Code -eq 0) {
        Write-Info 'Already connected:'
        foreach ($l in $st.Text) { Write-Info $l }
        exit 0
    }
    $pre = Invoke-Preflight
    if ($pre -ne 0) { exit 1 }
    $cfg = Initialize-ConnectConfig
    $echo = ($mode -eq 'foreground')
    $rc = Invoke-TunnelWorker -Cfg $cfg -Mode $mode -EchoRaw $echo -InteractiveMfa $true
    exit $rc
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
