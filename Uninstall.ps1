[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$exePath = [IO.Path]::GetFullPath((Join-Path $appRoot 'SkillUpdater.exe'))
$marker = 'CodexSkillUpdater/v1;'
$taskNames = @('Codex Skill Updater - 0800 Auto', 'Codex Skill Updater - Logon Manual')
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Codex Skill Updater.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Skill Updater.lnk')
)
$shell = New-Object -ComObject WScript.Shell
$removed = New-Object 'System.Collections.Generic.List[string]'
$skipped = New-Object 'System.Collections.Generic.List[string]'

foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task) { continue }
    $actions = @($task.Actions)
    $owned = ([string]$task.Description).StartsWith($marker) -and $actions.Count -eq 1
    if ($owned) {
        try { $owned = [IO.Path]::GetFullPath([string]$actions[0].Execute).Equals($exePath, [StringComparison]::OrdinalIgnoreCase) }
        catch { $owned = $false }
    }
    if ($owned) {
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        $removed.Add($taskName)
    } else { $skipped.Add($taskName) }
}

foreach ($shortcutPath in $shortcuts) {
    if (-not (Test-Path -LiteralPath $shortcutPath)) { continue }
    $shortcut = $shell.CreateShortcut($shortcutPath)
    if (([string]$shortcut.TargetPath).Equals($exePath, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $shortcutPath -Force
        $removed.Add($shortcutPath)
    } else { $skipped.Add($shortcutPath) }
}

$state = [ordered]@{
    application = 'Codex Skill Updater'
    version = 1
    installed = $false
    uninstalledAt = (Get-Date).ToString('o')
    appRoot = $appRoot
    removed = @($removed.ToArray())
    skippedNotOwned = @($skipped.ToArray())
}
[IO.File]::WriteAllText((Join-Path $appRoot 'install-state.json'), ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Output 'Removed this installation''s schedules and shortcuts. Skill files and plugins were not changed.'
if ($skipped.Count -gt 0) { Write-Warning ('Skipped entries belonging to another installation: ' + ($skipped -join ', ')) }
