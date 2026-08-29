# EPM Automate installer for Windows PowerShell (no Git / sh required).
#   irm https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.ps1 | iex
#
# Same Cloud EPM download as install.sh. Launches the GUI exe; you walk through it.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Version = '1.0.0'
$UserAgent = "epmautomate-install/${Version}"
$MinBytes = 102400

function Write-Info([string]$Message) { Write-Host "==> $Message" }
function Write-Err([string]$Message) { Write-Host "error: $Message" -ForegroundColor Red }

function Get-EnvOr([string]$Name, [string]$Fallback = '') {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Fallback }
    return $v.Trim()
}

$EpmUrl = Get-EnvOr 'EPM_URL'
$EpmUser = Get-EnvOr 'EPM_USER'
$EpmPassword = Get-EnvOr 'EPM_PASSWORD'
$EpmToken = Get-EnvOr 'EPM_TOKEN'
$EpmInstaller = Get-EnvOr 'EPM_INSTALLER'

function Test-HasCreds {
    return (-not [string]::IsNullOrWhiteSpace($EpmToken)) -or
        ((-not [string]::IsNullOrWhiteSpace($EpmUser)) -and (-not [string]::IsNullOrWhiteSpace($EpmPassword)))
}

function Get-NormalizedBase([string]$Url) {
    $u = $Url.Trim().TrimEnd('/')
    foreach ($suffix in @('/epmcloud', '/HyperionPlanning', '/workspace')) {
        if ($u.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
            $u = $u.Substring(0, $u.Length - $suffix.Length)
        }
    }
    return $u.TrimEnd('/')
}

function Test-IsWindowsExe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt $MinBytes) { return $false }
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 96
        $n = $fs.Read($buf, 0, $buf.Length)
        if ($n -lt 2) { return $false }
        if ($buf[0] -ne 0x4D -or $buf[1] -ne 0x5A) { return $false }
        $head = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        if ($head -match '(?i)<html|<!doctype|<\?xml') { return $false }
        if ($head.StartsWith('{') -or $head.StartsWith('[')) { return $false }
        return $true
    } finally {
        $fs.Close()
    }
}

function Get-CandidateUrls([string]$Base) {
    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($Base, "$Base/epmcloud", "$Base/HyperionPlanning")) {
        foreach ($u in @(
            "$root/interop/rest/11.1.2.3.600/epmautomate?os=windows",
            "$root/interop/rest/11.1.2.3.600/epmautomate?os=win",
            "$root/interop/rest/11.1.2.3.600/epmautomate?platform=windows",
            "$root/interop/rest/v1/epmautomate?os=windows",
            "$root/interop/rest/v1/epmautomate?platform=windows",
            "$root/interop/rest/v2/epmautomate?os=windows",
            "$root/download/epmautomate/windows",
            "$root/download?product=epmautomate&platform=windows",
            "$root/HyperionPlanning/download/epmautomate/windows",
            "$root/epmautomate/windows/EPM%20Automate.exe",
            "$root/epmautomate/windows/EPMAutomate.exe",
            "$root/epmautomate/EPM%20Automate.exe",
            "$root/epmautomate/EPMAutomate.exe",
            "$root/epmstatic/epmautomate/EPM%20Automate.exe",
            "$root/epmstatic/epmautomate/EPMAutomate.exe"
        )) {
            if (-not $urls.Contains($u)) { $urls.Add($u) }
        }
    }
    return $urls
}

function Get-AuthHeaders {
    $h = @{
        'User-Agent' = $UserAgent
        'Accept'      = 'application/octet-stream,*/*'
    }
    if (-not [string]::IsNullOrWhiteSpace($EpmToken)) {
        $h['Authorization'] = "Bearer $EpmToken"
    } elseif ((-not [string]::IsNullOrWhiteSpace($EpmUser)) -and (-not [string]::IsNullOrWhiteSpace($EpmPassword))) {
        $pair = "${EpmUser}:${EpmPassword}"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        $h['Authorization'] = "Basic $b64"
    }
    return $h
}

function Save-UrlToFile([string]$Url, [string]$Dest, [bool]$UseAuth) {
    $headers = @{
        'User-Agent' = $UserAgent
        'Accept'      = 'application/octet-stream,*/*'
    }
    if ($UseAuth) {
        $headers = Get-AuthHeaders
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -Headers $headers -TimeoutSec 120
        return $true
    } catch {
        return $false
    }
}

function Find-Installer([string]$Dest, [string]$Base) {
    $urls = @(Get-CandidateUrls $Base)
    $n = $urls.Count
    $tryAuthFirst = Test-HasCreds
    if ($tryAuthFirst) {
        $rounds = @($true)
    } else {
        $rounds = @($false, $true)
    }

    foreach ($useAuth in $rounds) {
        if ($useAuth -and -not (Test-HasCreds)) { continue }
        if ($useAuth) { Write-Info 'retrying download with credentials' }
        else { Write-Info 'downloading EPM Automate (windows)' }
        $i = 0
        foreach ($url in $urls) {
            $i++
            Write-Host ("    [{0}/{1}] {2}" -f $i, $n, $url)
            if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
            if ((Save-UrlToFile $Url $Dest $useAuth) -and (Test-IsWindowsExe $Dest)) {
                Write-Info "using $url"
                return $true
            }
        }
        if ($useAuth) { break }
        if (-not (Test-HasCreds)) {
            Write-Info 'anonymous download did not return an installer; Cloud EPM credentials are required'
            if ([string]::IsNullOrWhiteSpace($EpmUser)) {
                $script:EpmUser = Read-Host 'EPM user'
            }
            if ([string]::IsNullOrWhiteSpace($EpmPassword)) {
                $sec = Read-Host 'EPM password' -AsSecureString
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
                try {
                    $script:EpmPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                } finally {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }
        }
    }
    return $false
}

function Start-InstallerGui([string]$Exe) {
    Write-Info 'launching Windows installer (accept UAC, then walk through the GUI)'
    try {
        Start-Process -LiteralPath $Exe -Verb RunAs
    } catch {
        Start-Process -LiteralPath $Exe
    }
    Write-Host @'

The EPM Automate GUI installer is running.
Default location: Program Files\Oracle\EPM Automate
After it finishes, open an elevated Command Prompt and run:

    epmautomate upgrade

so the client matches the latest Cloud EPM release.
'@
}

# --- main ---

Write-Info 'detected Windows'

if (-not [string]::IsNullOrWhiteSpace($EpmInstaller)) {
    if (-not (Test-Path -LiteralPath $EpmInstaller)) {
        Write-Err "installer not found: $EpmInstaller"
        exit 1
    }
    if (-not (Test-IsWindowsExe $EpmInstaller)) {
        Write-Err "$EpmInstaller is not a valid Windows EPM Automate installer"
        exit 1
    }
    Start-InstallerGui $EpmInstaller
    return
}

if ([string]::IsNullOrWhiteSpace($EpmUrl)) {
    $EpmUrl = Read-Host 'Cloud EPM URL'
}
if ([string]::IsNullOrWhiteSpace($EpmUrl)) {
    Write-Err 'EPM_URL is required (example: https://epm-xxx.epm.region.ocs.oraclecloud.com/epmcloud)'
    exit 1
}

$base = Get-NormalizedBase $EpmUrl
Write-Info "Cloud EPM: $base"

$dest = Join-Path $env:TEMP 'EPM Automate.exe'
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }

if (-not (Find-Installer $dest $base)) {
    Write-Err @'
could not download a valid EPM Automate installer from Cloud EPM.

Oracle only publishes the client on each environment's Downloads page
(Settings and Actions > Downloads). There is no public CDN.

Download it in a browser, then re-run with:
  $env:EPM_INSTALLER = 'C:\path\to\EPM Automate.exe'
  irm https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.ps1 | iex

Basic auth cannot be used with MFA accounts.
'@
    exit 1
}

Start-InstallerGui $dest
