$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework C# compiler was not found.' }
$sourcePaths = @('SkillUpdater.cs', 'CaptionButton.cs', 'LocaleSupport.cs', 'AppearanceDialog.cs', 'ResponsiveLayout.cs', 'IntegralDetailsBox.cs', 'UiViewCache.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
$outputPath = Join-Path $PSScriptRoot 'SkillUpdater.exe'
$iconPath = Join-Path $PSScriptRoot 'app-icon.ico'
if (-not (Test-Path -LiteralPath $iconPath)) { throw 'The app-icon.ico asset is missing from the application folder.' }
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu /utf8output /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll "/win32icon:$iconPath" "/out:$outputPath" $sourcePaths
if ($LASTEXITCODE -ne 0) { throw "Build failed: $LASTEXITCODE" }
Write-Output (Join-Path $PSScriptRoot 'SkillUpdater.exe')
