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

    Visual Studio ships CMake and Ninja, but only puts them on PATH inside a
    developer shell. This script locates your VS install with vswhere, adds the
    bundled CMake/Ninja to PATH for this session, and imports the MSVC x64
    environment - so it works from a plain PowerShell window too. A separately
    installed CMake (winget / cmake.org) already on PATH is used as-is.

    Python 3 and Git must be on PATH.

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
    CMake generator for the runtime. Default is auto: Ninja when available
    (fastest for the huge generated C, and no toolset-version coupling),
    otherwise the newest "Visual Studio NN YYYY" generator your CMake offers.
    Pass a name explicitly to override.

.PARAMETER SkipGenerate
    Skip step 2. Use for a plain rebuild when generated/ is already current.

.PARAMETER Clean
    Delete build-release before configuring. The script already wipes it
    automatically when the cached generator differs from the one in use.

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
    [string]$Generator = '',
    [switch]$SkipGenerate,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot

function Step($n, $msg) { Write-Host "`n[$n/3] $msg" -ForegroundColor Cyan }
function Dim($msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "  $msg" -ForegroundColor Yellow }
function Have($exe) { [bool](Get-Command $exe -ErrorAction SilentlyContinue) }

function Get-VsInstallPath {
    # ProgramFiles(x86) is where the shared VS Installer lives on x64 Windows,
    # but guard for it being absent rather than letting Join-Path throw.
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { $pf86 = $env:ProgramFiles }
    if (-not $pf86) { return $null }

    $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }

    try {
        $found = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if (-not $found) {
            $found = & $vswhere -latest -products * -property installationPath 2>$null
        }
        if ($found) { return ([string[]]$found)[0] }
    }
    catch {
        Warn "vswhere failed: $($_.Exception.Message)"
    }
    return $null
}

function Add-ToPath($dir) {
    if ((Test-Path $dir) -and ($env:PATH -notlike "*$dir*")) {
        $env:PATH = "$dir;$env:PATH"
        Dim "PATH += $dir"
        return $true
    }
    return $false
}

function Initialize-BuildEnvironment {
    # Nothing to do if a real toolchain is already exposed.
    if ((Have 'cmake') -and (Have 'cl')) { return }

    $vs = Get-VsInstallPath
    if (-not $vs) {
        Warn 'vswhere could not find a Visual Studio install.'
        return
    }
    Dim "Visual Studio: $vs"

    # VS bundles CMake and Ninja under CommonExtensions; expose them here.
    if (-not (Have 'cmake')) {
        [void](Add-ToPath (Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'))
    }
    if (-not (Have 'ninja')) {
        [void](Add-ToPath (Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'))
    }

    # Import the MSVC x64 environment (cl.exe, INCLUDE, LIB) if not active.
    if (-not (Have 'cl')) {
        $dll = Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
        if (Test-Path $dll) {
            try {
                Import-Module $dll -ErrorAction Stop
                Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation `
                    -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
                Dim 'MSVC x64 environment loaded'
            }
            catch {
                Warn "could not load the MSVC environment: $($_.Exception.Message)"
            }
        }
        else {
            Warn 'Microsoft.VisualStudio.DevShell.dll not found; cl.exe may be unavailable.'
        }
    }
}

function Resolve-Generator {
    # Ninja first: it has no platform-toolset coupling, so it does not care
    # which Visual Studio generation is installed, and it parallelises the
    # very large generated C far better than MSBuild.
    if (Have 'ninja') { return 'Ninja' }

    # Otherwise ask CMake what Visual Studio generators it actually offers and
    # take the newest, rather than hardcoding a year that may not be installed.
    try {
        $names = & cmake --help 2>$null |
            Select-String -Pattern 'Visual Studio (\d+) (\d+)' |
            ForEach-Object { $_.Matches[0].Value } |
            Sort-Object -Unique
        if ($names) {
            $newest = $names |
                Sort-Object { [int]([regex]::Match($_, 'Visual Studio (\d+)').Groups[1].Value) } -Descending |
                Select-Object -First 1
            return $newest
        }
    }
    catch {
        Warn "could not read cmake --help: $($_.Exception.Message)"
    }
    throw 'No usable CMake generator found (no ninja, and cmake --help listed no Visual Studio generator).'
}

function Get-CachedGenerator($buildDir) {
    $cache = Join-Path $buildDir 'CMakeCache.txt'
    if (-not (Test-Path $cache)) { return $null }
    $m = Select-String -Path $cache -Pattern '^CMAKE_GENERATOR:INTERNAL=(.*)$' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    return $null
}

Push-Location $Root
try {
    Write-Host 'Preparing toolchain...' -ForegroundColor Cyan
    Initialize-BuildEnvironment
    Set-Location $Root   # Enter-VsDevShell can move us; pin it back.

    if (-not (Have 'cmake')) {
        throw @'
cmake not found on PATH, and it is not in your Visual Studio install either.

Fix it either way:
  * Visual Studio Installer -> Modify -> Individual components ->
    tick "C++ CMake tools for Windows", then rerun this script.
  * or install it standalone:  winget install Kitware.CMake
    then CLOSE AND REOPEN this terminal so PATH refreshes.
'@
    }
    if (-not (Have 'git')) { throw 'git not found on PATH. Install Git for Windows.' }

    $python = $null
    foreach ($c in @('python', 'python3', 'py')) {
        if (Have $c) { $python = $c; break }
    }
    if (-not $python) { throw 'Python 3 not found on PATH. Install it and reopen your shell.' }

    Dim "cmake  : $((Get-Command cmake).Source)"
    Dim "python : $((Get-Command $python).Source)"
    if (Have 'ninja') { Dim "ninja  : $((Get-Command ninja).Source)" }
    else { Warn 'ninja not found - the emitter build falls back to NMake Makefiles (slower).' }
    if (-not (Have 'cl')) { Warn 'cl.exe not found - CMake may not find MSVC.' }

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

    $gen = if ($Generator) { $Generator } else { Resolve-Generator }
    $buildDir = 'build-release'

    Step 3 "Configuring and building the runtime ($Config, $gen)"

    # A build dir configured with a different generator cannot be reused, and
    # CMake fails confusingly rather than recovering. Wipe it instead.
    $cached = Get-CachedGenerator $buildDir
    if ($Clean -or ($cached -and $cached -ne $gen)) {
        if ($cached -and $cached -ne $gen) {
            Dim "build-release was configured with '$cached'; removing it for '$gen'"
        }
        Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
    }

    $cfgArgs = @('-S', '.', '-B', $buildDir, '-G', $gen)
    if ($gen -like 'Visual Studio*') {
        # Multi-config: build type is chosen at build time via --config.
        $cfgArgs += @('-A', 'x64')
    }
    else {
        $cfgArgs += "-DCMAKE_BUILD_TYPE=$Config"
    }
    & cmake @cfgArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

    $buildArgs = @('--build', $buildDir, '--target', 'psx-runtime')
    if ($gen -like 'Visual Studio*') { $buildArgs += @('--config', $Config) }
    & cmake @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }

    $exe = Get-ChildItem -Path 'build-release' -Filter 'Domino_Recompiled.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host ''
    if ($exe) { Write-Host "Built: $($exe.FullName)" -ForegroundColor Green }
    else { Write-Host 'Build reported success; look under build-release\ for the exe.' -ForegroundColor Green }
}
finally {
    Pop-Location
}
