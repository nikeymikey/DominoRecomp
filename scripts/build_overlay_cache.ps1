<#
.SYNOPSIS
    Compile captured PS1 overlays into native cache shards for DominoRecomp.

.DESCRIPTION
    Turns overlay_captures.json (recorded while you play, because game.toml sets
    [runtime] overlay_cache = true) into native DLL shards under
    build-release\cache. Areas covered by a shard run as compiled code on the
    very first visit instead of on the dirty-RAM interpreter.

    Why this loops over several files: the runtime keeps the LATEST snapshot in
    overlay_captures.json and an immutable additive history in
    overlay_captures.json.d\<hash>.json. The latest snapshot only holds the
    overlays resident when you quit - earlier areas have been overwritten in
    guest RAM by then. compile_overlays.py reads ONE file per invocation and
    does not union the .d directory itself, so this script runs it once per
    snapshot. That is safe and cheap: the compile is incremental and keyed by
    (region, code CRC) via the .ranges files beside each shard, so repeated
    work is skipped and coverage accumulates in one cache.

    Toolchain: prefers gcc, else the clang from the portable cmake-clang-v1
    pack. Pass -Gcc to force a specific compiler binary.

    NOTE ON --cps: this build does NOT define PSX_CPS (checked in
    build-release\build.ninja), so --cps is deliberately NOT passed. The flag
    must match the runtime build or the shards misbehave. If you ever rebuild
    the runtime with CPS enabled, add -Cps here.

.PARAMETER Gcc
    Compiler binary for the shards. Default: gcc if present, else the
    toolchain pack's clang.exe.

.PARAMETER Jobs
    Parallel region workers. Default: CPU cores - 2.

.PARAMETER LatestOnly
    Compile only overlay_captures.json, skipping the .d history. Faster, but
    covers far less.

.PARAMETER Force
    Rebuild shards even when they already exist.

.PARAMETER Cps
    Pass --cps. Only correct if the runtime was built with PSX_CPS defined.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_overlay_cache.ps1
#>
[CmdletBinding()]
param(
    [string]$Gcc = '',
    [int]$Jobs = 0,
    [switch]$LatestOnly,
    [switch]$Force,
    [switch]$Cps
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$BuildDir = Join-Path $Root 'build-release'
$log = Join-Path $Root 'overlay_cache.log'
Remove-Item $log -ErrorAction SilentlyContinue

function Dim($m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Have($e) { [bool](Get-Command $e -ErrorAction SilentlyContinue) }

function Invoke-Logged {
    # Windows PowerShell 5.1 turns native stderr into terminating errors under
    # $ErrorActionPreference = 'Stop'. Exit code is the only success signal.
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { "$_" } else { $_ } } |
            Tee-Object -FilePath $log -Append |
            Out-Host
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
}

function Get-ToolchainBin {
    $stamp = Join-Path $Root 'toolchain\.psxrecomp-bin'
    if (Test-Path $stamp) {
        $p = (Get-Content $stamp -Raw).Trim()
        if ($p -and (Test-Path $p)) { return $p }
    }
    if ($env:USERPROFILE) {
        $c = Join-Path $env:USERPROFILE '.local\share\retcomm\toolchains\cmake-clang-v1\latest\bin'
        if (Test-Path $c) { return $c }
    }
    return $null
}

Push-Location $Root
try {
    $python = $null
    foreach ($c in @('python', 'python3', 'py')) { if (Have $c) { $python = $c; break } }
    if (-not $python) { throw 'Python 3 not found on PATH.' }

    $recompiler = Join-Path $Root 'psxrecomp\recompiler\build\psxrecomp-game.exe'
    if (-not (Test-Path $recompiler)) {
        throw "psxrecomp-game.exe not found at $recompiler - run the build script first."
    }

    # Pick the shard compiler.
    if (-not $Gcc) {
        $tc = Get-ToolchainBin
        $candidates = @()
        if (Have 'gcc') { $candidates += (Get-Command gcc).Source }
        if ($tc) {
            $candidates += (Join-Path $tc 'gcc.exe')
            $candidates += (Join-Path $tc 'clang.exe')
        }
        foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $Gcc = $c; break } }
    }
    if (-not $Gcc) { throw 'No shard compiler found. Pass -Gcc <path to gcc.exe or clang.exe>.' }
    Dim "compiler   : $Gcc"

    if ($Jobs -le 0) { $Jobs = [Math]::Max(1, [Environment]::ProcessorCount - 2) }
    Dim "jobs       : $Jobs"

    # Latest manifest first, then the additive history oldest-first so newer
    # snapshots win on any tie.
    $captureFiles = @()
    $latest = Join-Path $BuildDir 'overlay_captures.json'
    if (Test-Path $latest) { $captureFiles += (Get-Item $latest) }
    if (-not $LatestOnly) {
        $hist = Join-Path $BuildDir 'overlay_captures.json.d'
        if (Test-Path $hist) {
            $captureFiles += Get-ChildItem -Path $hist -Filter '*.json' | Sort-Object LastWriteTime
        }
    }
    if (-not $captureFiles) {
        throw "No capture files under $BuildDir. Play the game with [runtime] overlay_cache = true, quit normally, then rerun."
    }
    Dim "captures   : $($captureFiles.Count) file(s)"

    $outDir = Join-Path $BuildDir 'cache'
    $runtimeInclude = Join-Path $Root 'psxrecomp\runtime\include'
    $failed = 0
    $i = 0

    foreach ($f in $captureFiles) {
        $i++
        Write-Host "`n[$i/$($captureFiles.Count)] $($f.Name)" -ForegroundColor Cyan
        $a = @('psxrecomp\tools\compile_overlays.py',
               '--captures',        $f.FullName,
               '--game-toml',       'game.toml',
               '--recompiler',      $recompiler,
               '--runtime-include', $runtimeInclude,
               '--out-dir',         $outDir,
               '--gcc',             $Gcc,
               '--jobs',            "$Jobs")
        if ($Force) { $a += '--force' }
        if ($Cps)   { $a += '--cps' }

        $rc = Invoke-Logged $python $a
        if ($rc -ne 0) {
            $failed++
            Warn "snapshot $($f.Name) failed (exit $rc) - continuing with the rest"
        }
    }

    Write-Host ''
    $shards = @(Get-ChildItem -Path $outDir -Filter '*.dll' -Recurse -ErrorAction SilentlyContinue)
    if ($shards.Count -gt 0) {
        $mb = [Math]::Round(($shards | Measure-Object Length -Sum).Sum / 1MB, 1)
        Write-Host "Cache: $($shards.Count) shard(s), $mb MB under $outDir" -ForegroundColor Green
    }
    else {
        Warn "No shards were produced. See $log"
    }
    if ($failed -gt 0) { Warn "$failed of $($captureFiles.Count) snapshot(s) failed - see $log" }
    Write-Host 'Launch the game normally; the loader rescans the cache dir on startup.' -ForegroundColor Green
}
finally { Pop-Location }
