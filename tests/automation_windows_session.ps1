# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 awesomo4000
# Run the WebView2 smoke test in the current user's existing desktop session.
# Useful from SSH, which normally runs in session 0. No stored password is used.
param(
    [Parameter(Mandatory=$true)][string]$Binary,
    [string]$Python = 'python.exe',
    [switch]$Bridge,
    [switch]$Protocol,
    [switch]$Placement
)
$ErrorActionPreference = 'Stop'
$Binary = (Resolve-Path $Binary).Path
$Python = (Get-Command $Python).Source
$test = Join-Path $PSScriptRoot 'automation_windows.py'
if ($Protocol) { $test = Join-Path $PSScriptRoot 'automation_windows_protocol.py' }
if ($Placement) { $test = Join-Path $PSScriptRoot 'window_placement.py' }
$name = 'TurfSmoke-' + [Guid]::NewGuid().ToString('N')
$log = Join-Path $env:TEMP ($name + '.log')
function Quote-PS([string]$value) { return "'" + $value.Replace("'", "''") + "'" }
$command = '& ' + (Quote-PS $Python) + ' ' + (Quote-PS $test) + ' ' + (Quote-PS $Binary)
if ($Bridge) { $command += ' --bridge' }
$command += ' *> ' + (Quote-PS $log) + '; exit $LASTEXITCODE'
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -EncodedCommand $encoded"
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
try {
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
    Start-ScheduledTask -TaskName $name
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 1
        $task = Get-ScheduledTask -TaskName $name
        $info = Get-ScheduledTaskInfo -TaskName $name
        if ((Get-Date) -gt $deadline) { throw 'Desktop test timed out; a logged-in desktop session is required.' }
    } while ($task.State -eq 'Running' -or $info.LastRunTime.Year -lt 2000)
    if (Test-Path $log) { Get-Content $log }
    if ($info.LastTaskResult -ne 0) { throw "Desktop smoke test failed: $($info.LastTaskResult). Log: $log" }
} finally {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $name }
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    }
}
