$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Discovery.ps1')
$fixture=Join-Path (Join-Path $PSScriptRoot '.artifacts') ('discovery-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$passed=New-Object 'Collections.Generic.List[string]'
function Assert-Discovery($Condition,[string]$Name) { if(-not $Condition){throw ('FAIL: '+$Name)}; $passed.Add($Name) }
function Write-FixtureSkill([string]$Folder,[string]$Name,[string]$Version='1.0') {
 [IO.Directory]::CreateDirectory($Folder) | Out-Null
 [IO.File]::WriteAllText((Join-Path $Folder 'SKILL.md'),("---`nname: "+$Name+"`ndescription: Fixture only`nmetadata:`n  version: '"+$Version+"'`n---`nFixture."),(New-Object Text.UTF8Encoding($false)))
}
$oldCodexHome=$env:CODEX_HOME; $oldClaudeHome=$env:CLAUDE_CONFIG_DIR
try {
 $env:CODEX_HOME=$null; $env:CLAUDE_CONFIG_DIR=$null
 $cfg=[pscustomobject]@{userHome=$fixture;codexHome=(Join-Path $fixture '.codex');claudeHome=(Join-Path $fixture '.claude');skillRoots=@();projectRoots=@((Join-Path $fixture 'project'));discoverProjects=$false}
 Write-FixtureSkill (Join-Path $cfg.codexHome 'skills/alpha') 'same-name' '1.2'
 Write-FixtureSkill (Join-Path $fixture '.agents/skills/shared') 'shared-skill' '2'
 Write-FixtureSkill (Join-Path $cfg.codexHome 'skills/.system/builtin') 'builtin' '3'
 Write-FixtureSkill (Join-Path $fixture 'project/.claude/skills/team') 'team-skill' '4'
 $result=Get-DiscoveredSkills -Config $cfg -CodexPlugins @() -ClaudePlugins @()
 Assert-Discovery (@($result.skills).Count -eq 4) 'Filesystem discovery works without any plugin CLI inventory'
 Assert-Discovery (@($result.skills | Where-Object {$_.sourceKind -eq 'system'}).Count -eq 1) 'System Skill counted individually'
 Assert-Discovery (@($result.skills | Where-Object {$_.scope -eq 'Project' -and $_.providers -contains 'Claude Code'}).Count -eq 1) 'Known project Claude Skill detected'
 Write-FixtureSkill (Join-Path $cfg.claudeHome 'skills/same') 'same-name' '5'
 $result=Get-DiscoveredSkills -Config $cfg -ClaudePlugins @()
 Assert-Discovery (@($result.skills | Where-Object {$_.name -eq 'same-name'}).Count -eq 2) 'Same names at different paths remain distinct'
 $cfg | Add-Member -NotePropertyName sharedSkillRoots -NotePropertyValue @((Join-Path $fixture '.agents/skills'))
 $result=Get-DiscoveredSkills -Config $cfg -ClaudePlugins @()
 $shared=@($result.skills | Where-Object {$_.name -eq 'shared-skill'})
 Assert-Discovery ($shared.Count -eq 1 -and $shared[0].providers.Count -eq 2) 'Physical shared Skill merges providers'
 $plugin=[pscustomobject]@{pluginId='sample@market';name='sample';marketplaceName='market';version='1.0';installed=$true;enabled=$true;source=[pscustomobject]@{source='remote';id='example'}}
 Write-FixtureSkill (Join-Path $cfg.codexHome 'plugins/cache/market/sample/1.0/skills/current') 'current-plugin' '1'
 Write-FixtureSkill (Join-Path $cfg.codexHome 'plugins/cache/market/sample/2.0/skills/stale') 'stale-cache' '2'
 $result=Get-DiscoveredSkills -Config $cfg -CodexPlugins @($plugin) -ClaudePlugins @()
 Assert-Discovery (@($result.skills | Where-Object {$_.name -eq 'current-plugin'}).Count -eq 1 -and @($result.skills | Where-Object {$_.name -eq 'stale-cache'}).Count -eq 0) 'Only installed Codex version scanned'
 $plugin.installed=$false
 $result=Get-DiscoveredSkills -Config $cfg -CodexPlugins @($plugin) -ClaudePlugins @()
 Assert-Discovery (@($result.skills | Where-Object {$_.sourceKind -eq 'codex-plugin'}).Count -eq 0) 'Uninstalled plugin never discovered from old cache'
 $plugin.installed=$true; $plugin.enabled=$false
 $disabledFile=Join-Path $cfg.codexHome 'skills/alpha/SKILL.md'
 [IO.File]::WriteAllText((Join-Path $cfg.codexHome 'config.toml'),("[[skills.config]]`npath = '"+$disabledFile+"'`nenabled = false`n"))
 $result=Get-DiscoveredSkills -Config $cfg -CodexPlugins @($plugin) -ClaudePlugins @()
 Assert-Discovery ((@($result.skills | Where-Object {$_.name -eq 'current-plugin'})[0].enabled -eq $false) -and (@($result.skills | Where-Object {$_.skillFile -eq $disabledFile})[0].enabled -eq $false)) 'Disabled plugin and explicit local Skill preserved as disabled'
 $claudePackage=Join-Path $fixture 'claude-package'
 Write-FixtureSkill (Join-Path $claudePackage 'skills/base') 'claude-base' '6'
 Write-FixtureSkill (Join-Path $claudePackage 'custom/extra') 'claude-extra' '7'
 [IO.Directory]::CreateDirectory((Join-Path $claudePackage '.claude-plugin')) | Out-Null
 [IO.File]::WriteAllText((Join-Path $claudePackage '.claude-plugin/plugin.json'),'{"name":"claude-package","version":"9","skills":["./custom/"]}')
 $claudePlugins=@([pscustomobject]@{pluginId='cp@market';scope='user';projectPath='';installPath=$claudePackage;version='9';enabled=$true;ownerKey='provided-normalized-owner'},[pscustomobject]@{pluginId='cp@market';scope='project';projectPath=(Join-Path $fixture 'project');installPath=$claudePackage;version='9';enabled=$false;ownerKey='project-normalized-owner'})
 $result=Get-DiscoveredSkills -Config $cfg -CodexPlugins @() -ClaudePlugins $claudePlugins
 $pluginSkills=@($result.skills | Where-Object {$_.sourceKind -eq 'claude-plugin'})
 Assert-Discovery ($pluginSkills.Count -eq 4 -and @($pluginSkills | Where-Object {$_.name -eq 'claude-extra'}).Count -eq 2) 'Claude default plus manifest Skills and installation scopes preserved'
 Assert-Discovery (@($pluginSkills | Where-Object {$_.ownerKey -eq 'provided-normalized-owner'}).Count -eq 2) 'Normalized Claude ownerKey passed through unchanged'
 Write-FixtureSkill (Join-Path $cfg.claudeHome 'skills/synced/account/cloud') 'cloud-skill' '8'
 Write-FixtureSkill (Join-Path $cfg.claudeHome 'skills/.trash/old') 'trashed-skill' '1'
 $result=Get-DiscoveredSkills -Config $cfg -ClaudePlugins @()
 Assert-Discovery (@($result.skills | Where-Object {$_.name -eq 'cloud-skill' -and $_.scope -eq 'Synced'}).Count -eq 1 -and @($result.skills | Where-Object {$_.name -eq 'trashed-skill'}).Count -eq 0) 'Synced Skill managed; removed trash excluded'
 $linkRoot=Join-Path $fixture 'links'
 [IO.Directory]::CreateDirectory($linkRoot) | Out-Null
 New-Item -ItemType Junction -Path (Join-Path $linkRoot 'one') -Target (Join-Path $fixture '.agents/skills/shared') | Out-Null
 New-Item -ItemType Junction -Path (Join-Path $linkRoot 'two') -Target (Join-Path $fixture '.agents/skills/shared') | Out-Null
 New-Item -ItemType Junction -Path (Join-Path $linkRoot 'cycle') -Target $linkRoot | Out-Null
 $cfg.sharedSkillRoots=@($linkRoot)
 $result=Get-DiscoveredSkills -Config $cfg -ClaudePlugins @()
 Assert-Discovery (@($result.skills | Where-Object {$_.name -eq 'shared-skill'}).Count -eq 1) 'Junction aliases deduplicated and cycles terminate'
 $env:CODEX_HOME=Join-Path $fixture 'alternate-codex'
 [IO.Directory]::CreateDirectory($env:CODEX_HOME) | Out-Null
 $environment=Get-DiscoveryEnvironment $cfg
 Assert-Discovery ($environment.codexHome -eq $env:CODEX_HOME) 'CODEX_HOME overrides stale saved settings'
 $report=[pscustomobject]@{passed=$passed.Count;failed=0;tests=@($passed.ToArray());fixture=$fixture}
 $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'test-results.json') -Encoding UTF8
 $report | ConvertTo-Json -Depth 5
} finally { $env:CODEX_HOME=$oldCodexHome; $env:CLAUDE_CONFIG_DIR=$oldClaudeHome }
