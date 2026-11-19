# Compiles every scripting\*.sp into plugins\*.smx using the spcomp that ships
# with the SourceMod install on the local test server.
#   .\build.ps1            compile only
#   .\build.ps1 -Deploy    compile, then copy the .smx files to the server
#   .\build.ps1 -Package   compile, then write plugins\afkbomb-<version>.zip (the release zip)
# Shared includes come from the incs submodule (github.com/Ballganda/SourceMod-Incs):
#   git submodule update --init
param(
    [switch]$Deploy,
    [switch]$Package,
    [string]$SourceModDir = $(if ($env:SOURCEMOD_DIR) { $env:SOURCEMOD_DIR } else { 'C:\Users\user\cssds\cstrike\addons\sourcemod' })
)

$spcomp = Join-Path $SourceModDir 'scripting\spcomp.exe'
if (-not (Test-Path $spcomp)) { Write-Error "spcomp not found at $spcomp"; exit 1 }

$src = Join-Path $PSScriptRoot 'scripting'
$incs = Join-Path $PSScriptRoot 'incs\scripting\include'
$out = Join-Path $PSScriptRoot 'plugins'
if (-not (Test-Path (Join-Path $incs 'instance_config.inc'))) {
    Write-Error "Shared includes missing at $incs. Run: git submodule update --init"; exit 1
}
New-Item -ItemType Directory -Force $out | Out-Null

$failed = 0
# scripting\*.sp = the plugin; tests\*.sp = regression plugins (run `afkbomb_test` on the server)
$targets = @(Get-ChildItem $src -Filter *.sp) + @(Get-ChildItem (Join-Path $PSScriptRoot 'tests') -Filter *.sp -ErrorAction SilentlyContinue)
foreach ($sp in $targets) {
    $smx = Join-Path $out ($sp.BaseName + '.smx')
    & $spcomp $sp.FullName "-i$src\include" "-i$incs" "-i$SourceModDir\scripting\include" "-o$smx"
    if ($LASTEXITCODE -ne 0) { $failed++; continue }
    if ($Deploy) {
        Copy-Item $smx (Join-Path $SourceModDir 'plugins') -Force
        Write-Host "Deployed $($sp.BaseName).smx"
    }
}
if ($Deploy -and (Test-Path "$PSScriptRoot\translations")) {
    Copy-Item "$PSScriptRoot\translations\*" (Join-Path $SourceModDir 'translations') -Recurse -Force
    Write-Host 'Deployed translations'
}
if ($failed) { Write-Error "$failed plugin(s) failed to compile"; exit 1 }

if ($Package) {
    # Release zip: extracted into the server's cstrike folder. Only the plugin, never the test suite.
    $version = (Select-String -Path "$src\afkbomb.sp" -Pattern '#define\s+PLUGIN_VERSION\s+"([^"]+)"').Matches[0].Groups[1].Value
    if (-not $version) { Write-Error 'PLUGIN_VERSION not found in afkbomb.sp'; exit 1 }
    $stage = Join-Path $out 'package'
    $sm = Join-Path $stage 'addons\sourcemod'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force "$sm\plugins", "$sm\translations", "$sm\scripting\include" | Out-Null
    Copy-Item "$out\afkbomb.smx" "$sm\plugins"
    Copy-Item "$PSScriptRoot\translations\afkbomb.phrases.txt" "$sm\translations"
    Copy-Item "$src\afkbomb.sp" "$sm\scripting"
    # GPL v3 text beside the source (not addons/sourcemod/LICENSE.txt, which is SourceMod's own)
    Copy-Item "$PSScriptRoot\LICENSE" "$sm\scripting\afkbomb-LICENSE.txt"
    # every include afkbomb.sp uses from the submodule, so the zip recompiles on its own
    foreach ($inc in Get-ChildItem $incs -Filter *.inc) {
        if (Select-String -Path "$src\afkbomb.sp" -Pattern "#include\s+<$($inc.BaseName)>" -Quiet) {
            Copy-Item $inc.FullName "$sm\scripting\include"
        }
    }
    $zip = Join-Path $out "afkbomb-$version.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    # not Compress-Archive: on Windows PowerShell 5.1 it writes `\` into entry names, which Linux unzip keeps literally
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $entry = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry)
        }
    } finally { $archive.Dispose() }
    Remove-Item $stage -Recurse -Force
    Write-Host "Packaged $zip"
}
