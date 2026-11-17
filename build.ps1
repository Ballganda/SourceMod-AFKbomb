# Compiles every scripting\*.sp into plugins\*.smx using the spcomp that ships
# with the SourceMod install on the local test server.
#   .\build.ps1            compile only
#   .\build.ps1 -Deploy    compile, then copy the .smx files to the server
param(
    [switch]$Deploy,
    [string]$SourceModDir = $(if ($env:SOURCEMOD_DIR) { $env:SOURCEMOD_DIR } else { 'C:\Users\user\cssds\cstrike\addons\sourcemod' })
)

$spcomp = Join-Path $SourceModDir 'scripting\spcomp.exe'
if (-not (Test-Path $spcomp)) { Write-Error "spcomp not found at $spcomp"; exit 1 }

$src = Join-Path $PSScriptRoot 'scripting'
$out = Join-Path $PSScriptRoot 'plugins'
New-Item -ItemType Directory -Force $out | Out-Null

$failed = 0
# scripting\*.sp = the plugin; tests\*.sp = regression plugins (run `afkbomb_test` on the server)
$targets = @(Get-ChildItem $src -Filter *.sp) + @(Get-ChildItem (Join-Path $PSScriptRoot 'tests') -Filter *.sp -ErrorAction SilentlyContinue)
foreach ($sp in $targets) {
    $smx = Join-Path $out ($sp.BaseName + '.smx')
    & $spcomp $sp.FullName "-i$src\include" "-i$SourceModDir\scripting\include" "-o$smx"
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
