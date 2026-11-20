# ============================================================
#  DingBootNotify 一键安装脚本
#  功能：复制脚本到安装目录 → 写入 config.json → 创建开机任务
#  用法：双击 install.cmd，或右键本文件“以管理员身份运行”
# ============================================================
param(
    [string]$InstallDir = '',
    [string]$Webhook = '',
    [string]$Secret = '',
    [string]$DeviceName = '',
    [string]$TaskName = 'DingBootNotify',
    [switch]$SkipTask,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# ---- 需要管理员权限：创建“开机运行”的系统任务 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '创建开机任务需要管理员权限，正在申请提权……' -ForegroundColor Yellow
    $reArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    if ($PSBoundParameters.ContainsKey('InstallDir') -and $InstallDir) { $reArgs += @('-InstallDir', "`"$InstallDir`"") }
    if ($PSBoundParameters.ContainsKey('Webhook') -and $Webhook) { $reArgs += @('-Webhook', "`"$Webhook`"") }
    if ($PSBoundParameters.ContainsKey('DeviceName') -and $DeviceName) { $reArgs += @('-DeviceName', "`"$DeviceName`"") }
    if ($PSBoundParameters.ContainsKey('TaskName') -and $TaskName) { $reArgs += @('-TaskName', "`"$TaskName`"") }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $reArgs
        exit 0
    }
    catch {
        Write-Host '提权被取消。请右键 install.ps1，选择“以管理员身份运行”。' -ForegroundColor Red
        exit 1
    }
}

$sourceDir = $PSScriptRoot

if (-not $InstallDir) {
    if (Test-Path 'D:\') {
        $InstallDir = 'D:\DingBootNotify'
    }
    else {
        $InstallDir = Join-Path $env:LOCALAPPDATA 'DingBootNotify'
    }
}

Write-Host ''
Write-Host '=== DingBootNotify 安装 ===' -ForegroundColor Cyan
Write-Host "安装目录：$InstallDir"

if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$needCopy = $true
try { $needCopy = ((Resolve-Path -LiteralPath $sourceDir).Path.TrimEnd('\') -ne (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd('\')) } catch { }
if ($needCopy) {
    foreach ($name in @('DingBootNotify.ps1', 'RunNotify.vbs')) {
        $src = Join-Path $sourceDir $name
        if (-not (Test-Path -LiteralPath $src)) {
            throw "安装包缺少文件：$src（请完整下载仓库）"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $name) -Force
    }
    Write-Host '已复制脚本文件。'
}

# ---- 生成 / 更新 config.json ----
$configPath = Join-Path $InstallDir 'config.json'
if (Test-Path -LiteralPath $configPath) {
    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
}
else {
    $example = Join-Path $sourceDir 'config.example.json'
    if (-not (Test-Path -LiteralPath $example)) { throw "安装包缺少文件：$example" }
    $configText = Get-Content -LiteralPath $example -Raw -Encoding UTF8
}
$config = $configText | ConvertFrom-Json

function Set-JsonStringValue {
    param([string]$Text, [string]$Key, [string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"[^"]*"'
    $replacement = '"' + $Key + '": "' + $escaped + '"'
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        return $replacement
    }
    return [regex]::Replace($Text, $pattern, $evaluator)
}

$currentWebhook = [string]$config.webhook
$placeholder = $currentWebhook -match 'YOUR_|替换|xxxx'

if (-not $Webhook) {
    if ($NonInteractive) {
        if ($placeholder -or [string]::IsNullOrWhiteSpace($currentWebhook)) {
            throw '未提供 Webhook。非交互模式请加参数 -Webhook "https://oapi.dingtalk.com/robot/send?access_token=..."'
        }
        $Webhook = $currentWebhook
    }
    else {
        $hint = if ($currentWebhook -and -not $placeholder) { "（直接回车沿用当前值）" } else { '' }
        do {
            $answer = Read-Host "请粘贴钉钉机器人 Webhook$hint"
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $currentWebhook }
            if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match 'YOUR_|替换|xxxx') {
                Write-Host 'Webhook 不能为空，也不能是示例占位符。' -ForegroundColor Yellow
            }
        } while ([string]::IsNullOrWhiteSpace($answer) -or $answer -match 'YOUR_|替换|xxxx')
        $Webhook = $answer.Trim()
    }
}

if (-not $Secret -and -not $NonInteractive) {
    $ans = Read-Host '机器人若开启了“加签”，粘贴 SEC 开头的密钥（没有就直接回车跳过）'
    if (-not [string]::IsNullOrWhiteSpace($ans)) { $Secret = $ans.Trim() }
}

if (-not $DeviceName -and -not $NonInteractive) {
    $ans = Read-Host "设备名称（直接回车用电脑名 $env:COMPUTERNAME）"
    if (-not [string]::IsNullOrWhiteSpace($ans)) { $DeviceName = $ans.Trim() }
}

if ($Webhook) { $configText = Set-JsonStringValue -Text $configText -Key 'webhook' -Value $Webhook }
if ($Secret) { $configText = Set-JsonStringValue -Text $configText -Key 'secret' -Value $Secret }
if ($DeviceName) { $configText = Set-JsonStringValue -Text $configText -Key 'deviceName' -Value $DeviceName }

Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8
Write-Host '已写入 config.json。'

# ---- 创建开机任务（SYSTEM 账户，无需登录） ----
if (-not $SkipTask) {
    $vbsPath = Join-Path $InstallDir 'RunNotify.vbs'
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已移除同名旧任务：$TaskName"
    }
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description '开机自动发送钉钉通知（DingBootNotify）' | Out-Null
    Write-Host "已创建开机任务：$TaskName（SYSTEM 账户，开机即运行，无需登录）"
}

Write-Host ''
Write-Host '=== 安装完成 ===' -ForegroundColor Green
Write-Host "脚本目录：$InstallDir"
Write-Host "配置文件：$configPath"
Write-Host "运行日志：$(Join-Path $InstallDir 'logs\boot-notify.log')"

if (-not $SkipTask -and -not $NonInteractive) {
    $ans = Read-Host '现在发送一条测试消息？(Y/n)'
    if ($ans -eq '' -or $ans -match '^[Yy]') {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 4
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "任务已触发，请查看钉钉群。上次运行结果代码：$($info.LastTaskResult)"
    }
}

Write-Host ''
Write-Host '下一步：重启电脑做整机验证（开机后 30-60 秒内应收到消息）。按回车退出。'
[void](Read-Host)
