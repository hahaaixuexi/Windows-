# ============================================================
#  DingBootNotify 卸载脚本
#  用法：右键“以管理员身份运行”
#    .\uninstall.ps1                 只删除开机任务
#    .\uninstall.ps1 -RemoveFiles    同时删除安装目录（含配置与日志）
# ============================================================
param(
    [string]$TaskName = 'DingBootNotify',
    [string]$InstallDir = '',
    [switch]$RemoveFiles
)

$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '卸载开机任务需要管理员权限，正在申请提权……' -ForegroundColor Yellow
    $reArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($PSBoundParameters.ContainsKey('RemoveFiles') -and $RemoveFiles) { $reArgs += '-RemoveFiles' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $reArgs
        exit 0
    }
    catch {
        Write-Host '提权被取消。请右键 uninstall.ps1，选择“以管理员身份运行”。' -ForegroundColor Red
        exit 1
    }
}

if (-not $InstallDir) {
    if (Test-Path 'D:\DingBootNotify') { $InstallDir = 'D:\DingBootNotify' }
    else { $InstallDir = Join-Path $env:LOCALAPPDATA 'DingBootNotify' }
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除开机任务：$TaskName" -ForegroundColor Green
}
else {
    Write-Host "未找到任务：$TaskName（可能已手动删除）" -ForegroundColor Yellow
}

if ($RemoveFiles) {
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "已删除安装目录：$InstallDir" -ForegroundColor Green
    }
    else {
        Write-Host "安装目录不存在：$InstallDir" -ForegroundColor Yellow
    }
}
else {
    Write-Host "脚本与日志仍保留在：$InstallDir（如需一并删除，请加 -RemoveFiles）"
}
