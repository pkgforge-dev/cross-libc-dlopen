<#
.SYNOPSIS
    The end-to-end proof: a real AppImage using a real HOST graphics driver on a
    host whose libc is not the AppImage's.

.DESCRIPTION
    run.ps1 measures the mechanism in isolation. This measures the thing users
    actually complain about, on real software:

      debian:bullseye-slim  builds cross-libc-dlopen.so and the probes on the glibc
                            2.31 FLOOR, so they need only old symbols
      alpine:3.22           musl host. The demo AppImage bundles glibc 2.44 and
                            must drive Alpine's musl-built Mesa. This is the
                            case the complaint is about.
      debian:trixie-slim    glibc 2.41 host, OLDER than the bundled 2.44, so
                            nothing NEEDS rewriting. The regression case: does
                            turning the feature on break what already worked?
      ubuntu:14.04          pre-glvnd GLIBC. The third host CLASS, and the
      ubuntu:16.04          other half of "every musl distro and every
                            pre-glvnd glibc distro": glibc, classic Mesa 10.1
                            and 18.0.5, no libGLX_<vendor>.so.0, no Vulkan at
                            all. Section J is what they are here for; the
                            cases needing a Vulkan device SKIP by name.

    The demo AppImage is ~10 MB and is downloaded once into <repo>\.tmp, which
    is gitignored. Its sha256 is verified.

    Every case is measured with the feature OFF and ON, and against BOTH the
    upstream cross-libc-dlopen.so shipped inside the AppImage and the one built
    from src/. A single-sided result cannot tell a working fix from a fallback
    that was already happening.

.PARAMETER Engine
    Path to podman.exe or docker.exe. Auto-detected when omitted.

.PARAMETER Only
    One host: 'alpine', 'debian', 'ubuntu1404' or 'ubuntu1604'. 'both' is the
    original two; 'all' (the default) adds the pre-glvnd glibc pair.

.EXAMPLE
    .\appimage.ps1
#>
[CmdletBinding()]
param(
    [string]$Engine,
    [ValidateSet('alpine', 'debian', 'ubuntu1404', 'ubuntu1604', 'gtk4', 'gtk4hd', 'both', 'all')][string]$Only = 'all'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $Here
$Work = Join-Path $Repo '.tmp'
# ⛔ NO CHECKED-IN SHA256, AND THAT IS THE POLICY. The upstream publishes one
# release and its tag is `demo`; the assets are replaced without notice, so a
# pinned digest is stale before it lands. The digest is read from the release
# API at run time and the download is verified against it. docs/report/09-the-second-boundary.md 9.15.
$Url  = 'https://github.com/pkgforge-dev/Anylinux-AppImages/releases/download/demo/vkcube+glxgears-host-drivers-demo-x86_64.AppImage'
# The OTHER shape of AppImage: self-contained, its own Mesa, its own vendor
# libraries, a real GTK4 application, and the only AppDir here that bundles
# libGLESv2.so.2, which is what the GLES forwarding table is read out of.
# From pkgforge-dev, the upstream. REPORT 9.15.
$Gtk4Url = 'https://github.com/pkgforge-dev/Anylinux-AppImages/releases/download/demo/gtk4-demo-x86_64.AppImage'
# The same application in the host-drivers shape: glvnd dispatchers and no
# Mesa. On a classic host gles-fwd has to resolve GLES through the host EGL.
# From the upstream. REPORT 9.15.
$Gtk4HdUrl = 'https://github.com/pkgforge-dev/Anylinux-AppImages/releases/download/demo/gtk4-demo-host-drivers-x86_64.AppImage'
$UpstreamRepo = 'pkgforge-dev/Anylinux-AppImages'
$UpstreamTag = 'demo'

function Get-UpstreamDigest {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Asset)
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" `
        -Headers @{ Accept = 'application/vnd.github+json' }
    foreach ($a in $rel.assets) {
        if ($a.name -eq $Asset) { return ($a.digest -replace '^sha256:', '').ToLower() }
    }
    throw "asset $Asset is not published in $Repo release $Tag"
}

# Download, then verify against the digest the release publishes TODAY. The
# demo tag is rolling, so there is no checked-in value to compare with; the
# release API is the authority. A cached copy from an earlier run is only
# reused when it still matches what the release publishes now.
function Invoke-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Asset
    )
    $want = Get-UpstreamDigest -Repo $Repo -Tag $Tag -Asset $Asset
    if (-not (Test-Path -LiteralPath $Path) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() -ne $want) {
        Write-Host "downloading $Label" -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $Url -OutFile $Path
    }
    $got = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) {
        $want2 = Get-UpstreamDigest -Repo $Repo -Tag $Tag -Asset $Asset
        if ($got -ne $want2) {
            throw "$Label sha256 is $got, the release publishes $want2. The asset changed during the run, or the download is wrong."
        }
    }
    Write-Host "$Label sha256 ok (matches the release today)" -ForegroundColor DarkGray
}

function Resolve-Engine {
    if ($Engine) {
        if (-not (Test-Path -LiteralPath $Engine)) { throw "Engine not found: $Engine" }
        return $Engine
    }
    foreach ($n in @('podman', 'docker')) {
        $c = Get-Command "$n.exe" -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Podman\podman.exe'),
        (Join-Path $env:ProgramFiles 'RedHat\Podman\podman.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "No container engine found. Install podman or docker, or pass -Engine <path>."
}

function Invoke-In {
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string]$Script,
        [switch]$Privileged,
        [switch]$Gpu,
        [string]$GtkDir = ''
    )
    $path = Join-Path $Here $Script
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing script: $path" }
    if ([IO.File]::ReadAllText($path).Contains("`r")) {
        throw "$Script contains CR characters. Shell scripts here must be LF-only."
    }
    Write-Host "==> $Image  ($Script)" -ForegroundColor Cyan
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $args = @('run', '--rm',
                  '-v', "${Work}:/w",
                  '-v', "${Repo}:/repo:ro",
                  '-v', "${Here}:/scripts:ro")
        if ($Privileged) { $args += '--privileged' }
        if ($Gpu -and $script:GpuArgs) { $args += $script:GpuArgs }
        # Mounted as its own root, not as a subdirectory of the shared work
        # tree, so nothing can write one AppDir's files into the other's.
        if ($GtkDir) { $args += @('-v', "$(Join-Path $Work $GtkDir):/g") }
        $args += @($Image, 'sh', "/scripts/$Script")
        & $engineExe @args 2>&1 | Out-Host
        $rc = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    return $rc
}

<#
    Is a GPU reachable from a container on this machine?

    Asked by RUNNING it, not by inspecting the host. The engine may be a WSL2
    VM (podman machine), a Linux daemon or a remote socket, and only the
    container's own view of /dev/dxg and the bind-mounted vendor userspace
    decides whether the E41-E46 cases can run. A machine with no GPU is a
    supported configuration: those cases are then SKIPPED by name, never
    silently omitted (section 7).
#>
function Resolve-GpuArgs {
    $candidate = @('--device', '/dev/dxg', '-v', '/usr/lib/wsl:/usr/lib/wsl:ro')
    # One flat array, splatted once. `& $exe @a 'x' 'y', 'z'` parses the comma
    # list as a single array ARGUMENT, so the probe silently runs the wrong
    # command line and reports no GPU on a machine that has one.
    $probe = @('run', '--rm') + $candidate + @('alpine:3.22', 'sh', '-c',
              'test -e /dev/dxg && test -f /usr/lib/wsl/lib/libcuda.so.1 && echo GPU-OK')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $engineExe @probe 2>&1
        $ok = ($LASTEXITCODE -eq 0) -and ("$out" -match 'GPU-OK')
    }
    catch { $ok = $false }
    finally { $ErrorActionPreference = $prev }
    if ($ok) {
        Write-Host "GPU: /dev/dxg and the WSL vendor userspace are reachable" -ForegroundColor DarkGray
        return $candidate
    }
    Write-Host "GPU: no /dev/dxg with a WSL vendor userspace; E41-E46 will be SKIPPED" -ForegroundColor DarkGray
    return @()
}

$engineExe = Resolve-Engine
Write-Host "engine: $engineExe" -ForegroundColor DarkGray
New-Item -ItemType Directory -Force -Path $Work, (Join-Path $Work 'build') | Out-Null
$script:GpuArgs = Resolve-GpuArgs

# ---- the AppImage, fetched once and checksummed -------------------------
$img = Join-Path $Work 'demo.AppImage'
Invoke-VerifiedDownload -Url $Url -Path $img -Label 'demo.AppImage' -Repo $UpstreamRepo -Tag $UpstreamTag -Asset 'vkcube+glxgears-host-drivers-demo-x86_64.AppImage'

if (-not (Test-Path -LiteralPath (Join-Path $Work 'AppDir'))) {
    # Extraction runs the AppImage's own ELF runtime and the payload is DwarFS,
    # so it happens inside a container, not on the host.
    $rc = Invoke-In -Image 'debian:trixie-slim' -Script '41-extract.sh' -Privileged
    if ($rc -ne 0) { throw "extraction failed (exit $rc)" }
}

# ---- build on the FLOOR, not on the newest thing available --------------
$rc = Invoke-In -Image 'debian:bullseye-slim' -Script '42-build-floor.sh'
if ($rc -ne 0) { throw "floor build failed (exit $rc)" }

# ---- and the musl half of the ABI probe, which only Alpine can produce ---
$rc = Invoke-In -Image 'alpine:3.22' -Script '45-build-musl-guest.sh'
if ($rc -ne 0) { throw "musl guest build failed (exit $rc)" }

$fail = 0
if ($Only -in @('both', 'all', 'alpine')) {
    Write-Host ""
    Write-Host "######## musl host: the case the complaint is about ########" -ForegroundColor Yellow
    if ((Invoke-In -Image 'alpine:3.22' -Script '43-host-alpine.sh' -Gpu) -ne 0) { $fail++ }
}
if ($Only -in @('both', 'all', 'debian')) {
    Write-Host ""
    Write-Host "######## glibc host: the regression case ########" -ForegroundColor Yellow
    if ((Invoke-In -Image 'debian:trixie-slim' -Script '44-host-debian.sh' -Gpu) -ne 0) { $fail++ }
}
# The third host class: glibc, but from before libglvnd existed. This is the
# half of the claim that had no evidence on this machine.
foreach ($u in @(
    @{ Key = 'ubuntu1404'; Image = 'ubuntu:14.04'; Note = 'glibc 2.19, Mesa 10.1' },
    @{ Key = 'ubuntu1604'; Image = 'ubuntu:16.04'; Note = 'glibc 2.23, Mesa 18.0.5' })) {
    if ($Only -in @('all', $u.Key)) {
        Write-Host ""
        Write-Host "######## pre-glvnd glibc host: $($u.Image) -- $($u.Note) ########" -ForegroundColor Yellow
        if ((Invoke-In -Image $u.Image -Script '46-host-ubuntu.sh' -Gpu) -ne 0) { $fail++ }
    }
}

# The fifth stage is not a host, it is a different APPIMAGE: a real GTK4
# application that bundles its own Mesa. It is the only case here with a GLES
# dispatcher in it, and it is what found the shim preferring a host vendor
# library over the bundle's own.
if ($Only -in @('all', 'gtk4')) {
    $g = Join-Path $Work 'gtk4-demo.AppImage'
    Invoke-VerifiedDownload -Url $Gtk4Url -Path $g -Label 'gtk4-demo.AppImage' -Repo $UpstreamRepo -Tag $UpstreamTag -Asset 'gtk4-demo-x86_64.AppImage'
    if (-not (Test-Path -LiteralPath (Join-Path $Work 'gtk4x\AppDir'))) {
        $rc = Invoke-In -Image 'debian:trixie-slim' -Script '48-extract-gtk4.sh' -Privileged
        if ($rc -ne 0) { throw "gtk4 extraction failed (exit $rc)" }
    }
    Write-Host ""
    Write-Host "######## a real application: gtk4-demo on musl Alpine ########" -ForegroundColor Yellow
    if ((Invoke-In -Image 'alpine:3.22' -Script '47-gtk4.sh' -GtkDir 'gtk4x') -ne 0) { $fail++ }
}

# The same application in the OTHER shape: a host-drivers gtk4 demo, bundling
# the glvnd dispatchers and no Mesa. On a classic host gles-fwd has no
# libGLESv2.so.2 to forward to and must resolve GLES through the host EGL's
# eglGetProcAddress; this is the case report/10 said was measured-but-not-repaired.
if ($Only -in @('all', 'gtk4hd')) {
    $h = Join-Path $Work 'gtk4-demo-host-drivers.AppImage'
    Invoke-VerifiedDownload -Url $Gtk4HdUrl -Path $h -Label 'gtk4-demo-host-drivers.AppImage' -Repo $UpstreamRepo -Tag $UpstreamTag -Asset 'gtk4-demo-host-drivers-x86_64.AppImage'
    if (-not (Test-Path -LiteralPath (Join-Path $Work 'gtk4hd\AppDir'))) {
        $rc = Invoke-In -Image 'debian:trixie-slim' -Script '49-extract-gtk4-host-drivers.sh' -Privileged
        if ($rc -ne 0) { throw "gtk4 host-drivers extraction failed (exit $rc)" }
    }
    Write-Host ""
    Write-Host "######## a real application, host-drivers shape: gtk4-demo on musl Alpine ########" -ForegroundColor Yellow
    if ((Invoke-In -Image 'alpine:3.22' -Script '50-gtk4-host-drivers.sh' -GtkDir 'gtk4hd') -ne 0) { $fail++ }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL PREDICTIONS HELD" -ForegroundColor Green; exit 0 }
Write-Host "SOME PREDICTIONS DID NOT HOLD -- investigate, this is a finding" -ForegroundColor Yellow
exit 1
