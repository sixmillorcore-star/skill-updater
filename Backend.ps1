param(
    [ValidateSet('Check','Update')][string]$Mode = 'Check',
    [string]$OutputPath,
    [string]$SettingsPath = (Join-Path $PSScriptRoot 'settings.json'),
    [switch]$LibraryOnly
)
$ErrorActionPreference = 'Stop'

function Read-JsonFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return $null
}
function Save-JsonFile($Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 18), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Test-NewerVersion([string]$Candidate, [string]$Current) {
    # Reject unknown/prerelease versions instead of guessing a downgrade.
    if ($Candidate -notmatch '^\d+(\.\d+){0,3}$' -or $Current -notmatch '^\d+(\.\d+){0,3}$') { return $false }
    $a = @($Candidate.Split('.') | ForEach-Object { [long]$_ })
    $b = @($Current.Split('.') | ForEach-Object { [long]$_ })
    for ($i=0; $i -lt 4; $i++) {
        $av=0; $bv=0
        if ($i -lt $a.Count) { $av=$a[$i] }; if ($i -lt $b.Count) { $bv=$b[$i] }
        if ($av -gt $bv) { return $true }; if ($av -lt $bv) { return $false }
    }
    return $false
}
function Assert-ChildPath([string]$Path, [string]$Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Path outside expected folder: $full" }
    return $full
}
function Get-SafeFiles([string]$Path) {
    $root = Get-Item -LiteralPath $Path
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked folder is not supported: $Path" }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($root.FullName)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked file/folder is not supported: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
        }
    }
}
function Get-TreeHash([string]$Path) {
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parts = @(Get-SafeFiles $root | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($root.Length).Replace('\','/') + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))).Replace('-','') } finally { $sha.Dispose() }
}
function Get-SkillVersion([string]$Path) {
    $file = Join-Path $Path 'SKILL.md'
    if (-not (Test-Path -LiteralPath $file)) { return '?' }
    $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    if ($text -match '(?s)\A\uFEFF?---\s*\r?\n(.*?)\r?\n---(?:\r?\n|$)') {
        $frontmatter=$Matches[1]
        if ($frontmatter -match '(?m)^\s*version:\s*["'']?([^"''\r\n]+)') { return $Matches[1].Trim() }
    }
    return 'ไม่ระบุ'
}
function New-Row([string]$Name, [string]$Current, [string]$Latest, [string]$Status, [string]$Detail, [bool]$CanUpdate=$false) {
    return [pscustomobject]@{ name=$Name; current=$Current; latest=$Latest; status=$Status; detail=$Detail; canUpdate=$CanUpdate }
}
function Resolve-Codex($Config) {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot) {
        $found = Get-ChildItem -LiteralPath $binRoot -Directory | ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'codex.exe') -ErrorAction SilentlyContinue } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    if ($Config.codexPath -and (Test-Path -LiteralPath $Config.codexPath)) { return $Config.codexPath }
    throw 'ไม่พบ Codex CLI กรุณาเปิดหรือติดตั้งแอป Codex ก่อน'
}
function ConvertTo-WindowsArgument([string]$Value) {
    # Windows CommandLineToArgvW escaping; no shell is involved.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Invoke-CodexCli([string[]]$Arguments, [int]$TimeoutSeconds=90) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $script:CodexExecutable
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8
    $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    $start.EnvironmentVariables['CODEX_HOME']=$script:Config.codexHome
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    try {
        $process.Start() | Out-Null
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) { $process.Kill(); $process.WaitForExit(); throw 'Codex ใช้เวลานานเกินกำหนด กรุณาตรวจอินเทอร์เน็ตแล้วลองใหม่' }
        $out=$stdout.Result; $err=$stderr.Result
        if ($process.ExitCode -ne 0) { throw ('Codex CLI ล้มเหลว: ' + $err.Trim()) }
        return ($out | ConvertFrom-Json)
    } finally { $process.Dispose() }
}
function Get-PluginCachePath($Plugin) {
    if ($Plugin.marketplaceName -notmatch '^[a-zA-Z0-9._-]+$' -or $Plugin.name -notmatch '^[a-zA-Z0-9._-]+$') { return $null }
    $parent=Join-Path (Join-Path $script:Config.codexHome 'plugins\cache') ($Plugin.marketplaceName + '\' + $Plugin.name)
    if (-not (Test-Path -LiteralPath $parent)) { return $null }
    if ($Plugin.version -match '^[a-zA-Z0-9._-]+$') {
        $exact=Join-Path $parent $Plugin.version
        if (Test-Path -LiteralPath $exact) { return $exact }
    }
    $best=$null; $bestVersion='0'
    foreach ($directory in Get-ChildItem -LiteralPath $parent -Directory) {
        if ($directory.Name -match '^\d+(\.\d+){0,3}$' -and (Test-NewerVersion $directory.Name $bestVersion)) { $best=$directory.FullName; $bestVersion=$directory.Name }
    }
    return $best
}
function Backup-Skills([string]$Source, [string]$Name) {
    $safeName=$Name -replace '[^a-zA-Z0-9._-]','_'
    $backup=Join-Path $script:DataPath ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $safeName + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    Get-SafeFiles $Source | Out-Null
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    Copy-Item -LiteralPath $Source -Destination (Join-Path $backup 'skills') -Recurse
    return $backup
}
function Get-RemoteCatalog {
    $folder=Join-Path $script:Config.codexHome 'cache\remote_plugin_catalog'
    if (-not (Test-Path -LiteralPath $folder)) { return @{} }
    $map=@{}
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object LastWriteTimeUtc) {
        try {
            $catalog=Read-JsonFile $file.FullName
            $age=[datetimeoffset]::UtcNow - [datetimeoffset]::Parse($catalog.fetched_at)
            if ($age.TotalHours -gt 12 -or $age.TotalMinutes -lt -5) { continue }
            foreach ($plugin in $catalog.plugins) { $map[$plugin.id]=[pscustomobject]@{version=$plugin.release.version; name=$plugin.release.display_name; fetchedAt=$catalog.fetched_at} }
        } catch { continue }
    }
    return $map
}
function Get-PluginRows([string]$RequestedMode, $Listing=$null, $OwnerIds=$null) {
    $listing=$Listing
    if (-not $listing) { $listing=Invoke-CodexCli -Arguments @('plugin','list','--json') }
    $catalog=Get-RemoteCatalog
    foreach ($plugin in $listing.installed) {
        if (-not $plugin.installed -or -not $plugin.enabled) { continue }
        if ($null -ne $OwnerIds -and @($OwnerIds) -notcontains $plugin.pluginId) { continue }
        $cache=Get-PluginCachePath $plugin
        if (-not $cache -or -not (Test-Path -LiteralPath (Join-Path $cache 'skills'))) { continue }
        if (-not @(Get-ChildItem -LiteralPath (Join-Path $cache 'skills') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') }).Count) { continue }
        $manifestPath=Join-Path $cache '.codex-plugin\plugin.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { $manifestPath=Join-Path $cache 'plugin.json' }
        $manifest=Read-JsonFile $manifestPath
        $current=[string]$manifest.version; $latest='?'; $name=[string]$plugin.name
        $detail=''; $eligible=$false
        if ($plugin.source.source -eq 'remote') {
            if ($catalog.ContainsKey($plugin.source.id)) {
                $release=$catalog[$plugin.source.id]; $latest=[string]$release.version
                if ($release.name) { $name=$release.name }
                $stamp=([datetimeoffset]::Parse($release.fetchedAt)).ToLocalTime().ToString('dd/MM HH:mm')
                $detail='Catalog ของ Codex ตรวจเมื่อ ' + $stamp
            } elseif ($plugin.installPolicy -eq 'INSTALLED_BY_DEFAULT') {
                $latest='ตามแอป'; $detail='ปลั๊กอินภายในที่แอปดูแล; ไม่มีรุ่นเผยแพร่ใน Catalog สาธารณะ'
            } else { $detail='ยังตรวจรุ่นออนไลน์ไม่ได้ หรือข้อมูล Catalog เก่าเกิน 12 ชั่วโมง' }
        } elseif ($plugin.source.source -eq 'local') {
            $sourceManifest=Join-Path $plugin.source.path '.codex-plugin\plugin.json'
            if (-not (Test-Path -LiteralPath $sourceManifest)) { $sourceManifest=Join-Path $plugin.source.path 'plugin.json' }
            $source=Read-JsonFile $sourceManifest
            if ($source) { $latest=[string]$source.version }
            $detail='ตรวจจากแพ็กเกจที่ Codex จัดเตรียมไว้; รุ่นใหม่มาพร้อมการอัปเดตแอป'
        }
        $status='ตรวจไม่ได้'
        if ($latest -eq 'ตามแอป') { $status='แอปดูแล' }
        elseif ($latest -eq $current) { $status='ตรงกับต้นทาง' }
        elseif (Test-NewerVersion $latest $current) { $status='มีอัปเดต'; $eligible=$true }
        elseif ($latest -ne '?') { $status='ข้ามรุ่นที่ไม่รองรับ'; $detail+=' | ไม่ลดเวอร์ชันหรือเดารุ่น prerelease' }
        $row=New-Row $name $current $latest $status $detail $eligible
        $row | Add-Member -NotePropertyName ownerId -NotePropertyValue $plugin.pluginId
        $row | Add-Member -NotePropertyName sourceKind -NotePropertyValue 'codex-plugin'
        $row | Add-Member -NotePropertyName packagePath -NotePropertyValue $cache
        if ($RequestedMode -eq 'Update' -and $eligible) {
            try {
                # Re-read installed state immediately before mutation so a removed plugin is not reinstalled.
                $fresh=Invoke-CodexCli -Arguments @('plugin','list','--json')
                $stillInstalled=@($fresh.installed | Where-Object { $_.pluginId -eq $plugin.pluginId -and $_.installed -and $_.enabled })
                if ($stillInstalled.Count -ne 1) { throw 'รายการนี้ถูกถอนหรือปิดใช้งานแล้ว จึงข้ามการอัปเดต' }
                if ($plugin.pluginId -notmatch '^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+$') { throw 'รูปแบบ Plugin ID ไม่รองรับ' }
                $backup=Backup-Skills (Join-Path $cache 'skills') $plugin.name
                $result=Invoke-CodexCli -Arguments @('plugin','add',$plugin.pluginId,'--json') -TimeoutSeconds 180
                $after=Invoke-CodexCli -Arguments @('plugin','list','--json')
                $active=@($after.installed | Where-Object { $_.pluginId -eq $plugin.pluginId -and $_.installed -and $_.enabled -and [string]$_.version -eq $latest })
                if ($active.Count -ne 1) { throw 'ยังยืนยันเวอร์ชันที่ Codex ใช้งานหลังอัปเดตไม่ได้' }
                $expected=Join-Path (Split-Path -Parent $cache) $latest
                $verifyPath=Join-Path $expected '.codex-plugin\plugin.json'
                if (-not (Test-Path -LiteralPath $verifyPath)) { $verifyPath=Join-Path $expected 'plugin.json' }
                $verified=Read-JsonFile $verifyPath
                if (-not $verified -or [string]$verified.version -ne $latest -or -not (Test-Path -LiteralPath (Join-Path $expected 'skills'))) { throw 'คำสั่งเสร็จแล้ว แต่ยังยืนยันไฟล์รุ่นใหม่ไม่ได้ กรุณาเปิด Codex ตรวจสอบ' }
                $row.current=$latest; $row.status='อัปเดตแล้ว'; $row.canUpdate=$false
                $row.detail='สำรอง Skill เดิมแล้ว; เปิดแชตใหม่ใน Codex เพื่อโหลดรุ่นใหม่'
            } catch { $row.status='อัปเดตไม่สำเร็จ'; $row.detail=$_.Exception.Message }
        }
        $row
    }
}
function Get-LocalRows([string]$RequestedMode, $SkillRecord=$null) {
    $roots=@($script:Config.skillRoots)
    if ($SkillRecord) { $roots=@((Split-Path -Parent $SkillRecord.skillPath)) }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $folders=@(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { -not $_.Name.StartsWith('.') })
        if ($SkillRecord) { $folders=@(Get-Item -LiteralPath $SkillRecord.skillPath) }
        foreach ($folder in $folders) {
            if (-not (Test-Path -LiteralPath (Join-Path $folder.FullName 'SKILL.md'))) { continue }
            $version=Get-SkillVersion $folder.FullName
            $source=@($script:Config.localSources | Where-Object { [IO.Path]::GetFullPath($_.targetPath) -eq $folder.FullName }) | Select-Object -First 1
            if (-not $source) { New-Row $folder.Name $version '-' 'ดูแลเอง' 'Skill ที่สร้างเองหรือไม่มีแหล่งอัปเดต จึงเก็บไฟล์เดิมไว้'; continue }
            try {
                if (-not (Test-Path -LiteralPath (Join-Path $source.sourcePath 'SKILL.md'))) { throw 'ไม่พบต้นฉบับ Skill ในแพ็กเกจที่ติดตั้ง' }
                $sourceVersion=Get-SkillVersion $source.sourcePath
                $currentHash=Get-TreeHash $folder.FullName; $sourceHash=Get-TreeHash $source.sourcePath
                $baseline=$source.baselineHash
                $detail='ต้นฉบับจากแพ็กเกจ REA ที่ติดตั้งในเครื่อง เพื่อให้ตรงกับ MCP runtime'
                $status='ตรงกับ runtime'; $eligible=$false
                if ($currentHash -ne $sourceHash) {
                    if ($baseline -and $currentHash -eq $baseline) { $status='มีอัปเดต'; $eligible=$true }
                    else { $status='มีการแก้ไขเอง'; $detail='ไฟล์ต่างจากต้นฉบับและ baseline จึงข้ามเพื่อรักษาสิ่งที่คุณแก้ไว้' }
                }
                $row=New-Row $folder.Name $version $sourceVersion $status $detail $eligible
                if ($RequestedMode -eq 'Update' -and $eligible) {
                    $target=Assert-ChildPath $folder.FullName $root
                    $backup=Backup-Skills $target $folder.Name
                    $stage=Join-Path $script:DataPath ('staging\' + [guid]::NewGuid().ToString('N'))
                    Assert-ChildPath $stage $script:DataPath | Out-Null
                    [IO.Directory]::CreateDirectory((Split-Path -Parent $stage)) | Out-Null
                    Copy-Item -LiteralPath $source.sourcePath -Destination $stage -Recurse
                    if ((Get-TreeHash $stage) -ne $sourceHash) { throw 'ตรวจไฟล์ที่เตรียมอัปเดตไม่ผ่าน' }
                    # Recheck after staging to avoid overwriting edits made during download/copy.
                    if ((Get-TreeHash $target) -ne $currentHash) { throw 'Skill ถูกแก้ไขระหว่างอัปเดต จึงข้าม' }
                    $old=Join-Path $backup 'previous-folder'
                    Assert-ChildPath $old $script:DataPath | Out-Null
                    Move-Item -LiteralPath $target -Destination $old
                    try { Move-Item -LiteralPath $stage -Destination $target } catch { Move-Item -LiteralPath $old -Destination $target; throw }
                    # Keep the previous folder in app backups, outside Skill discovery roots.
                    $source.baselineHash=$sourceHash
                    Save-JsonFile $script:Config $script:SettingsFile
                    $row.current=$sourceVersion; $row.status='อัปเดตแล้ว'; $row.canUpdate=$false
                    $row.detail='อัปเดตจากแพ็กเกจที่ตรงกับ runtime พร้อมสำรองไฟล์เดิมแล้ว'
                }
                $row
            } catch { New-Row $folder.Name $version '?' 'ตรวจไม่ได้' $_.Exception.Message }
        }
    }
    if (-not $SkillRecord) { New-Row 'System Skills ของ Codex' 'ตามแอป' 'ตามแอป' 'แอปดูแล' 'imagegen, openai-docs, skill-creator และ skill-installer อัปเดตพร้อมแอป Codex' }
}
function Add-SkillRowMetadata($Row, $Skill) {
    $values=[ordered]@{
        name=$Skill.name; providers=@($Skill.providers); provider=(@($Skill.providers) -join ', ')
        scope=$Skill.scope; skillPath=$Skill.skillPath; sourceKind=$Skill.sourceKind
        ownerId=$Skill.ownerId; ownerKey=$Skill.ownerKey; enabled=$Skill.enabled
        identity=($Skill.skillPath.ToLowerInvariant() + '|' + (@($Skill.providers) -join ',') + '|' + $Skill.scope + '|' + $Skill.ownerKey)
        skillVersion=$Skill.version; packageVersion=$Skill.packageVersion
    }
    foreach ($key in $values.Keys) { $Row | Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force }
    return $Row
}
function Invoke-Updater([string]$RequestedMode) {
    $rows=New-Object 'Collections.Generic.List[object]'
    $problems=New-Object 'Collections.Generic.List[string]'
    $environment=Get-DiscoveryEnvironment -Config $script:Config
    if ($environment.codexHome) { $script:Config.codexHome=$environment.codexHome }
    $codexListing=[pscustomobject]@{installed=@()}
    $codexCliFound=$false
    try {
        $script:CodexExecutable=Resolve-Codex $script:Config
        $codexCliFound=$true
        $codexProvider=@($environment.providers | Where-Object { $_.name -eq 'Codex' }) | Select-Object -First 1
        if ($codexProvider) { $codexProvider.detected=$true; $codexProvider.cliPath=$script:CodexExecutable; $codexProvider.status='พบ CLI' }
        $codexListing=Invoke-CodexCli -Arguments @('plugin','list','--json')
    } catch { if ($codexCliFound) { $problems.Add('Codex: '+$_.Exception.Message) } }
    $claudeInventory=Get-ClaudePluginInventory -Config $script:Config
    $claudeProvider=@($environment.providers | Where-Object { $_.name -eq 'Claude Code' }) | Select-Object -First 1
    if ($claudeProvider) {
        $claudeProvider.detected=[bool]$claudeInventory.detected
        $claudeProvider.cliPath=$claudeInventory.cliPath
        $claudeProvider.detail=$claudeInventory.detail
        if ($claudeInventory.cliPath) { $claudeProvider.status='พบ CLI' }
        elseif ($claudeInventory.detected) { $claudeProvider.status='พบข้อมูล (ไม่พบ CLI)' }
    }
    foreach ($issue in @($claudeInventory.errors)) { if ($issue) { $problems.Add('Claude Code: '+[string]$issue) } }
    $discovery=Get-DiscoveredSkills -Config $script:Config -CodexPlugins @($codexListing.installed) -ClaudePlugins @($claudeInventory.plugins) -Environment $environment
    $codexPlans=@{}
    $codexOwnerIds=@($discovery.skills | Where-Object { $_.sourceKind -eq 'codex-plugin' -and $_.enabled -ne $false } | Select-Object -ExpandProperty ownerId -Unique)
    if (@($codexListing.installed).Count -gt 0 -and $codexOwnerIds.Count -gt 0) {
        try {
            foreach ($plan in Get-PluginRows $RequestedMode $codexListing $codexOwnerIds) { $codexPlans[$plan.ownerId]=$plan }
        } catch { $problems.Add('Codex Plugins: '+$_.Exception.Message) }
    }
    $claudePlans=@{}
    foreach ($plugin in @($claudeInventory.plugins)) {
        $owned=@($discovery.skills | Where-Object { $_.sourceKind -eq 'claude-plugin' -and $_.ownerKey -eq $plugin.ownerKey })
        if (@($owned | Where-Object { $_.enabled -ne $false }).Count -eq 0) { continue }
        try {
            $plan=Get-ClaudeUpdatePlan -Plugin $plugin -Config $script:Config
            if ($RequestedMode -eq 'Update' -and $plan.canUpdate -and $plugin.enabled) {
                $result=Invoke-ClaudePluginUpdate -Plugin $plugin -Config $script:Config -BackupRoot (Join-Path $script:DataPath 'backups')
                if ($result.status) { $plan.status=$result.status }
                if ($result.detail) { $plan.detail=$result.detail }
                if ($result.current) { $plan.current=$result.current }
                if ($result.latest) { $plan.latest=$result.latest }
                $plan.canUpdate=$false
            }
            $claudePlans[$plugin.ownerKey]=$plan
        } catch { $claudePlans[$plugin.ownerKey]=(New-Row $plugin.name $plugin.version '?' 'ตรวจไม่ได้' $_.Exception.Message) }
    }
    $changedPackages=@($codexPlans.Values | Where-Object { $_.status -eq 'อัปเดตแล้ว' }).Count + @($claudePlans.Values | Where-Object { $_.status -eq 'อัปเดตแล้ว' }).Count
    if ($changedPackages -gt 0) {
        if ($codexCliFound) {
            try { $codexListing=Invoke-CodexCli -Arguments @('plugin','list','--json') }
            catch { $problems.Add('ตรวจ Codex หลังอัปเดตไม่สำเร็จ: '+$_.Exception.Message) }
        }
        try { $claudeInventory=Get-ClaudePluginInventory -Config $script:Config }
        catch { $problems.Add('ตรวจ Claude Code หลังอัปเดตไม่สำเร็จ: '+$_.Exception.Message) }
        try { $discovery=Get-DiscoveredSkills -Config $script:Config -CodexPlugins @($codexListing.installed) -ClaudePlugins @($claudeInventory.plugins) -Environment $environment }
        catch { $problems.Add('ตรวจรายการ Skill หลังอัปเดตไม่สำเร็จ: '+$_.Exception.Message) }
    }
    foreach ($skill in @($discovery.skills)) {
        $row=$null
        try {
        if ($skill.enabled -eq $false) {
            $row=New-Row $skill.name $skill.version '-' 'ปิดใช้งาน' 'พบ Skill ในเครื่อง แต่ถูกปิดใช้งาน จึงข้ามการอัปเดต'
        } elseif ($skill.sourceKind -eq 'codex-plugin') {
            $plan=$codexPlans[$skill.ownerId]
            if ($plan) {
                $row=New-Row $skill.name $plan.current $plan.latest $plan.status $plan.detail $plan.canUpdate
                $row.detail+=' | แพ็กเกจ: '+$skill.ownerId
            } else { $row=New-Row $skill.name $skill.version '?' 'ตรวจไม่ได้' 'พบไฟล์ Skill แต่ยังตรวจข้อมูลเวอร์ชันปลั๊กอินไม่ได้' }
        } elseif ($skill.sourceKind -eq 'claude-plugin') {
            $plan=$claudePlans[$skill.ownerKey]
            if ($plan) { $row=New-Row $skill.name $plan.current $plan.latest $plan.status $plan.detail ([bool]$plan.canUpdate) }
            else { $row=New-Row $skill.name $skill.version '?' 'ตรวจไม่ได้' 'พบ Skill ของ Claude Code แต่ยังตรวจต้นทางแพ็กเกจไม่ได้' }
        } elseif ($skill.sourceKind -in @('system','synced','claude-synced')) {
            $row=New-Row $skill.name $skill.version 'ตามแอป' 'แอปดูแล' 'Skill ที่จัดการโดยแอปหรือการซิงก์ จะอัปเดตจากแอปต้นทาง'
        } else {
            $local=@(Get-LocalRows $RequestedMode $skill)
            if ($local.Count -gt 0) { $row=$local[0] }
            else { $row=New-Row $skill.name $skill.version '-' 'ดูแลเอง' 'ไม่พบแหล่งอัปเดตที่ยืนยันได้' }
        }
        } catch { $row=New-Row $skill.name $skill.version '?' 'ตรวจไม่ได้' ('Skill อาจถูกย้ายหรือแก้ไขระหว่างตรวจ: '+$_.Exception.Message) }
        $rows.Add((Add-SkillRowMetadata $row $skill))
    }
    $providerStats=New-Object 'Collections.Generic.List[object]'
    foreach ($providerName in @('Codex','Claude Code')) {
        $provider=@($discovery.providers | Where-Object { $_.name -eq $providerName }) | Select-Object -First 1
        $providerCount=@($rows | Where-Object { @($_.providers) -contains $providerName }).Count
        $detected=($providerCount -gt 0 -or ($provider -and $provider.detected))
        $detail=''
        $status='ไม่พบในเครื่อง'
        if ($provider) { $detail=[string]$provider.detail; if ($provider.status) { $status=[string]$provider.status } }
        if ($detected -and $status -eq 'ไม่พบในเครื่อง') { $status='พบ Skill (ไม่พบ CLI)' }
        $providerStats.Add([pscustomobject]@{name=$providerName;detected=$detected;skillCount=$providerCount;status=$status;detail=$detail})
    }
    $updated=@($rows | Where-Object {$_.status -eq 'อัปเดตแล้ว'}).Count
    $errors=@($rows | Where-Object {$_.status -in @('ตรวจไม่ได้','อัปเดตไม่สำเร็จ')}).Count + $problems.Count
    $available=@($rows | Where-Object {$_.canUpdate}).Count
    $manual=@($rows | Where-Object {$_.status -in @('ดูแลเอง','มีการแก้ไขเอง','แอปดูแล','ข้ามรุ่นที่ไม่รองรับ','ตรวจผ่าน Claude','ต้องใช้ Claude CLI','ดูแลต้นทาง','Claude ดูแล')}).Count
    $packageReady=@($rows | Where-Object {$_.canUpdate} | ForEach-Object { if ($_.ownerKey) { $_.ownerKey } elseif ($_.ownerId) { $_.ownerId } else { $_.skillPath } } | Select-Object -Unique).Count
    $summary="พบ $($rows.Count) Skill | อัปเดตแล้ว $updated | พร้อมอัปเดต $available | ตรวจไม่ได้/ผิดพลาด $errors | ดูแลแยก $manual"
    $problem=$null
    if ($problems.Count -gt 0) { $problem=($problems.ToArray() -join "`r`n") }
    return [pscustomobject]@{ checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'); mode=$RequestedMode; summary=$summary; error=$problem; rows=@($rows.ToArray()); updatedCount=$updated; errorCount=$errors; manualCount=$manual; availableCount=$available; availablePackageCount=$packageReady; detectedSkillCount=$rows.Count; providerStats=@($providerStats.ToArray()); discoveryRoots=@($discovery.roots); warnings=@($discovery.warnings) }
}

foreach ($helperName in @('ClaudeSupport.ps1','Discovery.ps1')) {
    $helperPath=Join-Path $PSScriptRoot $helperName
    if (Test-Path -LiteralPath $helperPath) { . $helperPath }
}
if ($LibraryOnly) { return }
$script:SettingsFile=[IO.Path]::GetFullPath($SettingsPath)
$script:Config=Read-JsonFile $script:SettingsFile
if (-not $script:Config) { throw 'ไม่พบ settings.json' }
$script:DataPath=Join-Path $PSScriptRoot 'data'
[IO.Directory]::CreateDirectory($script:DataPath) | Out-Null
if (-not $OutputPath) { $OutputPath=Join-Path $script:DataPath 'latest.json' }
$lock=$null
try {
    $lockDeadline=[datetime]::UtcNow
    if ($Mode -eq 'Update') { $lockDeadline=$lockDeadline.AddSeconds(120) }
    while (-not $lock) {
        try { $lock=[IO.File]::Open((Join-Path $script:DataPath 'operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch {
            if ([datetime]::UtcNow -ge $lockDeadline) { throw 'มีการตรวจหรืออัปเดต Skill กำลังทำงานอยู่ กรุณารอสักครู่แล้วกดตรวจใหม่' }
            Start-Sleep -Milliseconds 1000
        }
    }
    $report=Invoke-Updater $Mode
    Save-JsonFile $report (Join-Path $script:DataPath 'latest.json')
    Save-JsonFile $report $OutputPath
    $logPath=Join-Path $script:DataPath 'history.jsonl'
    [IO.File]::AppendAllText($logPath, (($report | ConvertTo-Json -Depth 18 -Compress)+[Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
} catch {
    $report=[pscustomobject]@{checkedAt=(Get-Date).ToString('s');summary='ตรวจหรืออัปเดตไม่สำเร็จ';error=$_.Exception.Message;rows=@();updatedCount=0;errorCount=1;manualCount=0}
    Save-JsonFile $report $OutputPath
    exit 1
} finally { if ($lock) { $lock.Dispose() } }
