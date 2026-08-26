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

.PARAMETER Bash
    Use this bash instead of searching. MSYS2 is preferred automatically,
    because Git for Windows bash cannot see MSYS2 pacman packages.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_setup_host.ps1
#>
[CmdletBinding()]
param(
    [string]$Artifact = 'windows-x64',
    [string]$BuildDir = 'build-setuphost',
    [switch]$SkipPackage,
    [switch]$Clean,
    [string]$Bash = ''
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

function Get-BashCandidates {
    <#
      MSYS2 FIRST, deliberately. Git for Windows also provides bash, but it is a
      separate installation with its own /usr/bin and cannot see packages
      installed by MSYS2's pacman - so `pacman -S zip rsync` leaves git-bash
      exactly as it was. Whichever shell we pick has to be the one that owns the
      tools.
    #>
    $c = @()
    foreach ($p in @('C:\msys64\usr\bin\bash.exe',
                     "$env:SystemDrive\msys64\usr\bin\bash.exe",
                     "$env:ProgramFiles\Git\bin\bash.exe",
                     "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
        if ($p -and (Test-Path $p)) { $c += (Resolve-Path $p).Path }
    }
    if (Have 'bash') { $c += (Get-Command bash).Source }
    return ($c | Select-Object -Unique)
}

function ConvertTo-MsysPath {
    <# C:\mingw64\bin -> /c/mingw64/bin #>
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') {
        return ('/' + $Matches[1].ToLower() + $Matches[2])
    }
    return $p
}

function Test-BashTools {
    <# Returns the tools MISSING from this particular bash. #>
    param([string]$Bash, [string[]]$Tools)
    $missing = @()
    foreach ($t in $Tools) {
        & $Bash -lc "command -v $t >/dev/null 2>&1"
        if ($LASTEXITCODE -ne 0) { $missing += $t }
    }
    # Comma operator: an empty array would otherwise unroll to $null on return,
    # and $null.Count throws under Set-StrictMode - on the SUCCESS path.
    return ,$missing
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

    # cmake must be visible to the shell we hand off to.
    if (($env:PATH -notlike "*$tc*")) { $env:PATH = "$tc;$env:PATH" }

    $candidates = if ($Bash) { @($Bash) } else { Get-BashCandidates }
    if (-not $candidates) {
        Warn 'No bash found. Install MSYS2:  winget install MSYS2.MSYS2'
        Write-Host "`nSetup host built; zip not created." -ForegroundColor Yellow
        return
    }

    $bash = $null
    $report = @()
    foreach ($c in $candidates) {
        $miss = Test-BashTools -Bash $c -Tools @('rsync', 'zip')
        $report += [pscustomobject]@{ Path = $c; Missing = $miss }
        if ($miss.Count -eq 0) { $bash = $c; break }
    }

    if (-not $bash) {
        Warn 'The packager needs rsync and zip, and no available bash has both:'
        foreach ($r in $report) {
            Warn ("  {0}  ->  missing {1}" -f $r.Path, ($r.Missing -join ', '))
        }
        Warn ''
        Warn 'Note that Git for Windows bash and MSYS2 bash are separate installs'
        Warn 'with separate /usr/bin - pacman packages are invisible to git-bash.'
        Warn 'Install into MSYS2 and this script will pick MSYS2 bash:'
        Warn '    C:\msys64\usr\bin\pacman -S --noconfirm zip rsync'
        Warn 'Or point at a specific shell:  -Bash C:\msys64\usr\bin\bash.exe'
        Write-Host "`nSetup host built; zip not created." -ForegroundColor Yellow
        return
    }

    foreach ($r in $report) {
        if ($r.Path -eq $bash) { Dim "bash      : $($r.Path)  (rsync + zip present)" }
        else { Dim "skipped   : $($r.Path)  (missing $($r.Missing -join ', '))" }
    }
    # MSYS2's login shell does not inherit the Windows PATH, so tools installed
    # outside MSYS2 are invisible to it. The packager needs:
    #   objdump - bundle_mingw_dlls.sh uses it to resolve the exe's DLL imports
    #             (it tries x86_64-w64-mingw32-objdump, then objdump)
    #   cmake   - staging invokes it
    # Both live outside MSYS2 here, so prepend their directories explicitly
    # rather than depending on profile behaviour.
    $extra = @()
    if (Have 'gcc') {
        $gccDir = Split-Path (Get-Command gcc).Source -Parent
        $extra += (ConvertTo-MsysPath $gccDir)
        Dim "mingw bin : $gccDir  (objdump)"
    }
    else {
        Warn 'gcc not on PATH - objdump probably will not be found either.'
    }
    $extra += (ConvertTo-MsysPath $tc)
    $prefix = ($extra | Where-Object { $_ } | Select-Object -Unique) -join ':'

    $rootMsys = ConvertTo-MsysPath $Root
    $cmd = "export PATH='$prefix':`$PATH; cd '$rootMsys' && " +
           "scripts/package_setup_release.sh '$BuildDir' '$Artifact' psxrecomp/recompiler/build"
    $rc = Invoke-Logged $bash @('-lc', $cmd)
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
