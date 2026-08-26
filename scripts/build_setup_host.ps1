<#
.SYNOPSIS
    Build a setup-host binary and package it as a release zip.

.DESCRIPTION
    A playable build cannot be distributed: it links ~300 MB of C generated from
    your disc, and the overlay cache shards are compiled from code captured off
    it. psxrecomp's release model is a "setup host" instead - the launcher plus
    sources, with NO generated game C - which the player runs once against their
    own disc to generate and build locally.

    Step 1 (always works): configure and build with
    -DPSXRECOMP_FORCE_SETUP_HOST=ON, which is documented as "build without
    linking game C even if generated/ exists". Your generated\ tree and overlay
    cache are left completely alone - nothing is cleared.

    Step 2 (needs tools): psxrecomp/tools/package_setup_host.sh stages the tree
    and zips it. It is bash and needs `rsync` and `zip`, neither of which Git
    for Windows provides. If they are missing this script stops after the build
    and tells you exactly what to install, rather than failing halfway through
    staging.

.PARAMETER Artifact
    Artifact tag used in the zip name. Default windows-x64.

.PARAMETER BuildDir
    Where to build the setup host. Default build-setuphost, deliberately
    separate from build-release so your playable build is untouched.

.PARAMETER SkipPackage
    Build only; do not attempt the bash packager.

.PARAMETER Clean
    Wipe the setup-host build directory first.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_setup_host.ps1
#>
[CmdletBinding()]
param(
    [string]$Artifact = 'windows-x64',
    [string]$BuildDir = 'build-setuphost',
    [switch]$SkipPackage,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $PSScriptRoot
$buildPath = Join-Path $Root $BuildDir
$log = Join-Path $Root 'setup_host.log'
Remove-Item $log -ErrorAction SilentlyContinue

function Step($n, $m) { Write-Host "`n[$n/2] $m" -ForegroundColor Cyan }
function Dim($m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Have($e) { [bool](Get-Command $e -ErrorAction SilentlyContinue) }

function Invoke-Logged {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
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

function Find-Bash {
    if (Have 'bash') { return (Get-Command bash).Source }
    foreach ($c in @("$env:ProgramFiles\Git\bin\bash.exe",
                     "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
                     'C:\msys64\usr\bin\bash.exe')) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

Push-Location $Root
try {
    $tc = Get-ToolchainBin
    if (-not $tc) { throw 'cmake-clang-v1 toolchain not found - run scripts\build_windows.ps1 first.' }
    $clang = Join-Path $tc 'clang.exe'
    $clangxx = Join-Path $tc 'clang++.exe'
    $cmakeExe = Join-Path $tc 'cmake.exe'
    if (-not (Test-Path $cmakeExe)) { $cmakeExe = 'cmake' }
    $ninjaExe = Join-Path $tc 'ninja.exe'
    Dim "toolchain : $tc"

    if ($Clean) { Remove-Item -Recurse -Force $buildPath -ErrorAction SilentlyContinue }

    Step 1 "Building the setup host into $BuildDir (no game C linked)"
    $cfg = @('-S', '.', '-B', $buildPath, '-G', 'Ninja',
             '-DCMAKE_BUILD_TYPE=Release', '-DPSX_PGO=',
             "-DCMAKE_C_COMPILER=$clang", "-DCMAKE_CXX_COMPILER=$clangxx",
             '-DPSXRECOMP_FORCE_SETUP_HOST=ON',
             '-DPSXRECOMP_ALLOW_NO_BIOS=ON',
             '-DPSX_SETUP_WIZARD=ON')
    if (Test-Path $ninjaExe) { $cfg += "-DCMAKE_MAKE_PROGRAM=$ninjaExe" }
    $rc = Invoke-Logged $cmakeExe $cfg
    if ($rc -ne 0) { throw "configure failed ($rc) - see $log" }

    $jobs = [Environment]::ProcessorCount
    $rc = Invoke-Logged $cmakeExe @('--build', $buildPath, '--parallel', "$jobs", '--target', 'psx-runtime')
    if ($rc -ne 0) { throw "build failed ($rc) - see $log" }

    $exe = Get-ChildItem -Path $buildPath -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notmatch 'CMake' } | Select-Object -First 1
    if ($exe) { Dim "host exe  : $($exe.FullName)" }

    if ($SkipPackage) {
        Write-Host "`nBuilt. Skipping packaging (-SkipPackage)." -ForegroundColor Green
        return
    }

    Step 2 'Packaging the setup-host zip'
    $bash = Find-Bash
    $missing = @()
    if (-not $bash) { $missing += 'bash' }
    else {
        foreach ($t in @('rsync', 'zip')) {
            & $bash -lc "command -v $t >/dev/null 2>&1"
            if ($LASTEXITCODE -ne 0) { $missing += $t }
        }
    }

    if ($missing.Count -gt 0) {
        Warn "The packager needs: $($missing -join ', ')"
        Warn 'psxrecomp/tools/package_setup_host.sh is bash and uses rsync + zip.'
        Warn 'Git for Windows ships neither. Easiest fix:'
        Warn '    winget install MSYS2.MSYS2'
        Warn '    C:\msys64\usr\bin\pacman -S --noconfirm zip rsync'
        Warn 'then rerun this script. The build above is done and is not repeated.'
        Write-Host "`nSetup host built; zip not created." -ForegroundColor Yellow
        return
    }

    Dim "bash      : $bash"
    $rc = Invoke-Logged $bash @('-lc',
        "cd '$($Root -replace '\\','/')' && scripts/package_setup_release.sh '$BuildDir' '$Artifact' psxrecomp/recompiler/build")
    if ($rc -ne 0) { throw "packaging failed ($rc) - see $log" }

    $zip = Get-ChildItem -Path (Join-Path $Root 'dist') -Filter '*.zip' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host ''
    if ($zip) {
        Write-Host "Release zip: $($zip.FullName)  ($([Math]::Round($zip.Length/1MB,1)) MB)" -ForegroundColor Green
    }
    else { Warn "Packager reported success but no zip found under dist\ - see $log" }
}
finally { Pop-Location }
