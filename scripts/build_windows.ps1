<#
.SYNOPSIS
    One-command Windows/MSVC build for DominoRecomp
    (No One Can Stop Mr. Domino, SLUS-00804).

.DESCRIPTION
    Wraps the three steps from psxrecomp/docs/GAME_PROJECT_SETUP.md:

      1. git submodule update --init --recursive
      2. psxrecomp_cli.py generate   -> builds the emitters if missing,
                                        prepares the disc, writes generated/
      3. cmake configure + build     -> build-release\<Config>\Domino_Recompiled.exe

    Run this from a "x64 Native Tools Command Prompt for VS 2022" (or any shell
    where cl.exe is on PATH) so CMake finds MSVC. Python 3 and CMake >= 3.20
    must also be on PATH. Ninja is strongly recommended - the emitter build
    prefers it and falls back to NMake Makefiles without it.

    The disc is NOT copied into this repo. game.toml points at it by relative
    path (..\No One Can Stop Mr. Domino (USA)\...cue); pass -Disc to override.

.PARAMETER Disc
    Override the .cue path from game.toml. Must be your own legal dump.

.PARAMETER Bios
    Optional retail SCPH1001.BIN. Without it the build uses the bundled,
    MIT-licensed OpenBIOS. A supplied dump is staged to bios\ (gitignored).

.PARAMETER Config
    Release (default) or RelWithDebInfo. Never Debug - the generated C is
    enormous and compiles unusably slowly unoptimized.

.PARAMETER Generator
    CMake generator for the runtime. Default "Visual Studio 17 2022".
    Use "Ninja" if you prefer, from a VS developer prompt.

.PARAMETER SkipGenerate
    Skip step 2. Use for a plain rebuild when generated/ is already current.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -Bios C:\bios\SCPH1001.BIN
#>
[CmdletBinding()]
param(
    [string]$Disc = '',
    [string]$Bios = '',
    [ValidateSet('Release', 'RelWithDebInfo')]
    [string]$Config = 'Release',
    [string]$Generator = 'Visual Studio 17 2022',
    [switch]$SkipGenerate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root

function Step($n, $msg) { Write-Host "`n[$n/3] $msg" -ForegroundColor Cyan }
function Need($exe, $hint) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        throw "$exe not found on PATH. $hint"
    }
}

try {
    Need 'cmake'  'Install CMake 3.20+ and reopen your shell.'
    Need 'git'    'Install Git for Windows.'

    $python = $null
    foreach ($c in @('python', 'python3', 'py')) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { $python = $c; break }
    }
    if (-not $python) { throw 'Python 3 not found on PATH. Install it and reopen your shell.' }

    if (-not (Get-Command 'ninja' -ErrorAction SilentlyContinue)) {
        Write-Host 'note: ninja is not on PATH. The emitter build will fall back to' -ForegroundColor Yellow
        Write-Host '      NMake Makefiles, which is slower. winget install Ninja-build.Ninja' -ForegroundColor Yellow
    }
    if (-not (Get-Command 'cl' -ErrorAction SilentlyContinue)) {
        Write-Host 'note: cl.exe is not on PATH. Run this from a "x64 Native Tools' -ForegroundColor Yellow
        Write-Host '      Command Prompt for VS 2022" so CMake can find MSVC.' -ForegroundColor Yellow
    }

    Step 1 'Syncing submodules (psxrecomp, recomp-ui, recomp-net)'
    & git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "git submodule update failed ($LASTEXITCODE)" }

    if ($SkipGenerate) {
        Step 2 'Skipping generate (-SkipGenerate)'
    }
    else {
        Step 2 'Generating BIOS + game C from the disc (builds emitters if missing)'
        $genArgs = @('psxrecomp\psxrecomp_cli.py', 'generate',
                     '--config', 'game.toml', '--project-root', '.')
        if ($Disc) { $genArgs += @('--disc', $Disc) }
        if ($Bios) { $genArgs += @('--bios', $Bios) }
        & $python @genArgs
        if ($LASTEXITCODE -ne 0) { throw "generate failed ($LASTEXITCODE)" }
    }

    Step 3 "Configuring and building the runtime ($Config)"
    $cfgArgs = @('-S', '.', '-B', 'build-release', '-G', $Generator)
    if ($Generator -like 'Visual Studio*') { $cfgArgs += @('-A', 'x64') }
    else { $cfgArgs += "-DCMAKE_BUILD_TYPE=$Config" }
    & cmake @cfgArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

    & cmake --build build-release --config $Config --target psx-runtime
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }

    $exe = Get-ChildItem -Path 'build-release' -Filter 'Domino_Recompiled.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host ''
    if ($exe) {
        Write-Host "Built: $($exe.FullName)" -ForegroundColor Green
    }
    else {
        Write-Host 'Build reported success; look under build-release\ for the exe.' -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
