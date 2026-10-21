param([string]$BackendPath = (Join-Path $PSScriptRoot '..\Backend.ps1'))
$ErrorActionPreference = 'Stop'
. $BackendPath -LibraryOnly

# All test data and backups remain in this unique isolated workspace.
$script:TestRoot = Join-Path (Join-Path $PSScriptRoot '.artifacts') ('skill-updater-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
$script:Results = New-Object 'Collections.Generic.List[object]'
$script:CopyOps = New-Object 'Collections.Generic.List[object]'
$script:MoveOps = New-Object 'Collections.Generic.List[object]'

function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw ($Message + " (expected '$Expected'; actual '$Actual')") }
}
function Test-Within([string]$Path, [string]$Root) {
    return [IO.Path]::GetFullPath($Path).StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
}
function Write-TestFile([string]$Path, [string]$Text) {
    Assert-True (Test-Within $Path $script:TestRoot) 'Test write escaped its isolated workspace'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function Write-TestSkill([string]$Path, [string]$Version, [string]$Body) {
    Write-TestFile (Join-Path $Path 'SKILL.md') ("---`nname: fixture-skill`ndescription: isolated test`nmetadata:`n  version: `"$Version`"`n---`n" + $Body)
    Write-TestFile (Join-Path $Path 'references\guide.txt') ('supporting-file-' + $Body)
}
function Reset-Fixture([string]$Name) {
    $script:CaseRoot = Join-Path $script:TestRoot $Name
    $script:SkillRoot = Join-Path $script:CaseRoot 'skills'
    $script:DataPath = Join-Path $script:CaseRoot 'app-data'
    $script:SettingsFile = Join-Path $script:CaseRoot 'settings.json'
    $script:Config = [pscustomobject]@{ codexHome=(Join-Path $script:CaseRoot 'codex'); skillRoots=@($script:SkillRoot); localSources=@(); codexPath='unused-mocked.exe' }
    [IO.Directory]::CreateDirectory($script:SkillRoot) | Out-Null
    [IO.Directory]::CreateDirectory($script:DataPath) | Out-Null
    $script:CopyOps.Clear(); $script:MoveOps.Clear()
    $script:FailInstallMove = $false
    $script:ListCalls = 0; $script:AddCalls = 0
    $script:MockScenario = 'same'
    $script:MockLatest = '1.0.0'
    $script:MockPlugin = $null
}
function Initialize-LocalFixture {
    $script:Target = Join-Path $script:SkillRoot 'fixture-skill'
    $script:Source = Join-Path $script:CaseRoot 'runtime-package\skills\fixture-skill'
    Write-TestSkill $script:Target '1.0.0' 'old instructions'
    Write-TestSkill $script:Source '2.0.0' 'new instructions'
    $script:OldHash = Get-TreeHash $script:Target
    $script:SourceHash = Get-TreeHash $script:Source
    $script:Config.localSources = @([pscustomobject]@{ targetPath=$script:Target; sourcePath=$script:Source; baselineHash=$script:OldHash })
    Save-JsonFile $script:Config $script:SettingsFile
    $script:CopyOps.Clear(); $script:MoveOps.Clear()
}
function Initialize-PluginFixture {
    $script:PluginBase = Join-Path $script:Config.codexHome 'plugins\cache\fixture-market\fixture-plugin'
    Write-TestSkill (Join-Path $script:PluginBase '1.0.0\skills\fixture-skill') '1.0.0' 'plugin old'
    Write-TestFile (Join-Path $script:PluginBase '1.0.0\.codex-plugin\plugin.json') '{"name":"fixture-plugin","version":"1.0.0"}'
    $script:MockPlugin = [pscustomobject]@{
        pluginId='fixture-plugin@fixture-market'; name='fixture-plugin'; marketplaceName='fixture-market';
        version='1.0.0'; installed=$true; enabled=$true; installPolicy='AVAILABLE';
        source=[pscustomobject]@{source='remote';id='fixture-remote-id'}
    }
}

# Mock only the external CLI and remote catalog. No actual command is ever started.
function Invoke-CodexCli([string[]]$Arguments, [int]$TimeoutSeconds=90) {
    if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'plugin' -and $Arguments[1] -eq 'list') {
        $script:ListCalls++
        if ($script:MockScenario -eq 'removed' -and $script:ListCalls -gt 1) { return [pscustomobject]@{installed=@()} }
        if ($script:MockScenario -eq 'success' -and $script:AddCalls -gt 0) {
            $active = $script:MockPlugin.PSObject.Copy()
            $active.version = '2.0.0'
            return [pscustomobject]@{installed=@($active)}
        }
        return [pscustomobject]@{installed=@($script:MockPlugin)}
    }
    if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'plugin' -and $Arguments[1] -eq 'add') {
        $script:AddCalls++
        Assert-Equal $Arguments[2] 'fixture-plugin@fixture-market' 'Mock add received an unexpected plugin'
        if ($script:MockScenario -eq 'add-fails') { throw 'MOCK: plugin add failed' }
        if ($script:MockScenario -in @('success','inactive-new-cache')) {
            Write-TestSkill (Join-Path $script:PluginBase '2.0.0\skills\fixture-skill') '2.0.0' 'plugin new'
            Write-TestFile (Join-Path $script:PluginBase '2.0.0\.codex-plugin\plugin.json') '{"name":"fixture-plugin","version":"2.0.0"}'
        }
        return [pscustomobject]@{pluginId='fixture-plugin@fixture-market'}
    }
    throw ('Unexpected CLI request in isolated test: ' + ($Arguments -join ' '))
}
function Get-RemoteCatalog {
    return @{'fixture-remote-id'=[pscustomobject]@{ version=$script:MockLatest; name='Fixture Plugin'; fetchedAt=[datetimeoffset]::UtcNow.ToString('o') }}
}

# Observe real fixture copies/moves and inject exactly one staged-install failure for rollback.
function Copy-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force)
    Assert-True (Test-Within $LiteralPath $script:TestRoot) 'Copy source escaped fixture'
    Assert-True (Test-Within $Destination $script:TestRoot) 'Copy destination escaped fixture'
    $script:CopyOps.Add([pscustomobject]@{source=$LiteralPath;destination=$Destination})
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
function Move-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Destination, [switch]$Force)
    Assert-True (Test-Within $LiteralPath $script:TestRoot) 'Move source escaped fixture'
    Assert-True (Test-Within $Destination $script:TestRoot) 'Move destination escaped fixture'
    $script:MoveOps.Add([pscustomobject]@{source=$LiteralPath;destination=$Destination})
    if ($script:FailInstallMove -and $Destination -eq $script:Target -and (Test-Within $LiteralPath $script:DataPath) -and $LiteralPath -match '[\\/]staging[\\/]') {
        $script:FailInstallMove=$false
        throw 'MOCK: staged folder move failed'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
}
function Run-Test([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Results.Add([pscustomobject]@{name=$Name;passed=$true;error=$null})
        Write-Output ('PASS: ' + $Name)
    } catch {
        $script:Results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message})
        Write-Output ('FAIL: ' + $Name + ' | ' + $_.Exception.Message)
    }
}

Run-Test 'numeric-version-comparison-rejects-downgrade-and-prerelease' {
    Assert-True (Test-NewerVersion '1.10.0' '1.9.9') 'Numeric newer version was missed'
    Assert-True (Test-NewerVersion '26.1020.11349' '26.1020.11348') 'Date-like newer version was missed'
    Assert-True (-not (Test-NewerVersion '1.0.0' '2.0.0')) 'Downgrade was accepted'
    Assert-True (-not (Test-NewerVersion '1.0' '1.0.0')) 'Equivalent versions were treated as newer'
    Assert-True (-not (Test-NewerVersion '3.0.0-beta' '2.0.0')) 'Prerelease was guessed'
}
Run-Test 'local-user-edits-are-preserved' {
    Reset-Fixture 'local-edits'; Initialize-LocalFixture
    Write-TestFile (Join-Path $script:Target 'references\guide.txt') 'User customized this instruction'
    $editedHash=Get-TreeHash $script:Target
    $row=@(Get-LocalRows 'Update' | Where-Object {$_.name -eq 'fixture-skill'})[0]
    Assert-Equal (Get-TreeHash $script:Target) $editedHash 'Update overwrote a user edit'
    Assert-True (-not $row.canUpdate) 'User-edited skill remained eligible'
    Assert-Equal $script:CopyOps.Count 0 'User-edited skill was copied despite protection'
}
Run-Test 'local-check-does-not-mutate' {
    Reset-Fixture 'local-check'; Initialize-LocalFixture
    $row=@(Get-LocalRows 'Check' | Where-Object {$_.name -eq 'fixture-skill'})[0]
    Assert-True $row.canUpdate 'Expected local update was not detected'
    Assert-Equal (Get-TreeHash $script:Target) $script:OldHash 'Check changed the target skill'
    Assert-Equal $script:CopyOps.Count 0 'Check created an update copy'
}
Run-Test 'local-update-verifies-copy-and-backs-up-outside-discovery' {
    Reset-Fixture 'local-update'; Initialize-LocalFixture
    $row=@(Get-LocalRows 'Update' | Where-Object {$_.name -eq 'fixture-skill'})[0]
    Assert-Equal $row.current '2.0.0' ('Local update did not report installed version: ' + $row.detail)
    Assert-Equal (Get-TreeHash $script:Target) $script:SourceHash 'Installed skill differs from verified source'
    Assert-True (-not $row.canUpdate) 'Completed update remained eligible'
    $backupDirs=@(Get-ChildItem -LiteralPath (Join-Path $script:DataPath 'backups') -Directory)
    Assert-Equal $backupDirs.Count 1 'Expected one backup folder'
    Assert-Equal (Get-TreeHash (Join-Path $backupDirs[0].FullName 'skills')) $script:OldHash 'Backup differs from old skill'
    Assert-Equal (Get-TreeHash (Join-Path $backupDirs[0].FullName 'previous-folder')) $script:OldHash 'Moved original differs from old skill'
    foreach ($copy in @($script:CopyOps | Where-Object {$_.source -eq $script:Source})) {
        Assert-True (-not (Test-Within $copy.destination $script:SkillRoot)) 'Staging was created within skill discovery'
        Assert-True (Test-Within $copy.destination $script:DataPath) 'Staging was outside managed app data'
    }
    Assert-Equal @(Get-ChildItem -LiteralPath $script:SkillRoot -Directory).Count 1 'Update left duplicate discoverable skills'
    Assert-Equal (Read-JsonFile $script:SettingsFile).localSources[0].baselineHash $script:SourceHash 'Successful update did not persist new baseline'
}
Run-Test 'local-staged-move-failure-restores-original' {
    Reset-Fixture 'local-rollback'; Initialize-LocalFixture
    $script:FailInstallMove=$true
    $row=@(Get-LocalRows 'Update' | Where-Object {$_.name -eq 'fixture-skill'})[0]
    Assert-Equal (Get-TreeHash $script:Target) $script:OldHash 'Failed staged move did not restore original'
    Assert-True ($row.detail -like '*staged folder move failed*') 'Rollback failure was not reported truthfully'
    Assert-Equal (Read-JsonFile $script:SettingsFile).localSources[0].baselineHash $script:OldHash 'Failed update persisted a new baseline'
    Assert-Equal @(Get-ChildItem -LiteralPath $script:SkillRoot -Directory).Count 1 'Rollback left duplicate discoverable skills'
}
Run-Test 'plugin-removed-before-add-is-not-reinstalled' {
    Reset-Fixture 'plugin-removed'; Initialize-PluginFixture
    $script:MockScenario='removed'; $script:MockLatest='2.0.0'
    $row=@(Get-PluginRows 'Update')[0]
    Assert-Equal $script:AddCalls 0 'Removed plugin was reinstalled'
    Assert-Equal $row.current '1.0.0' 'Removed plugin falsely reported a new version'
    Assert-True ($row.detail -ne '') 'Removed plugin skip had no explanation'
}
Run-Test 'plugin-cli-failure-does-not-report-update' {
    Reset-Fixture 'plugin-failure'; Initialize-PluginFixture
    $script:MockScenario='add-fails'; $script:MockLatest='2.0.0'
    $row=@(Get-PluginRows 'Update')[0]
    Assert-Equal $script:AddCalls 1 'Plugin add failure scenario did not invoke mock add'
    Assert-Equal $row.current '1.0.0' 'Failed add falsely reported a new version'
    Assert-True ($row.detail -like '*MOCK: plugin add failed*') 'CLI failure was hidden'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $script:DataPath 'backups') -Directory).Count 1 'Old plugin skill was not backed up before attempted update'
}
Run-Test 'same-version-plugin-does-not-run-add' {
    Reset-Fixture 'plugin-current'; Initialize-PluginFixture
    $row=@(Get-PluginRows 'Update')[0]
    Assert-Equal $script:AddCalls 0 'Same-version plugin unnecessarily ran add'
    Assert-True (-not $row.canUpdate) 'Same-version plugin was marked updatable'
}
Run-Test 'plugin-downgrade-does-not-run-add' {
    Reset-Fixture 'plugin-downgrade'; Initialize-PluginFixture
    $script:MockLatest='0.9.0'
    $row=@(Get-PluginRows 'Update')[0]
    Assert-Equal $script:AddCalls 0 'Plugin downgrade ran add'
    Assert-Equal $row.current '1.0.0' 'Plugin version was downgraded'
}
Run-Test 'new-plugin-cache-without-active-version-is-not-success' {
    Reset-Fixture 'plugin-inactive'; Initialize-PluginFixture
    $script:MockScenario='inactive-new-cache'; $script:MockLatest='2.0.0'
    $row=@(Get-PluginRows 'Update')[0]
    Assert-Equal $script:AddCalls 1 'Plugin add was not attempted'
    Assert-Equal $row.current '1.0.0' 'New cached files alone were reported as active update'
    Assert-True $row.canUpdate 'Unconfirmed update should remain eligible for retry'
}
Run-Test 'plugin-success-requires-active-version-and-files' {
    Reset-Fixture 'plugin-success'; Initialize-PluginFixture
    $script:MockScenario='success'; $script:MockLatest='2.0.0'
    $row=@(Get-PluginRows 'Update')[0]
    Assert-Equal $script:AddCalls 1 'Expected exactly one plugin add'
    Assert-Equal $row.current '2.0.0' ('Verified plugin update not reported: ' + $row.detail)
    Assert-True (-not $row.canUpdate) 'Confirmed plugin update remained eligible'
    Assert-True (Test-Path -LiteralPath (Join-Path $script:PluginBase '2.0.0\skills\fixture-skill\SKILL.md')) 'Verified plugin skill files missing'
}

$failures=@($script:Results | Where-Object {-not $_.passed})
$report=[pscustomobject]@{runAt=(Get-Date).ToString('o');backend=[IO.Path]::GetFullPath($BackendPath);fixtureRoot=$script:TestRoot;passed=$script:Results.Count-$failures.Count;failed=$failures.Count;tests=@($script:Results.ToArray())}
Write-TestFile (Join-Path $script:TestRoot 'test-results.json') ($report | ConvertTo-Json -Depth 8)
Write-Output ("RESULT: $($report.passed) passed, $($report.failed) failed. Fixtures: $script:TestRoot")
if ($failures.Count -gt 0) { exit 1 }
