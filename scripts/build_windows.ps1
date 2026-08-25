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

    IMPORTANT - the runtime is built with clang, not MSVC. psxrecomp's runtime
    sources use GNU C extensions (designated-initializer ranges in sio.c,
    __attribute__ in mdec.c) that cl.exe cannot parse, so step 3 drives
    psxrecomp_cli.py, which fetches and activates the portable cmake-clang-v1
    pack - the same toolchain upstream CI and RetComM use. Pass -Msvc to try
    cl.exe anyway; it is expected to fail with C2059/C2143/C2146.

    Visual Studio ships CMake and Ninja but only puts them on PATH inside a
    developer shell, so this script also locates your VS install with vswhere
    and exposes them - that is what step 2's emitter build uses.

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

.PARAMETER KeepGoing
    Ninja -k value: keep building through this many failures instead of
    stopping at the first. Use -KeepGoing 10 when diagnosing, so one run
    shows the whole pattern of errors. Ignored for Visual Studio generators.

.PARAMETER LogFile
    Where to tee generate/build output. Default build.log in the repo root
    (gitignored). Everything still prints to the console as well.

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
    [switch]$Clean,
    [int]$KeepGoing = 0,
    [string]$LogFile = '',
    [switch]$Msvc
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

function Get-CachedCompiler($buildDir) {
    $cache = Join-Path $buildDir 'CMakeCache.txt'
    if (-not (Test-Path $cache)) { return $null }
    $m = Select-String -Path $cache -Pattern '^CMAKE_C_COMPILER:(?:FILE)?PATH=(.*)$' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    return $null
}

$log = if ($LogFile) { $LogFile } else { Join-Path $Root 'build.log' }
Remove-Item $log -ErrorAction SilentlyContinue

Push-Location $Root
try {
    Write-Host "Logging generate/build output to $log" -ForegroundColor DarkGray
    Write-Host 'Preparing toolchain...' -ForegroundColor Cyan
    Initialize-BuildEnvironment
    Set-Location $Root   # Enter-VsDevShell can move us; pin it back.

    # The default path drives psxrecomp_cli.py, which activates the portable
    # clang pack itself, so cmake on PATH is only required for -Msvc.
    if ($Msvc -and -not (Have 'cmake')) {
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

    if (Have 'cmake') { Dim "cmake  : $((Get-Command cmake).Source)" }
    Dim "python : $((Get-Command $python).Source)"
    if (Have 'ninja') { Dim "ninja  : $((Get-Command ninja).Source)" }
    else { Warn 'ninja not found - the emitter build falls back to NMake Makefiles (slower).' }

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
        & $python @genArgs 2>&1 | Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) { throw "generate failed ($LASTEXITCODE) - full output in $log" }
    }

    $buildDir = 'build-release'

    if ($Clean) {
        Dim 'removing build-release (-Clean)'
        Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
    }

    if ($Msvc) {
        # ---- Unsupported escape hatch -------------------------------------
        # The runtime sources use GNU C extensions (designated-initializer
        # ranges in sio.c, __attribute__ in mdec.c) that MSVC cannot parse.
        # Kept only for experimenting; expect C2059/C2143/C2146.
        Warn 'The -Msvc path is known to fail: the runtime uses GNU C extensions cl.exe rejects.'
        $gen = if ($Generator) { $Generator } else { Resolve-Generator }
        Step 3 "Configuring and building with MSVC ($Config, $gen)"

        $cached = Get-CachedGenerator $buildDir
        if ($cached -and $cached -ne $gen) {
            Dim "build-release was configured with '$cached'; removing it for '$gen'"
            Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
        }

        $cfgArgs = @('-S', '.', '-B', $buildDir, '-G', $gen)
        if ($gen -like 'Visual Studio*') { $cfgArgs += @('-A', 'x64') }
        else { $cfgArgs += "-DCMAKE_BUILD_TYPE=$Config" }
        & cmake @cfgArgs 2>&1 | Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE) - full output in $log" }

        $buildArgs = @('--build', $buildDir, '--target', 'psx-runtime')
        if ($gen -like 'Visual Studio*') { $buildArgs += @('--config', $Config) }
        elseif ($KeepGoing -gt 0) { $buildArgs += @('--', '-k', "$KeepGoing") }
        & cmake @buildArgs 2>&1 | Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE) - full output in $log" }
    }
    else {
        # ---- Supported path: the project's own clang toolchain -------------
        # psxrecomp_cli.py resolves the portable cmake-clang-v1 pack, puts its
        # cmake/ninja/clang on PATH, and configures with them. This is what
        # upstream CI and RetComM use; MSVC cannot compile this codebase.
        Step 3 "Fetching the portable clang toolchain (cmake-clang-v1)"
        & $python 'psxrecomp\psxrecomp_cli.py' 'ensure-toolchain' '--project-root' '.' 2>&1 |
            Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) { throw "ensure-toolchain failed ($LASTEXITCODE) - full output in $log" }

        # A build dir configured with cl.exe cannot be reused for clang.
        $cachedCC = Get-CachedCompiler $buildDir
        if ($cachedCC -and $cachedCC -notmatch 'clang') {
            Dim "build-release was configured with '$cachedCC'; removing it for clang"
            Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
        }

        Step 3 "Configuring and building the runtime ($Config, clang + Ninja)"
        $rbArgs = @('psxrecomp\psxrecomp_cli.py', 'rebuild',
                    '--config', 'game.toml', '--project-root', '.',
                    '--build-dir', $buildDir, '--target', 'psx-runtime',
                    '--exe-basename', 'Domino_Recompiled', '--no-pgo')
        & $python @rbArgs 2>&1 | Tee-Object -FilePath $log -Append
        if ($LASTEXITCODE -ne 0) { throw "rebuild failed ($LASTEXITCODE) - full output in $log" }
    }

    $exe = Get-ChildItem -Path 'build-release' -Filter 'Domino_Recompiled.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host ''
    if ($exe) { Write-Host "Built: $($exe.FullName)" -ForegroundColor Green }
    else { Write-Host 'Build reported success; look under build-release\ for the exe.' -ForegroundColor Green }
}
finally {
    Pop-Location
}
