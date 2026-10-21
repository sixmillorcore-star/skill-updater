[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$exePath = [IO.Path]::GetFullPath((Join-Path $appRoot 'SkillUpdater.exe'))
$marker = 'CodexSkillUpdater/v1;'
$taskNames = @('Codex Skill Updater - 0800 Auto', 'Codex Skill Updater - Logon Manual')
$statePath = Join-Path $appRoot 'install-state.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Test-OwnedTask($task) {
    if (-not $task) { return $false }
    if (-not ([string]$task.Description).StartsWith($marker)) { return $false }
    $actions = @($task.Actions)
    if ($actions.Count -ne 1) { return $false }
    try { return [IO.Path]::GetFullPath([string]$actions[0].Execute).Equals($exePath, [StringComparison]::OrdinalIgnoreCase) }
    catch { return $false }
}

if (-not $exePath.StartsWith($appRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The executable path must be inside the application folder.'
}
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "Build SkillUpdater.exe before installing: $exePath" }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentUser = $identity.Name
$currentSid = $identity.User.Value
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Codex Skill Updater.lnk'
$startShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Skill Updater.lnk'
$shortcuts = @($desktopShortcut, $startShortcut)
$existingXml = @{}
$writtenTasks = New-Object 'System.Collections.Generic.List[string]'
$writtenShortcuts = New-Object 'System.Collections.Generic.List[string]'
$shell = New-Object -ComObject WScript.Shell

# Inspect all names before changing anything. Never replace another program's task or shortcut.
foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        if (-not (Test-OwnedTask $task)) { throw "A task with this name belongs to another installation: $taskName" }
        $existingXml[$taskName] = Export-ScheduledTask -TaskName $taskName -TaskPath '\'
    }
}
foreach ($shortcutPath in $shortcuts) {
    if (Test-Path -LiteralPath $shortcutPath) {
        $existingShortcut = $shell.CreateShortcut($shortcutPath)
        if (-not ([string]$existingShortcut.TargetPath).Equals($exePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "A shortcut with this name already points elsewhere: $shortcutPath"
        }
    }
}

$state = [ordered]@{
    application = 'Codex Skill Updater'
    version = 1
    installed = $false
    installedAt = (Get-Date).ToString('o')
    appRoot = $appRoot
    executable = $exePath
    currentUser = $currentUser
    currentSid = $currentSid
    timeZone = [TimeZoneInfo]::Local.Id
    dailyTime = '08:00'
    dailyMode = 'Auto update and show result; no missed-run catch-up'
    logonMode = 'Manual update window, delayed 20 seconds'
    taskNames = $taskNames
    shortcuts = $shortcuts
    startWhenAvailable = $false
    wakeToRun = $false
    error = $null
}

try {
    $principal = New-ScheduledTaskPrincipal -UserId $currentSid -LogonType Interactive -RunLevel Limited
    $dailySettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $dailySettings.StartWhenAvailable = $false
    $dailySettings.WakeToRun = $false
    $dailySettings.RunOnlyIfIdle = $false
    $logonSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    $logonSettings.StartWhenAvailable = $false
    $logonSettings.WakeToRun = $false
    $logonSettings.RunOnlyIfIdle = $false

    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]::Today.AddHours(8))
    $dailyAction = New-ScheduledTaskAction -Execute $exePath -Argument '--daily' -WorkingDirectory $appRoot
    $dailyTask = New-ScheduledTask -Action $dailyAction -Trigger $dailyTrigger -Principal $principal -Settings $dailySettings -Description "$marker Automatic skill update at 08:00 while this user is logged in; no missed-run catch-up."
    Register-ScheduledTask -TaskName $taskNames[0] -TaskPath '\' -InputObject $dailyTask -Force | Out-Null
    $writtenTasks.Add($taskNames[0])

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentSid
    $logonTrigger.Delay = 'PT20S'
    $logonAction = New-ScheduledTaskAction -Execute $exePath -WorkingDirectory $appRoot
    $logonTask = New-ScheduledTask -Action $logonAction -Trigger $logonTrigger -Principal $principal -Settings $logonSettings -Description "$marker Open the manual Skill Updater window after this user logs in; never auto update on logon."
    Register-ScheduledTask -TaskName $taskNames[1] -TaskPath '\' -InputObject $logonTask -Force | Out-Null
    $writtenTasks.Add($taskNames[1])

    foreach ($shortcutPath in $shortcuts) {
        $wasPresent = Test-Path -LiteralPath $shortcutPath
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $exePath
        $shortcut.WorkingDirectory = $appRoot
        $shortcut.Description = 'Check and update Codex skills'
        $iconPath = Join-Path $appRoot 'app-icon.ico'
        $shortcut.IconLocation = if (Test-Path -LiteralPath $iconPath -PathType Leaf) { "$iconPath,0" } else { "$exePath,0" }
        $shortcut.Save()
        if (-not $wasPresent) { $writtenShortcuts.Add($shortcutPath) }
    }

    $state.installed = $true
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), $utf8)
    Write-Output 'Installed: automatic update at 08:00; manual window at Windows logon.'
    Write-Output "Application: $exePath"
    Write-Output "Schedule time zone: $($state.timeZone)"
} catch {
    $failure = $_.Exception.Message
    foreach ($taskName in $writtenTasks) {
        try {
            if ($existingXml.ContainsKey($taskName)) {
                Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $existingXml[$taskName] -Force | Out-Null
            } else {
                Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
            }
        } catch { Write-Warning "Could not roll back task '$taskName': $($_.Exception.Message)" }
    }
    foreach ($shortcutPath in $writtenShortcuts) {
        if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
    }
    $state.error = $failure
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), $utf8)
    throw "Installation failed and newly created changes were rolled back: $failure"
}
