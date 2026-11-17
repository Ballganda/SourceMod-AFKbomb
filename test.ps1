# Builds and deploys the plugins, runs the regression suite on the local test server
# unattended, then scans every log the run touched for errors.
#   .\test.ps1                 full run; exit code 0 = all passed and logs clean
#   .\test.ps1 -NoBuild        skip build/deploy, test what is already on the server
#   .\test.ps1 -WithClient     also launch the CS:S client on this PC so the real-client cases run
#                              (leave the game window alone while it runs: the client must be idle)
#   .\test.ps1 -InjectError    self-check: the suite logs a deliberate error, so this run MUST fail
#   .\test.ps1 -ScanOnly       no server run; scan the whole current logs (e.g. after a manual session)
param(
    [switch]$NoBuild,
    [switch]$InjectError,
    [switch]$ScanOnly,
    [switch]$WithClient,
    [string]$ClientDir = $(if ($env:CSS_CLIENT_DIR) { $env:CSS_CLIENT_DIR } else { 'C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source' }),
    [string]$ServerDir = $(if ($env:CSS_SERVER_DIR) { $env:CSS_SERVER_DIR } else { 'C:\Users\user\cssds' }),
    [string]$Map = 'de_dust2',
    [int]$TimeoutSec = 360
)
$clientNames = 'cstrike_win64', 'cstrike', 'hl2'
$clientLog = Join-Path $ClientDir 'cstrike\console.log'
$steamExe = Join-Path (Split-Path (Split-Path (Split-Path $ClientDir))) 'steam.exe'
if ($WithClient -and $TimeoutSec -eq 360) { $TimeoutSec = 600 }

$game = Join-Path $ServerDir 'cstrike'
$smLogs = Join-Path $game 'addons\sourcemod\logs'
$consoleLog = Join-Path $game 'console.log'
$testLog = Join-Path $smLogs 'afkbomb_tests.log'

# Lines that look like errors but are normal on this server (see CLAUDE.md).
$benign = @(
    'metamod[\\/]bin[\\/]win64[\\/]server',      # x64 VDF on a 32-bit server
    'vscript_convar_allowlist\.txt',
    '\[afkbomb_test\]', '\[(PASS|FAIL|WARN|SKIP|INFO)\]', 'tests finished:',   # the suite's own output (judged separately)
    'afkbomb test', 'AFKTest'                     # fake-client kick reasons and names
)
# Always a failure: script errors, plugins or extensions that did not load, engine faults.
$hard = '\[SM\] (Exception|Blaming|Call stack|Unable to load|Failed to load|Plugin .* failed|Fatal)|' +
        'Exception reported|Native ".*" (reported|was not found)|Script execution timed out|' +
        '<(Failed|Error|Bad Load)>|Could not find required file|Language phrase ".*" not found|' +
        'Translation .* not found|Host_Error|Engine Error|Segmentation fault|Access violation|' +
        'Failed to load plugin|Plugin failed to load|required extension'
# Reported as a warning for a human to judge.
$soft = '\b(error|errors|exception|failed|failure|unable to|could not|cannot|invalid|not found|missing|warning|deprecated|leak)\b'

function Get-LogSizes {
    $sizes = @{}
    $files = @(Get-ChildItem $smLogs -Filter *.log -ErrorAction SilentlyContinue)
    if (Test-Path $consoleLog) { $files += Get-Item $consoleLog }
    foreach ($f in $files) { $sizes[$f.FullName] = $f.Length }
    return $sizes
}

# Text appended to a log since the snapshot (the whole file if it is new or was rotated).
function Get-NewLines([string]$path, $before) {
    if (-not (Test-Path $path)) { return @() }
    # open shared: the server or client may still hold its log open
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $bytes = New-Object byte[] $fs.Length; [void]$fs.Read($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $from = 0
    if ($before -and $before.ContainsKey($path) -and $before[$path] -le $bytes.Length) { $from = $before[$path] }
    if ($from -ge $bytes.Length) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($bytes, $from, $bytes.Length - $from)
    return @($text -split "`r?`n" | Where-Object { $_.Trim() })
}

function Test-Benign([string]$line) {
    foreach ($b in $benign) { if ($line -match $b) { return $true } }
    return $false
}

$problems = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$before = $null

if (-not $ScanOnly) {
    if (Get-Process srcds -ErrorAction SilentlyContinue) {
        Write-Error 'srcds.exe is already running; stop it first (the suite needs its own server instance).'
        exit 2
    }
    if (-not $NoBuild) {
        $buildOut = & "$PSScriptRoot\build.ps1" -Deploy 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { $buildOut | Write-Host; Write-Error 'build failed'; exit 1 }
        foreach ($l in $buildOut) {
            if ($l -match ' : (warning|error) \d+') { $warnings.Add("compiler: " + ($l -replace '^.*\\', '')) }
        }
    }

    if ($WithClient) {
        if (Get-Process $clientNames -ErrorAction SilentlyContinue) { Write-Error 'The CS:S client is already running; close it first.'; exit 2 }
        if (-not (Test-Path $steamExe)) { Write-Error "steam.exe not found at $steamExe"; exit 2 }
    }
    $before = Get-LogSizes
    if (Test-Path $clientLog) { $before[$clientLog] = (Get-Item $clientLog).Length }
    $inject = 0; if ($InjectError) { $inject = 1 }
    $srcdsArgs = "-console -game cstrike -condebug -tickrate 100 +sv_lan 1 +maxplayers 10 +bot_quota 0 " +
                 "+afkbomb_test_autorun 1 +afkbomb_test_inject_error $inject +afkbomb_test_wait_client $([int][bool]$WithClient) +map $Map"
    if ($WithClient) {
        # SourceMod file natives cannot open absolute paths; a junction inside the server's game dir exposes the client's cstrike folder
        $junction = Join-Path $game 'afkbomb_client'
        if (-not (Test-Path $junction)) { New-Item -ItemType Junction -Path $junction -Target (Split-Path $clientLog) | Out-Null }
        $srcdsArgs += ' +afkbomb_test_client_log afkbomb_client/console.log'
    }
    Write-Host "Starting srcds ($Map); the suite takes about 2.5 minutes..."
    $proc = Start-Process (Join-Path $ServerDir 'srcds.exe') -ArgumentList $srcdsArgs -WorkingDirectory $ServerDir -PassThru
    if ($WithClient) {
        # the game port listens on the LAN IP, not 127.0.0.1
        $ip = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4Address.IPAddress
        Start-Sleep -Seconds 20
        Write-Host "Launching the CS:S client -> ${ip}:27015 (do not touch the game window)..."
        Start-Process $steamExe -ArgumentList "-applaunch 240 -novid -windowed -w 1024 -h 768 -condebug +connect ${ip}:27015"
    }
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        Stop-Process -Id $proc.Id -Force
        $problems.Add("server did not quit within ${TimeoutSec}s (suite hung or never started); it was killed")
    }
}

if ($WithClient -and -not $ScanOnly) {
    Start-Sleep -Seconds 3
    Get-Process $clientNames -ErrorAction SilentlyContinue | Stop-Process -Force   # the client this script launched
    Start-Sleep -Seconds 2
}

# --- the suite's own results ---
$results = Get-NewLines $testLog $before
$passed = @($results | Where-Object { $_ -match '\[PASS\]' })
$failed = @($results | Where-Object { $_ -match '\[FAIL\]' })
$skipped = @($results | Where-Object { $_ -match '\[SKIP\]' })
$summary = @($results | Where-Object { $_ -match 'tests finished: (\d+) passed, (\d+) failed' }) | Select-Object -Last 1
if (-not $ScanOnly) {
    if (-not $results.Count) { $problems.Add('the suite wrote nothing to afkbomb_tests.log (test plugin not loaded?)') }
    elseif (-not $summary) { $problems.Add('the suite started but never reached its summary line (crash or hang mid-suite)') }
    $started = @($results | Where-Object { $_ -match 'tests started \((\d+) cases\)' }) | Select-Object -Last 1
    if ($started -and $started -match '\((\d+) cases\)' -and ($passed.Count + $failed.Count + $skipped.Count) -lt [int]$Matches[1]) {
        $problems.Add("only $($passed.Count + $failed.Count) of $($Matches[1]) cases reported a result")
    }
}
if ($WithClient -and $skipped.Count) { $problems.Add("$($skipped.Count) real-client case(s) were skipped: the client never got into the game") }
foreach ($l in $failed) { $problems.Add('test: ' + ($l -replace '^.*?(\[FAIL\])', '$1')) }
foreach ($l in @($results | Where-Object { $_ -match '\[WARN\]' })) { $warnings.Add('test: ' + ($l -replace '^.*?(\[WARN\])', '$1')) }

# --- every other log the run touched ---
$logs = @(Get-ChildItem $smLogs -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $testLog })
if (Test-Path $consoleLog) { $logs += Get-Item $consoleLog }
if ($WithClient -and (Test-Path $clientLog)) { $logs += Get-Item $clientLog }
$scanned = 0
foreach ($f in $logs) {
    $lines = Get-NewLines $f.FullName $before
    $scanned += $lines.Count
    $isErrorLog = $f.Name -like 'errors_*'
    if ($f.FullName -eq $clientLog) {
        # what the player actually saw in chat; the rest of a client log is unrelated asset noise
        $chat = @($lines | Where-Object { $_ -match 'seems to be afk with the bomb|\[Afk Bomb\]' })
        if ($chat.Count) { Write-Host "`nClient chat:"; $chat | ForEach-Object { Write-Host "  $_" -ForegroundColor Cyan } }
        elseif (-not $ScanOnly) { $warnings.Add('client console.log shows no AFK Bomb chat lines') }
        continue
    }
    foreach ($l in $lines) {
        if (Test-Benign $l) { continue }
        if ($isErrorLog -or $l -match $hard) { $problems.Add("$($f.Name): $l") }
        elseif ($l -match $soft) { $warnings.Add("$($f.Name): $l") }
    }
}

# --- report ---
Write-Host ''
foreach ($l in $passed) { Write-Host ($l -replace '^.*?(\[PASS\])', '$1') -ForegroundColor DarkGreen }
foreach ($l in $skipped) { Write-Host ($l -replace '^.*?(\[SKIP\])', '$1') -ForegroundColor DarkGray }
foreach ($l in $failed) { Write-Host ($l -replace '^.*?(\[FAIL\])', '$1') -ForegroundColor Red }
Write-Host ''
Write-Host "Cases: $($passed.Count) passed, $($failed.Count) failed, $($skipped.Count) skipped. Scanned $scanned new log lines in $($logs.Count) files."
if ($warnings.Count) {
    Write-Host "`nWarnings ($($warnings.Count)):" -ForegroundColor Yellow
    $warnings | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
if ($problems.Count) {
    Write-Host "`nProblems ($($problems.Count)):" -ForegroundColor Red
    $problems | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "`nRESULT: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "`nRESULT: PASS" -ForegroundColor Green
exit 0
