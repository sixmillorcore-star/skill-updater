# Claude Code support. Loading this file performs no filesystem writes or CLI calls.
# Official references:
# https://code.claude.com/docs/en/plugins/cli-reference
# https://code.claude.com/docs/en/plugins/loading

function Get-CsuValue($Object, [string]$Name, $Fallback=$null) {
    if ($null -eq $Object) { return $Fallback }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $Fallback }
    $property=$Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Fallback
}
function Read-CsuJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path).Length -gt 16777216) { throw 'Claude metadata file is too large.' }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Get-ClaudeConfigDirectory($Config) {
    $configured=$env:CLAUDE_CONFIG_DIR
    if (-not $configured) { $configured=Get-CsuValue $Config 'claudeConfigDir' }
    if (-not $configured) { $configured=Get-CsuValue $Config 'claudeHome' }
    if (-not $configured) {
        $userRoot=Get-CsuValue $Config 'userHome' $env:USERPROFILE
        $configured=Join-Path $userRoot '.claude'
    }
    return [IO.Path]::GetFullPath($configured).TrimEnd('\','/')
}
function Get-ClaudePluginRoot($Config) {
    $configured=$env:CLAUDE_CODE_PLUGIN_CACHE_DIR
    if (-not $configured) { $configured=Get-CsuValue $Config 'claudePluginRoot' }
    if (-not $configured) { $configured=Join-Path (Get-ClaudeConfigDirectory $Config) 'plugins' }
    return [IO.Path]::GetFullPath($configured).TrimEnd('\','/')
}
function Resolve-ClaudeCli($Config) {
    $configured=Get-CsuValue $Config 'claudePath'
    if ($configured -and (Test-Path -LiteralPath $configured -PathType Leaf)) { return [IO.Path]::GetFullPath($configured) }
    foreach ($name in @('claude.exe','claude.cmd','claude')) {
        $command=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    $userRoot=Get-CsuValue $Config 'userHome' $env:USERPROFILE
    $candidates=@((Join-Path $userRoot '.local\bin\claude.exe'),(Join-Path $userRoot 'Tools\npm\claude.cmd'))
    if ($env:APPDATA) { $candidates+=(Join-Path $env:APPDATA 'npm\claude.cmd') }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    return $null
}
function ConvertTo-CsuWindowsArgument([string]$Value) {
    return '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-ClaudeCli([string]$CliPath,[string[]]$Arguments,[string]$WorkingDirectory,[string]$ConfigDirectory,[string]$PluginCacheDirectory,[int]$TimeoutSeconds=30) {
    if (-not $CliPath -or -not (Test-Path -LiteralPath $CliPath -PathType Leaf)) { throw 'ไม่พบ Claude Code CLI' }
    $start=New-Object Diagnostics.ProcessStartInfo
    if ([IO.Path]::GetExtension($CliPath) -in @('.cmd','.bat','.ps1')) {
        # Execute a literal argument array through PowerShell, not string-built cmd syntax.
        $tokens=@($Arguments | ForEach-Object { "'"+$_.Replace("'","''")+"'" })
        $scriptText="`$ErrorActionPreference='Stop';`$OutputEncoding=New-Object Text.UTF8Encoding(`$false);[Console]::OutputEncoding=`$OutputEncoding; & '"+$CliPath.Replace("'","''")+"' "+($tokens -join ' ')+"; exit `$LASTEXITCODE"
        $start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
    } else {
        $start.FileName=$CliPath
        $start.Arguments=(@($Arguments | ForEach-Object { ConvertTo-CsuWindowsArgument $_ }) -join ' ')
    }
    $start.WorkingDirectory=$WorkingDirectory
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.RedirectStandardInput=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8; $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    if ($ConfigDirectory) { $start.EnvironmentVariables['CLAUDE_CONFIG_DIR']=$ConfigDirectory }
    if ($PluginCacheDirectory) { $start.EnvironmentVariables['CLAUDE_CODE_PLUGIN_CACHE_DIR']=$PluginCacheDirectory }
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    try {
        $process.Start() | Out-Null; $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds*1000)) { $process.Kill(); $process.WaitForExit(); throw 'Claude Code ใช้เวลานานเกินกำหนด กรุณาลองอีกครั้ง' }
        return [pscustomobject]@{exitCode=$process.ExitCode;stdout=$stdout.Result;stderr=$stderr.Result}
    } finally { $process.Dispose() }
}
function Get-ClaudeOwnerKey([string]$PluginId,[string]$Scope,[string]$ProjectPath) {
    $project=''
    if ($ProjectPath) { $project=[IO.Path]::GetFullPath($ProjectPath).TrimEnd('\','/') }
    return $PluginId+'|'+$Scope+'|'+$project
}
function Get-CsuEnabledSetting([string]$ConfigDir,[string]$PluginId,[string]$ProjectPath) {
    $enabled=$true
    $paths=@((Join-Path $ConfigDir 'settings.json'))
    if ($ProjectPath) { $paths+=@((Join-Path $ProjectPath '.claude\settings.json'),(Join-Path $ProjectPath '.claude\settings.local.json')) }
    foreach ($path in $paths) {
        $settings=Read-CsuJson $path
        $declarations=Get-CsuValue $settings 'enabledPlugins'
        if ($declarations -and $declarations.PSObject.Properties[$PluginId]) { $enabled=($declarations.PSObject.Properties[$PluginId].Value -ne $false) }
    }
    return $enabled
}
function ConvertTo-CsuPlugin($Entry,[string]$PluginId,[string]$ConfigDir,[string]$PluginRoot,[string]$CliPath,[string]$Origin) {
    if (-not $PluginId) { $PluginId=[string](Get-CsuValue $Entry 'id' (Get-CsuValue $Entry 'pluginId')) }
    if (-not $PluginId) { return $null }
    $scope=[string](Get-CsuValue $Entry 'scope' 'user')
    $project=[string](Get-CsuValue $Entry 'projectPath' '')
    if ($project -and -not [IO.Path]::IsPathRooted($project)) { throw 'Claude plugin projectPath is not absolute.' }
    $install=[string](Get-CsuValue $Entry 'readFromFolder' '')
    if (-not $install) { $install=[string](Get-CsuValue $Entry 'installPath' '') }
    if ($install -and -not [IO.Path]::IsPathRooted($install)) { throw 'Claude plugin installPath is not absolute.' }
    if ($install) { $install=[IO.Path]::GetFullPath($install).TrimEnd('\','/') }
    $version=[string](Get-CsuValue $Entry 'folderVersion' '')
    if (-not $version) { $version=[string](Get-CsuValue $Entry 'version' 'ไม่ระบุ') }
    $enabledSetting=Get-CsuValue $Entry 'enabled'
    if ($null -eq $enabledSetting) { $enabledSetting=Get-CsuEnabledSetting $ConfigDir $PluginId $project }
    $parts=$PluginId.Split('@',2)
    return [pscustomobject]@{
        ownerKey=(Get-ClaudeOwnerKey $PluginId $scope $project);pluginKey=(Get-ClaudeOwnerKey $PluginId $scope $project)
        pluginId=$PluginId;name=$parts[0];marketplaceName=$(if($parts.Length -eq 2){$parts[1]}else{''})
        scope=$scope;projectPath=$project;installPath=$install;version=$version;enabled=[bool]$enabledSetting
        configDir=$ConfigDir;pluginRoot=$PluginRoot;cliPath=$CliPath;inventorySource=$Origin
        readFromFolder=[string](Get-CsuValue $Entry 'readFromFolder' '')
    }
}
function Get-ClaudePluginInventory($Config,[switch]$SkipCli) {
    $errors=New-Object 'Collections.Generic.List[string]'
    $plugins=New-Object 'Collections.Generic.List[object]'
    $configDir=Get-ClaudeConfigDirectory $Config
    $pluginRoot=Get-ClaudePluginRoot $Config
    $cli=Resolve-ClaudeCli $Config
    $registryPath=Join-Path $pluginRoot 'installed_plugins.json'
    $hasRegistry=Test-Path -LiteralPath $registryPath -PathType Leaf
    if ($hasRegistry) {
        try {
            $registry=Read-CsuJson $registryPath
            $entries=Get-CsuValue $registry 'plugins'
            if ($null -eq $entries) { throw 'Claude registry has no plugins object.' }
            foreach ($property in $entries.PSObject.Properties) {
                foreach ($entry in @($property.Value)) {
                    try { $normalized=ConvertTo-CsuPlugin $entry $property.Name $configDir $pluginRoot $cli 'registry'; if ($normalized) { $plugins.Add($normalized) } }
                    catch { $errors.Add('อ่านรายการ Claude plugin ไม่สำเร็จ: '+$_.Exception.Message) }
                }
            }
        } catch { $errors.Add('อ่าน installed_plugins.json ไม่สำเร็จ: '+$_.Exception.Message) }
    }
    if ($cli -and -not $SkipCli) {
        try {
            $working=Get-CsuValue $Config 'workingDirectory' $PSScriptRoot
            if (-not (Test-Path -LiteralPath $working -PathType Container)) { $working=$PSScriptRoot }
            $result=Invoke-ClaudeCli -CliPath $cli -Arguments @('plugin','list','--json') -WorkingDirectory $working -ConfigDirectory $configDir -PluginCacheDirectory $pluginRoot
            if ($result.exitCode -ne 0) { throw ('Claude plugin list exit '+$result.exitCode) }
            $json=$result.stdout | ConvertFrom-Json
            $cliEntries=@($json)
            if ($json.PSObject.Properties['installed']) { $cliEntries=@($json.installed) }
            elseif ($json.PSObject.Properties['plugins']) { $cliEntries=@($json.plugins) }
            foreach ($entry in $cliEntries) {
                # Some CLI versions return less installation metadata than the registry.
                # Overlay only supplied fields; never erase the path needed for discovery.
                $entryId=[string](Get-CsuValue $entry 'id' (Get-CsuValue $entry 'pluginId' ''))
                $entryScope=[string](Get-CsuValue $entry 'scope' 'user')
                $entryProject=[string](Get-CsuValue $entry 'projectPath' '')
                $entryKey=Get-ClaudeOwnerKey $entryId $entryScope $entryProject
                $prior=@($plugins | Where-Object { $_.ownerKey -eq $entryKey })
                if ($prior.Count -eq 0 -and -not $entryProject) {
                    $prior=@($plugins | Where-Object { $_.pluginId -eq $entryId -and $_.scope -eq $entryScope })
                }
                if ($prior.Count -gt 1) {
                    $errors.Add('Claude CLI ไม่ระบุโครงการให้ชัดเจน จึงเก็บข้อมูลการติดตั้งแต่ละ scope จาก registry')
                    continue
                }
                $merged=$entry
                if ($prior.Count -eq 1) {
                    $saved=$prior[0]
                    $merged=[ordered]@{id=$saved.pluginId;scope=$saved.scope;projectPath=$saved.projectPath;installPath=$saved.installPath;version=$saved.version;enabled=$saved.enabled;readFromFolder=$saved.readFromFolder}
                    foreach ($field in @('id','pluginId','scope','projectPath','installPath','version','folderVersion','enabled','readFromFolder')) {
                        $value=Get-CsuValue $entry $field
                        if ($null -eq $value) { continue }
                        if ($field -ne 'enabled' -and [string]::IsNullOrWhiteSpace([string]$value)) { continue }
                        $merged[$field]=$value
                    }
                }
                $normalized=ConvertTo-CsuPlugin $merged '' $configDir $pluginRoot $cli 'cli'
                if (-not $normalized) { continue }
                $existing=@($plugins | Where-Object { $_.ownerKey -eq $normalized.ownerKey })
                foreach ($old in $existing) { $plugins.Remove($old) | Out-Null }
                $plugins.Add($normalized)
            }
        } catch { $errors.Add('ตรวจรายการผ่าน Claude CLI ไม่สำเร็จ; ใช้ข้อมูลที่อ่านได้จากดิสก์: '+$_.Exception.Message) }
    }
    $detected=[bool]($cli -or (Test-Path -LiteralPath $configDir -PathType Container) -or $hasRegistry)
    $detail='ยังไม่พบ Claude Code หรือโฟลเดอร์การตั้งค่า'
    if ($detected) { $detail='พบ Claude Code/โฟลเดอร์การตั้งค่า; ปลั๊กอิน '+$plugins.Count+' การติดตั้ง' }
    if ($detected -and -not $cli) { $detail+='; อ่าน Skill ได้ แต่อัปเดตปลั๊กอินต้องมี Claude CLI' }
    return [pscustomobject]@{plugins=@($plugins.ToArray());detected=$detected;cliPath=$cli;configDir=$configDir;pluginRoot=$pluginRoot;errors=@($errors.ToArray());detail=$detail}
}
function Get-CsuSkillRoots($Plugin) {
    $base=$Plugin.installPath
    if (-not $base -or -not (Test-Path -LiteralPath $base -PathType Container)) { return @() }
    $candidates=@((Join-Path $base 'skills'))
    if (Test-Path -LiteralPath (Join-Path $base 'SKILL.md')) { $candidates+=$base }
    $manifest=Read-CsuJson (Join-Path $base '.claude-plugin\plugin.json')
    foreach ($declaration in @(Get-CsuValue $manifest 'skills')) {
        if ($declaration -isnot [string] -or -not $declaration) { continue }
        $path=[IO.Path]::GetFullPath((Join-Path $base $declaration))
        $prefix=[IO.Path]::GetFullPath($base).TrimEnd('\')+'\'
        if ($path -eq $prefix.TrimEnd('\') -or $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $candidates+=$path }
    }
    return @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique)
}
function Get-CsuSafeFiles([string]$Root) {
    $pending=New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root);$count=0
    while ($pending.Count) {
        $folder=Get-Item -LiteralPath $pending.Pop()
        if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked Skill folders require review in Claude Code.' }
        foreach ($item in Get-ChildItem -LiteralPath $folder.FullName -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked Skill files require review in Claude Code.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $count++; if ($count -gt 20000) { throw 'Skill backup exceeds the file limit.' }; $item }
        }
    }
}
function Get-CsuPluginSkillHash($Plugin) {
    $parts=New-Object 'Collections.Generic.List[string]'
    foreach ($root in Get-CsuSkillRoots $Plugin) {
        foreach ($file in @(Get-CsuSafeFiles $root | Sort-Object FullName)) {
            $relative=$file.FullName.Substring([IO.Path]::GetFullPath($Plugin.installPath).Length).Replace('\','/')
            $parts.Add($relative+':'+(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)
        }
    }
    if ($parts.Count -eq 0) { return $null }
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes((@($parts | Sort-Object -Unique) -join "`n"))))).Replace('-','') }
    finally { $hash.Dispose() }
}
function Compare-CsuNumericVersion([string]$Left,[string]$Right) {
    if ($Left -notmatch '^\d+(\.\d+){0,3}$' -or $Right -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    $leftParts=@($Left.Split('.'));$rightParts=@($Right.Split('.'))
    for ($i=0;$i -lt 4;$i++) {
        $a=0L;$b=0L
        if ($i -lt $leftParts.Count) { $a=[long]$leftParts[$i] }
        if ($i -lt $rightParts.Count) { $b=[long]$rightParts[$i] }
        if ($a -gt $b) { return 1 };if ($a -lt $b) { return -1 }
    }
    return 0
}
function Get-ClaudeUpdatePlan($Plugin,$Config) {
    $current=[string]$Plugin.version
    $plan=[pscustomobject]@{ownerKey=$Plugin.ownerKey;current=$current;latest='?';status='ตรวจผ่าน Claude';detail='ยังยืนยันรุ่นล่าสุดไม่ได้จากข้อมูล marketplace ที่มี; ตรวจด้วย Claude Code ได้';canUpdate=$false}
    if (-not $Plugin.enabled) { $plan.status='ปิดใช้งาน';$plan.detail='ปลั๊กอินนี้ปิดใช้งานอยู่';return $plan }
    if ($Plugin.scope -notin @('user','project','local','managed') -or $Plugin.marketplaceName -in @('inline','skills-dir','synced')) { $plan.status='Claude ดูแล';$plan.detail='รายการนี้ไม่ใช่ปลั๊กอิน marketplace ที่อัปเดตผ่านคำสั่ง plugin update';return $plan }
    if ($Plugin.readFromFolder) { $plan.status='ดูแลต้นทาง';$plan.detail='Claude โหลดปลั๊กอินจากโฟลเดอร์ต้นทางโดยตรง จึงไม่เขียนทับไฟล์ที่นี่';return $plan }
    try {
        $known=Read-CsuJson (Join-Path $Plugin.pluginRoot 'known_marketplaces.json')
        $market=Get-CsuValue $known $Plugin.marketplaceName
        $location=[string](Get-CsuValue $market 'installLocation' '')
        if (-not $location -or -not (Test-Path -LiteralPath $location -PathType Container)) { return $plan }
        $catalog=Read-CsuJson (Join-Path $location '.claude-plugin\marketplace.json')
        $entry=@((Get-CsuValue $catalog 'plugins' @()) | Where-Object { (Get-CsuValue $_ 'name') -eq $Plugin.name }) | Select-Object -First 1
        if (-not $entry) { return $plan }
        $source=Get-CsuValue $entry 'source'
        if ((Get-CsuValue $source 'source') -eq 'command') { $plan.detail='แหล่งอัปเดตใช้คำสั่งติดตั้ง ต้องตรวจและยืนยันใน Claude Code';return $plan }
        $latest=[string](Get-CsuValue $entry 'version' '')
        if ($source -is [string] -and $source.StartsWith('./')) {
            $sourcePath=[IO.Path]::GetFullPath((Join-Path $location $source))
            $prefix=[IO.Path]::GetFullPath($location).TrimEnd('\')+'\'
            if ($sourcePath -ne $prefix.TrimEnd('\') -and -not $sourcePath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Marketplace source path escapes its folder.' }
            $sourceManifest=Read-CsuJson (Join-Path $sourcePath '.claude-plugin\plugin.json')
            if (Get-CsuValue $sourceManifest 'version') { $latest=[string](Get-CsuValue $sourceManifest 'version') }
        }
        if (-not $latest) { return $plan }
        $plan.latest=$latest
        $stamp=[string](Get-CsuValue $market 'lastUpdated' 'ไม่ระบุเวลา')
        $plan.detail='ตรวจจาก marketplace ในเครื่อง (อัปเดต '+$stamp+'); ไม่ได้อ้างว่าเป็น release ออนไลน์ล่าสุด'
        if ($latest -eq $current) { $plan.status='ตรงกับ catalog';return $plan }
        $numeric='^\d+(\.\d+){1,3}$'
        if ($latest -match $numeric -and $current -match $numeric -and [version]$latest -gt [version]$current) {
            if ($Plugin.cliPath) { $plan.status='มีอัปเดต';$plan.canUpdate=$true }
            else { $plan.status='ต้องใช้ Claude CLI';$plan.detail+='; ไม่พบ CLI สำหรับอัปเดต' }
        }
    } catch { $plan.status='ตรวจไม่ได้';$plan.detail=$_.Exception.Message }
    return $plan
}
function Invoke-ClaudePluginUpdate($Plugin,$Config,[string]$BackupRoot) {
    $result=[pscustomobject]@{ownerKey=$Plugin.ownerKey;current=[string]$Plugin.version;latest='?';status='อัปเดตไม่สำเร็จ';detail='';canUpdate=$false;changed=$false;backupPath=$null}
    try {
        $inventory=Get-ClaudePluginInventory -Config $Config
        $fresh=@($inventory.plugins | Where-Object { $_.ownerKey -eq $Plugin.ownerKey -and $_.enabled })
        if ($fresh.Count -ne 1) { throw 'ปลั๊กอินนี้ถูกถอนหรือปิดใช้งานแล้ว จึงไม่อัปเดตหรือติดตั้งกลับ' }
        $active=$fresh[0]
        if ($active.pluginId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'รูปแบบ Claude plugin ID ไม่รองรับ' }
        if ($active.scope -notin @('user','project','local','managed') -or $active.marketplaceName -in @('inline','skills-dir','synced') -or $active.readFromFolder) { throw 'ต้องดูแลปลั๊กอินต้นทางนี้ผ่าน Claude Code' }
        if (-not $inventory.cliPath) { throw 'อ่าน Skill ได้ แต่ต้องติดตั้ง Claude Code CLI เพื่ออัปเดตปลั๊กอิน' }
        $working=$PSScriptRoot
        if ($active.scope -in @('project','local')) {
            if (-not $active.projectPath -or -not (Test-Path -LiteralPath $active.projectPath -PathType Container)) { throw 'ไม่พบโฟลเดอร์โครงการของ scope นี้' }
            $working=$active.projectPath
        }
        $expectedPlan=Get-ClaudeUpdatePlan -Plugin $active -Config $Config
        $beforeHash=Get-CsuPluginSkillHash $active
        if (-not $beforeHash) { throw 'ไม่พบไฟล์ Skill สำหรับสำรองและตรวจสอบ' }
        $backupBase=[IO.Path]::GetFullPath($BackupRoot).TrimEnd('\','/')
        $pluginBase=[IO.Path]::GetFullPath($active.installPath).TrimEnd('\','/')
        if ($backupBase -eq $pluginBase -or $backupBase.StartsWith($pluginBase+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup must be outside the plugin directory.' }
        $backup=Join-Path $backupBase ('claude-'+($active.name -replace '[^A-Za-z0-9._-]','_')+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        $index=0
        foreach ($root in Get-CsuSkillRoots $active) { Get-CsuSafeFiles $root | Out-Null; Copy-Item -LiteralPath $root -Destination (Join-Path $backup ('skills-'+$index)) -Recurse; $index++ }
        $result.backupPath=$backup
        $record=[pscustomobject]@{pluginId=$active.pluginId;scope=$active.scope;projectPath=$active.projectPath;installPath=$active.installPath;version=$active.version;skillHash=$beforeHash}
        [IO.File]::WriteAllText((Join-Path $backup 'metadata.json'),($record | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        # No -y: changed marketplace install commands remain for the user to review in Claude.
        $command=Invoke-ClaudeCli -CliPath $inventory.cliPath -Arguments @('plugin','update',$active.pluginId,'--scope',$active.scope) -WorkingDirectory $working -ConfigDirectory $inventory.configDir -PluginCacheDirectory $active.pluginRoot -TimeoutSeconds 180
        if ($command.exitCode -ne 0) { throw ('Claude Code ปฏิเสธหรืออัปเดตไม่สำเร็จ (รหัส '+$command.exitCode+'); เปิด Claude Code เพื่อตรวจข้อความหรือคำสั่งติดตั้งที่ต้องยืนยัน') }
        $after=Get-ClaudePluginInventory -Config $Config
        $verified=@($after.plugins | Where-Object { $_.ownerKey -eq $active.ownerKey -and $_.enabled })
        if ($verified.Count -ne 1) { throw 'ยังยืนยันการติดตั้งที่เปิดใช้งานหลังอัปเดตไม่ได้' }
        $new=$verified[0];$afterHash=Get-CsuPluginSkillHash $new
        if (-not $afterHash) { throw 'คำสั่งเสร็จ แต่ยังยืนยันไฟล์ Skill หลังอัปเดตไม่ได้' }
        $result.current=[string]$new.version;$result.latest=[string]$new.version
        $comparedToOld=Compare-CsuNumericVersion ([string]$new.version) ([string]$active.version)
        if ($null -ne $comparedToOld -and $comparedToOld -lt 0) {
            throw ('เวอร์ชันหลังคำสั่งลดลงจาก '+$active.version+' เป็น '+$new.version+' จึงไม่ยืนยันว่าอัปเดตสำเร็จ; เก็บสำเนา Skill เดิมไว้แล้ว')
        }
        $comparedToExpected=Compare-CsuNumericVersion ([string]$new.version) ([string]$expectedPlan.latest)
        if ($comparedToOld -eq 1 -and $null -ne $comparedToExpected -and $comparedToExpected -lt 0) {
            $result.latest=[string]$expectedPlan.latest
            throw ('เวอร์ชันหลังคำสั่งยังไม่ถึงรุ่น '+$expectedPlan.latest+' ที่ตรวจพบ จึงยังยืนยันการอัปเดตไม่ได้; เก็บสำเนา Skill เดิมไว้แล้ว')
        }
        if ([string]$new.version -ne [string]$active.version -or $afterHash -ne $beforeHash) {
            $result.status='อัปเดตแล้ว';$result.changed=$true;$result.detail='สำรอง Skill เดิมแล้ว; เริ่ม Claude Code ใหม่หรือใช้ /reload-plugins เพื่อโหลดรุ่นใหม่'
        } else { $result.status='ไม่มีการเปลี่ยนแปลง';$result.detail='Claude Code รันคำสั่งตรวจ/อัปเดตสำเร็จ แต่เวอร์ชันและไฟล์ Skill ไม่เปลี่ยน' }
    } catch { $result.detail=$_.Exception.Message }
    return $result
}
