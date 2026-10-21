$ErrorActionPreference='Stop'
$appRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $appRoot 'Backend.ps1') -LibraryOnly
$fixtureRoot=Join-Path (Join-Path $PSScriptRoot '.artifacts') ('backend-integration-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot)|Out-Null
$script:Config=[pscustomobject]@{codexHome=(Join-Path $fixtureRoot 'codex');skillRoots=@();localSources=@()}
$script:DataPath=Join-Path $fixtureRoot 'data'
$script:SettingsFile=Join-Path $fixtureRoot 'settings.json'
$results=New-Object 'Collections.Generic.List[object]'

function Reset-Fixture {
 $script:Fixture=@{cliMode='ok';skills=@();installed=@();plugins=@();codexPlans=@{};claudePlans=@{};claudeDetected=$false;warnings=@()}
 $script:Calls=@{cli=0;codexPlans=0;claudePlans=0;claudeUpdates=0;localUpdates=0;codexOwnerIds=@();claudeOwners=@()}
}
function New-Skill([string]$Name,[string]$Kind='local',[string]$OwnerId='', [string]$OwnerKey='', [string[]]$Providers=@('Codex'),[string]$Scope='user',[bool]$Enabled=$true) {
 [pscustomobject]@{name=$Name;version='1.0';providers=$Providers;scope=$Scope;skillPath=(Join-Path $fixtureRoot ($Kind+'-'+$Name+'-'+$Scope+'-'+($OwnerKey -replace '[^a-zA-Z0-9]','_')));sourceKind=$Kind;ownerId=$OwnerId;ownerKey=$OwnerKey;enabled=$Enabled;packageVersion='1.0'}
}
function New-Plan([string]$Current='1.0',[string]$Latest='1.1',[bool]$Ready=$true,[string]$Status='มีอัปเดต') {
 [pscustomobject]@{current=$Current;latest=$Latest;canUpdate=$Ready;status=$Status;detail='Fixture plan'}
}
function Get-DiscoveryEnvironment($Config) {
 [pscustomobject]@{codexHome=$Config.codexHome;providers=@([pscustomobject]@{name='Codex';detected=$false;cliPath='';status='ไม่พบในเครื่อง';detail='Fixture'},[pscustomobject]@{name='Claude Code';detected=$script:Fixture.claudeDetected;cliPath='';status='ไม่พบในเครื่อง';detail='Fixture'})}
}
function Resolve-Codex($Config) { if($script:Fixture.cliMode -eq 'missing'){throw 'Codex CLI absent'}; return 'fixture-codex.exe' }
function Invoke-CodexCli([string[]]$Arguments,[int]$TimeoutSeconds=90) {
 $script:Calls.cli++
 if($script:Fixture.cliMode -eq 'missing'){throw 'Absent Codex CLI must not be invoked'}
 if($script:Fixture.cliMode -eq 'error'){throw 'Fixture Codex network failure'}
 [pscustomobject]@{installed=$script:Fixture.installed}
}
function Get-ClaudePluginInventory($Config) {
 [pscustomobject]@{plugins=$script:Fixture.plugins;detected=$script:Fixture.claudeDetected;cliPath='';detail='Fixture Claude inventory';errors=@()}
}
function Get-DiscoveredSkills($Config,$CodexPlugins,$ClaudePlugins,$Environment) {
 [pscustomobject]@{skills=$script:Fixture.skills;providers=$Environment.providers;roots=@();warnings=$script:Fixture.warnings}
}
function Get-PluginRows([string]$RequestedMode,$Listing=$null,$OwnerIds=$null) {
 $script:Calls.codexPlans++;$script:Calls.codexOwnerIds=@($OwnerIds)
 foreach($owner in @($OwnerIds)){
  $plan=$script:Fixture.codexPlans[$owner]
  if(-not $plan){continue}
  $row=New-Row $owner $plan.current $plan.latest $plan.status $plan.detail $plan.canUpdate
  $row|Add-Member -NotePropertyName ownerId -NotePropertyValue $owner
  if($RequestedMode -eq 'Update' -and $row.canUpdate){$row.current=$row.latest;$row.status='อัปเดตแล้ว';$row.canUpdate=$false}
  $row
 }
}
function Get-ClaudeUpdatePlan($Plugin,$Config) {
 $script:Calls.claudePlans++;$script:Calls.claudeOwners+=@($Plugin.ownerKey)
 $plan=$script:Fixture.claudePlans[$Plugin.ownerKey]
 if(-not $plan){throw 'Fixture missing plan'}
 New-Row $Plugin.name $plan.current $plan.latest $plan.status $plan.detail $plan.canUpdate
}
function Invoke-ClaudePluginUpdate($Plugin,$Config,$BackupRoot) {
 $script:Calls.claudeUpdates++
 $plan=$script:Fixture.claudePlans[$Plugin.ownerKey]
 [pscustomobject]@{current=$plan.latest;latest=$plan.latest;status='อัปเดตแล้ว';detail='Fixture update verified'}
}
function Get-LocalRows([string]$RequestedMode,$SkillRecord=$null) {
 if($RequestedMode -eq 'Update'){$script:Calls.localUpdates++}
 New-Row $SkillRecord.name $SkillRecord.version '-' 'ดูแลเอง' 'No verified upstream' $false
}
function Assert-True($Condition,[string]$Message) {if(-not $Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body) {
 Reset-Fixture
 try {& $Body; $results.Add([pscustomobject]@{name=$Name;passed=$true;error=$null})}
 catch {$results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message})}
}

Test-Case 'Multiple Codex skills map to one package update plan' {
 $owner='bundle@fixture'
 $script:Fixture.installed=@([pscustomobject]@{pluginId=$owner;enabled=$true;installed=$true})
 $script:Fixture.codexPlans[$owner]=New-Plan
 $script:Fixture.skills=@((New-Skill 'one' 'codex-plugin' $owner $owner),(New-Skill 'two' 'codex-plugin' $owner $owner),(New-Skill 'three' 'codex-plugin' $owner $owner))
 $report=Invoke-Updater 'Check'
 Assert-True ($script:Calls.codexPlans -eq 1) 'Package planner called more than once'
 Assert-True ($script:Calls.codexOwnerIds.Count -eq 1) 'Owner IDs were not deduplicated'
 Assert-True ($report.availableCount -eq 3 -and $report.availablePackageCount -eq 1) 'Skill/package ready counts incorrect'
 Assert-True ($report.detectedSkillCount -eq 3) 'Actual skill count incorrect'
}
Test-Case 'Claude installations with same plugin ID preserve scope owner keys' {
 $script:Fixture.claudeDetected=$true
 $script:Fixture.plugins=@([pscustomobject]@{name='same';ownerKey='same|user';enabled=$true;version='1.0'},[pscustomobject]@{name='same';ownerKey='same|project';enabled=$true;version='2.0'})
 $script:Fixture.claudePlans['same|user']=New-Plan '1.0' '1.1'
 $script:Fixture.claudePlans['same|project']=New-Plan '2.0' '2.1'
 $script:Fixture.skills=@((New-Skill 'same-skill' 'claude-plugin' 'same@market' 'same|user' @('Claude Code') 'user'),(New-Skill 'same-skill' 'claude-plugin' 'same@market' 'same|project' @('Claude Code') 'project'))
 $report=Invoke-Updater 'Check'
 $user=@($report.rows|Where-Object{$_.ownerKey -eq 'same|user'})[0]
 $project=@($report.rows|Where-Object{$_.ownerKey -eq 'same|project'})[0]
 Assert-True ($user.current -eq '1.0' -and $user.latest -eq '1.1' -and $project.current -eq '2.0' -and $project.latest -eq '2.1') 'Scope plans mixed'
 Assert-True ($report.availablePackageCount -eq 2 -and $script:Calls.claudePlans -eq 2) 'Scope packages were incorrectly merged'
}
Test-Case 'Unknown Claude upstream never becomes an automatic update' {
 $script:Fixture.claudeDetected=$true
 $script:Fixture.plugins=@([pscustomobject]@{name='unknown';ownerKey='unknown|user';enabled=$true;version='1.0'})
 $script:Fixture.claudePlans['unknown|user']=New-Plan '1.0' '?' $false 'ตรวจผ่าน Claude'
 $script:Fixture.skills=@((New-Skill 'unknown' 'claude-plugin' 'unknown@market' 'unknown|user' @('Claude Code')))
 $report=Invoke-Updater 'Update'
 Assert-True ($script:Calls.claudeUpdates -eq 0 -and $report.availableCount -eq 0) 'Unknown upstream was updated'
 Assert-True ($report.rows[0].latest -eq '?' -and $report.rows[0].status -eq 'ตรวจผ่าน Claude' -and $report.manualCount -eq 1) 'Unknown state was misreported as latest'
}
Test-Case 'Absent Codex CLI does not block Claude and filesystem skills' {
 $script:Fixture.cliMode='missing';$script:Fixture.claudeDetected=$true
 $script:Fixture.skills=@((New-Skill 'claude-local' 'local' '' '' @('Claude Code')))
 $report=Invoke-Updater 'Check'
 Assert-True ($report.rows.Count -eq 1 -and $report.errorCount -eq 0 -and -not $report.error) 'Missing optional Codex produced a global error'
 Assert-True ($script:Calls.cli -eq 0) 'Missing Codex CLI invoked'
 $provider=@($report.providerStats|Where-Object{$_.name -eq 'Claude Code'})[0]
 Assert-True ($provider.detected -and $provider.skillCount -eq 1) 'Claude provider detection/count wrong'
}
Test-Case 'Codex CLI read failure preserves filesystem skills and reports partial failure' {
 $script:Fixture.cliMode='error'
 $script:Fixture.skills=@((New-Skill 'codex-local'))
 $report=Invoke-Updater 'Check'
 Assert-True ($report.rows.Count -eq 1 -and $report.rows[0].name -eq 'codex-local') 'Filesystem detection lost after CLI failure'
 Assert-True ($report.errorCount -eq 1 -and $report.error -match 'Codex') 'CLI failure hidden'
}
Test-Case 'Disabled skills remain disabled and skip update planners and actions' {
 $script:Fixture.claudeDetected=$true
 $script:Fixture.plugins=@([pscustomobject]@{name='disabled';ownerKey='disabled|user';enabled=$false;version='1.0'})
 $script:Fixture.installed=@([pscustomobject]@{pluginId='disabled@fixture';enabled=$false;installed=$true})
 $script:Fixture.skills=@((New-Skill 'off-codex' 'codex-plugin' 'disabled@fixture' 'disabled@fixture' @('Codex') 'user' $false),(New-Skill 'off-claude' 'claude-plugin' 'disabled@market' 'disabled|user' @('Claude Code') 'user' $false))
 $report=Invoke-Updater 'Update'
 Assert-True ($script:Calls.codexPlans -eq 0 -and $script:Calls.claudePlans -eq 0 -and $script:Calls.claudeUpdates -eq 0) 'Disabled package reached update logic'
 Assert-True (@($report.rows|Where-Object{$_.status -eq 'ปิดใช้งาน' -and $_.enabled -eq $false -and -not $_.canUpdate}).Count -eq 2) 'Disabled metadata was lost'
}
Test-Case 'Shared providers and individual/package counts remain accurate' {
 $script:Fixture.claudeDetected=$true
 $script:Fixture.installed=@([pscustomobject]@{pluginId='bundle@fixture';enabled=$true;installed=$true})
 $script:Fixture.codexPlans['bundle@fixture']=New-Plan
 $script:Fixture.plugins=@([pscustomobject]@{name='claude';ownerKey='claude|user';enabled=$true;version='1.0'})
 $script:Fixture.claudePlans['claude|user']=New-Plan
 $script:Fixture.skills=@((New-Skill 'c1' 'codex-plugin' 'bundle@fixture' 'bundle@fixture'),(New-Skill 'c2' 'codex-plugin' 'bundle@fixture' 'bundle@fixture'),(New-Skill 'c3' 'codex-plugin' 'bundle@fixture' 'bundle@fixture'),(New-Skill 'a1' 'claude-plugin' 'claude@market' 'claude|user' @('Claude Code')),(New-Skill 'a2' 'claude-plugin' 'claude@market' 'claude|user' @('Claude Code')),(New-Skill 'shared' 'local' '' '' @('Codex','Claude Code')),(New-Skill 'unknown'))
 $report=Invoke-Updater 'Check'
 Assert-True ($report.detectedSkillCount -eq 7 -and $report.rows.Count -eq 7 -and $report.availableCount -eq 5 -and $report.availablePackageCount -eq 2) 'Individual/package counts incorrect'
 Assert-True ((@($report.providerStats|Where-Object{$_.name -eq 'Codex'})[0].skillCount -eq 5) -and (@($report.providerStats|Where-Object{$_.name -eq 'Claude Code'})[0].skillCount -eq 3)) 'Shared-provider counts incorrect'
 $updated=Invoke-Updater 'Update'
 Assert-True ($updated.updatedCount -eq 5 -and $updated.availableCount -eq 0 -and $script:Calls.claudeUpdates -eq 1) 'One package update did not map consistently to all owned skills'
}
Test-Case 'Claude-only update does not attempt an absent Codex CLI during rescan' {
 $script:Fixture.cliMode='missing';$script:Fixture.claudeDetected=$true
 $script:Fixture.plugins=@([pscustomobject]@{name='claude';ownerKey='claude|user';enabled=$true;version='1.0'})
 $script:Fixture.claudePlans['claude|user']=New-Plan
 $script:Fixture.skills=@((New-Skill 'claude-skill' 'claude-plugin' 'claude@market' 'claude|user' @('Claude Code')))
 $report=Invoke-Updater 'Update'
 Assert-True ($script:Calls.cli -eq 0) 'Post-update rescan invoked missing Codex CLI'
 Assert-True ($report.updatedCount -eq 1 -and $report.errorCount -eq 0 -and -not $report.error) 'Successful Claude-only update received a false error'
}

$failed=@($results|Where-Object{-not $_.passed}).Count
$report=[ordered]@{passed=$results.Count-$failed;failed=$failed;tests=@($results.ToArray());fixtureRoot=$fixtureRoot;scope='All external CLI/discovery/updates mocked; no installed Skill changes'}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $fixtureRoot 'results.json') -Encoding UTF8
$report|ConvertTo-Json -Depth 8
if($failed -gt 0){exit 1}
