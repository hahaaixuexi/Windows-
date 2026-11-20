# ============================================================
#  DingBootNotify - send a DingTalk message when Windows boots
# ------------------------------------------------------------
#  This file is intentionally ASCII-only. That way it works
#  regardless of how it is saved (UTF-8 / ANSI / BOM) and
#  avoids the classic DingTalk errcode 310000 encoding trap.
#  All Chinese text lives in config.json, read as UTF-8.
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File DingBootNotify.ps1
#    powershell -ExecutionPolicy Bypass -File DingBootNotify.ps1 -DryRun
# ============================================================
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$script:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ScriptDir)) {
    $script:ScriptDir = (Get-Location).Path
}
$script:LogPath = Join-Path $script:ScriptDir 'logs\boot-notify.log'
$script:StateFile = Join-Path $script:ScriptDir 'state\pending-boot.txt'

function Write-Log {
    param([string]$Message)
    try {
        $logDir = Split-Path -Parent $script:LogPath
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $script:LogPath -Value "[$ts] $Message" -Encoding UTF8
    }
    catch { }
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$cfg.webhook)) {
        throw "config.json: 'webhook' is empty. Please fill in your DingTalk robot webhook."
    }
    return $cfg
}

function Get-DingUrl {
    param($Config)
    $url = [string]$Config.webhook
    $secret = [string]$Config.secret
    if ([string]::IsNullOrWhiteSpace($secret)) {
        return $url
    }
    # DingTalk "signed" robots: hmac-sha256(timestamp + "\n" + secret, secret)
    $ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $toSign = "$ts`n$secret"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($secret)
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($toSign))
    $sign = [Convert]::ToBase64String($hash)
    $encoded = [Uri]::EscapeDataString($sign)
    if ($url.Contains('?')) {
        return "$url&timestamp=$ts&sign=$encoded"
    }
    return "$url?timestamp=$ts&sign=$encoded"
}

function Test-Network {
    $targets = @('https://www.baidu.com', 'https://oapi.dingtalk.com')
    foreach ($target in $targets) {
        try {
            $null = Invoke-WebRequest -Uri $target -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            return $true
        }
        catch { }
    }
    return $false
}

function Send-DingMessage {
    param([string]$Content, $Config)
    if ($DryRun) {
        Write-Log "[DryRun] $Content"
        Write-Host $Content
        return $true
    }
    $payload = @{
        msgtype = 'text'
        text    = @{ content = $Content }
    } | ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        $url = Get-DingUrl -Config $Config
        $resp = Invoke-RestMethod -Uri $url -Method Post -Body $bytes `
            -ContentType 'application/json;charset=utf-8' -TimeoutSec 10 -ErrorAction Stop
        if ($resp.errcode -eq 0) {
            Write-Log 'DingTalk message sent.'
            return $true
        }
        Write-Log "DingTalk rejected: errcode=$($resp.errcode) errmsg=$($resp.errmsg)"
        return $false
    }
    catch {
        Write-Log "Send error: $($_.Exception.Message)"
        return $false
    }
}

function Format-Message {
    param([string]$Template, [string]$Device, [string]$BootTime, [string]$SendTime)
    if ([string]::IsNullOrWhiteSpace($Template)) { return '' }
    $text = $Template.Replace('{device}', $Device)
    $text = $text.Replace('{bootTime}', $BootTime)
    $text = $text.Replace('{sendTime}', $SendTime)
    return $text
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------
try {
    $config = Get-Config
}
catch {
    Write-Log "Fatal: $($_.Exception.Message)"
    exit 1
}

$deviceName = [string]$config.deviceName
if ([string]::IsNullOrWhiteSpace($deviceName)) {
    $deviceName = $env:COMPUTERNAME
}

$retryMax = 600
$retryStep = 5
try { if ($null -ne $config.retryMaxSeconds) { $retryMax = [int]$config.retryMaxSeconds } } catch { }
try { if ($null -ne $config.retryStepSeconds) { $retryStep = [int]$config.retryStepSeconds } } catch { }
if ($retryStep -lt 2) { $retryStep = 2 }
if ($retryMax -lt $retryStep) { $retryMax = $retryStep }

# Real boot time (falls back to "now" if WMI is unavailable)
$bootTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
try {
    $bootRaw = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    $bootTime = ([datetime]$bootRaw).ToString('yyyy-MM-dd HH:mm:ss')
}
catch { }

# A leftover state file means a previous boot could not reach the network
$pendingTime = $null
if (Test-Path -LiteralPath $script:StateFile) {
    try {
        $pendingTime = (Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8).Trim()
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($pendingTime)) { $pendingTime = $null }
}

$isPending = $false
if ($pendingTime) {
    $isPending = $true
    $bootTime = $pendingTime
}

Write-Log "Start. device=$deviceName bootTime=$bootTime pending=$isPending dryRun=$DryRun"

if (Test-Network) {
    $template = if ($isPending) { [string]$config.delayedTemplate } else { [string]$config.onlineTemplate }
    $message = Format-Message -Template $template -Device $deviceName `
        -BootTime $bootTime -SendTime (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    if (Send-DingMessage -Content $message -Config $config) {
        if (Test-Path -LiteralPath $script:StateFile) { Remove-Item -LiteralPath $script:StateFile -Force }
    }
    exit 0
}

# Offline: remember the boot time, then poll until the network is up
$stateDir = Split-Path -Parent $script:StateFile
if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}
$bootTime | Out-File -LiteralPath $script:StateFile -Encoding utf8 -Force
Write-Log "Network not ready. Boot time saved, waiting up to ${retryMax}s."

$waited = 0
while ($waited -lt $retryMax) {
    Start-Sleep -Seconds $retryStep
    $waited += $retryStep
    if (Test-Network) {
        $message = Format-Message -Template ([string]$config.delayedTemplate) -Device $deviceName `
            -BootTime $bootTime -SendTime (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        if (Send-DingMessage -Content $message -Config $config) {
            Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
        }
        break
    }
    if (($waited % 60) -eq 0) {
        Write-Log "Still offline after ${waited}s, keep waiting."
    }
}

if ($waited -ge $retryMax) {
    Write-Log "Gave up after ${retryMax}s. Boot time kept in state file for the next run."
}
exit 0
