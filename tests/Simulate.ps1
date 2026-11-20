# ============================================================
#  DingBootNotify 模拟测试
# ------------------------------------------------------------
#  在临时沙箱里复制一份脚本，用本地假钉钉服务器接收消息。
#  · 不读取、不覆盖真实 config.json
#  · 不向真实钉钉群发送任何消息
#  · 使用独立的测试任务名，结束后自动删除
#  · 沙箱目录测完自动清理（-KeepSandbox 可保留）
#
#  运行： powershell -ExecutionPolicy Bypass -File tests\Simulate.ps1
# ============================================================
param(
    [int]$Port = 18080,
    [switch]$SkipTaskTest,
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$sandbox = Join-Path $env:TEMP "DingBootNotify-sim-$runId"
$mockScript = Join-Path $PSScriptRoot 'MockDingTalk.py'
$mockLog = Join-Path $sandbox 'received.jsonl'
$mockOut = Join-Path $sandbox 'mock.out'
$mockErr = Join-Path $sandbox 'mock.err'
$taskName = 'DingBootNotify_SimTest'

$mockProc = $null
$taskRegistered = $false
$exitCode = 0
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.Add([pscustomobject]@{
            Name   = $Name
            Result = $(if ($Pass) { 'PASS' } else { 'FAIL' })
            Detail = $Detail
        })
}

function Get-Posts {
    if (-not (Test-Path -LiteralPath $mockLog)) { return }
    foreach ($line in (Get-Content -LiteralPath $mockLog -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.method -eq 'POST') { $obj }
        }
        catch { }
    }
}

function Wait-ForPosts {
    param([int]$Expected, [int]$TimeoutSeconds = 25)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-Posts).Count -ge $Expected) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Write-TestConfig {
    param(
        [string]$FileName,
        [string]$Webhook,
        [object[]]$Probes,
        [string]$Secret = '',
        [int]$RetryMax = 600,
        [int]$RetryStep = 5
    )
    $cfg = [ordered]@{
        webhook          = $Webhook
        secret           = $Secret
        deviceName       = '模拟-台式机'
        onlineTemplate   = "【开机提醒】{device} 已开机`n开机时间：{bootTime}`n发送时间：{sendTime}"
        delayedTemplate  = "【开机提醒】{device} 延迟推送`n记录开机时间：{bootTime}`n联网发送时间：{sendTime}"
        retryMaxSeconds  = $RetryMax
        retryStepSeconds = $RetryStep
        networkProbeUrls = $Probes
    }
    $path = Join-Path $sandbox $FileName
    $json = $cfg | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Invoke-NotifyScript {
    param([string]$ConfigPath)
    $scriptPath = Join-Path $sandbox 'DingBootNotify.ps1'
    $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath -ConfigPath $ConfigPath 2>&1
    return [int]$LASTEXITCODE
}

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'DingBootNotify.ps1') -Destination $sandbox
    Copy-Item -LiteralPath (Join-Path $repoRoot 'RunNotify.vbs') -Destination $sandbox

    Write-Host "沙箱：$sandbox"
    $mockProc = Start-Process -FilePath 'python' `
        -ArgumentList @(('"' + $mockScript + '"'), $Port, ('"' + $mockLog + '"')) `
        -WindowStyle Hidden -RedirectStandardOutput $mockOut -RedirectStandardError $mockErr -PassThru

    $ready = $false
    for ($i = 0; $i -lt 50; $i++) {
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/ping" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
            $ready = $true
            break
        }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) {
        throw "假钉钉服务器启动失败，端口 $Port 不可用。"
    }

    # ---------------- 场景 1：联网开机，立即推送 ----------------
    $cfgOnline = Write-TestConfig -FileName 'config.online.json' `
        -Webhook "http://127.0.0.1:$Port/robot/send?access_token=SIM" `
        -Probes @("http://127.0.0.1:$Port/ping")
    $before = @(Get-Posts).Count
    $code = Invoke-NotifyScript -ConfigPath $cfgOnline
    Start-Sleep -Milliseconds 500
    $posts = @(Get-Posts)
    $new = @($posts | Select-Object -Skip $before)
    if ($new.Count -eq 1 -and $code -eq 0) {
        try {
            $body = $new[0].body | ConvertFrom-Json
            $content = [string]$body.text.content
            $pass = ($body.msgtype -eq 'text') -and
                    ($content -match '【开机提醒】') -and
                    ($content -match '模拟-台式机') -and
                    ($content -match '已开机') -and
                    ($content -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}') -and
                    (($content -split "`n").Count -ge 3)
            Add-Result '联网开机立即推送' $pass "收到 $($new.Count) 条；内容：$($content -replace "`n", ' / ')"
        }
        catch {
            Add-Result '联网开机立即推送' $false "消息 JSON 解析失败：$($_.Exception.Message)"
        }
    }
    else {
        Add-Result '联网开机立即推送' $false "期望 1 条消息、退出码 0；实际 $($new.Count) 条、退出码 $code"
    }

    # ---------------- 场景 2：断网，落盘等待 ----------------
    $cfgOffline = Write-TestConfig -FileName 'config.offline.json' `
        -Webhook "http://127.0.0.1:$Port/robot/send?access_token=SIM" `
        -Probes @('http://127.0.0.1:1') -RetryMax 6 -RetryStep 2
    $before = @(Get-Posts).Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-NotifyScript -ConfigPath $cfgOffline
    $sw.Stop()
    Start-Sleep -Milliseconds 300
    $stateFile = Join-Path $sandbox 'state\pending-boot.txt'
    $logFile = Join-Path $sandbox 'logs\boot-notify.log'
    $stateExists = Test-Path -LiteralPath $stateFile
    $noNewPosts = (@(Get-Posts).Count -eq $before)
    $logOk = (Test-Path -LiteralPath $logFile) -and ((Get-Content -LiteralPath $logFile -Raw -Encoding UTF8) -match 'Network not ready')
    $pass = $stateExists -and $noNewPosts -and $logOk -and ($sw.Elapsed.TotalSeconds -ge 4)
    Add-Result '断网时记录开机时间' $pass "状态文件=$stateExists，未发消息=$noNewPosts，耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1))s"

    # ---------------- 场景 3：联网后补发并清理记录 ----------------
    $savedTime = if ($stateExists) { (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8).Trim() } else { '' }
    $cfgResume = Write-TestConfig -FileName 'config.resume.json' `
        -Webhook "http://127.0.0.1:$Port/robot/send?access_token=SIM" `
        -Probes @("http://127.0.0.1:$Port/ping")
    $before = @(Get-Posts).Count
    $code = Invoke-NotifyScript -ConfigPath $cfgResume
    Start-Sleep -Milliseconds 500
    $new = @(@(Get-Posts) | Select-Object -Skip $before)
    $stateAfter = Test-Path -LiteralPath $stateFile
    if ($new.Count -eq 1 -and $code -eq 0) {
        $body = $new[0].body | ConvertFrom-Json
        $content = [string]$body.text.content
        $pass = ($content -match '延迟推送') -and ($content.Contains($savedTime)) -and (-not $stateAfter)
        Add-Result '联网后补发并删除记录' $pass "记录时间=$savedTime；状态文件残留=$stateAfter"
    }
    else {
        Add-Result '联网后补发并删除记录' $false "期望 1 条延迟消息；实际 $($new.Count) 条、退出码 $code"
    }

    # ---------------- 场景 4：VBS 静默启动 ----------------
    $cfgVbs = Write-TestConfig -FileName 'config.json' `
        -Webhook "http://127.0.0.1:$Port/robot/send?access_token=SIM" `
        -Probes @("http://127.0.0.1:$Port/ping")
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
    $before = @(Get-Posts).Count
    $vbsPath = Join-Path $sandbox 'RunNotify.vbs'
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbsPath + '"') | Out-Null
    $got = Wait-ForPosts -Expected ($before + 1) -TimeoutSeconds 30
    $new = @(@(Get-Posts) | Select-Object -Skip $before)
    $vbsMsgOk = $false
    if ($new.Count -ge 1) {
        $body = $new[0].body | ConvertFrom-Json
        $vbsMsgOk = ([string]$body.text.content).Contains('已开机')
    }
    Add-Result 'VBS 隐藏窗口启动' ($got -and $vbsMsgOk) "30 秒内收到=$got，内容正确=$vbsMsgOk"

    # ---------------- 场景 5：加签 URL ----------------
    $secret = 'SECSIM2026TEST'
    $cfgSign = Write-TestConfig -FileName 'config.sign.json' `
        -Webhook "http://127.0.0.1:$Port/robot/send?access_token=SIM" `
        -Probes @("http://127.0.0.1:$Port/ping") -Secret $secret
    $before = @(Get-Posts).Count
    $code = Invoke-NotifyScript -ConfigPath $cfgSign
    Start-Sleep -Milliseconds 500
    $new = @(@(Get-Posts) | Select-Object -Skip $before)
    if ($new.Count -eq 1) {
        $path = [string]$new[0].path
        $mTs = [regex]::Match($path, 'timestamp=([0-9]+)')
        $mSign = [regex]::Match($path, 'sign=([^&]+)')
        $ts = $mTs.Groups[1].Value
        $sign = if ($mSign.Success) { [Uri]::UnescapeDataString($mSign.Groups[1].Value) } else { '' }
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($secret)
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$ts`n$secret"))
        $expected = [Convert]::ToBase64String($hash)
        $pass = $mTs.Success -and $mSign.Success -and ($sign -eq $expected) -and ($path -match 'access_token=SIM')
        Add-Result '加签签名正确' $pass "timestamp=$ts，签名匹配=$($sign -eq $expected)"
    }
    else {
        Add-Result '加签签名正确' $false "未收到签名消息（$($new.Count) 条）"
    }

    # ---------------- 场景 6：任务计划端到端 ----------------
    if (-not $SkipTaskTest) {
        try {
            $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            }
            $cfgTask = Write-TestConfig -FileName 'config.json' `
                -Webhook "http://127.0.0.1:$Port/robot/send?access_token=SIM" `
                -Probes @("http://127.0.0.1:$Port/ping")
            if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }

            $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbsPath + '"')
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal `
                -Description 'DingBootNotify simulation task' | Out-Null
            $taskRegistered = $true

            $xml = Export-ScheduledTask -TaskName $taskName
            $hasBootTrigger = $xml -match '<BootTrigger'

            $before = @(Get-Posts).Count
            Start-ScheduledTask -TaskName $taskName
            $got = Wait-ForPosts -Expected ($before + 1) -TimeoutSeconds 35
            Add-Result '开机任务端到端（BootTrigger）' ($hasBootTrigger -and $got) "包含 BootTrigger=$hasBootTrigger，收到消息=$got"
        }
        catch {
            Add-Result '开机任务端到端（BootTrigger）' $false "无法创建测试任务（可能权限不足）：$($_.Exception.Message)"
        }
        finally {
            if ($taskRegistered) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                $taskRegistered = $false
            }
        }
    }
    else {
        Add-Result '开机任务端到端（BootTrigger）' $true '已按参数跳过'
    }
}
catch {
    Add-Result '测试框架' $false $_.Exception.Message
}
finally {
    if ($taskRegistered) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($mockProc -and -not $mockProc.HasExited) {
        Stop-Process -Id $mockProc.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 300
    if (-not $KeepSandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '================ 模拟测试结果 ================'
$results | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failed -eq 0) {
    Write-Host "全部通过（$($results.Count)/$($results.Count)）。真实系统未做任何修改。" -ForegroundColor Green
}
else {
    Write-Host "$failed 项失败。" -ForegroundColor Red
    $exitCode = 1
}
if ($KeepSandbox) {
    Write-Host "沙箱保留在：$sandbox"
}
exit $exitCode
