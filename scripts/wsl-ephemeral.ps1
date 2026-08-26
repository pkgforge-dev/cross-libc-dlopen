<#
.SYNOPSIS
    Create, use, and destroy ephemeral WSL2 distros on demand.

.DESCRIPTION
    Builds throwaway WSL2 distros from OCI images (any distro, any tag available on a
    container registry) or from a local rootfs tarball, runs commands inside them, and
    removes them cleanly.

    SAFETY MODEL -- this script is destructive by nature, so removal is constrained four ways:
      1. Every distro it creates is named with a fixed prefix (default 'eph-').
      2. It REFUSES to remove any distro whose name lacks that prefix.
      3. It REFUSES to remove any name on an explicit protected list, prefix or not.
         'podman-machine-default' and the Docker Desktop distros are protected, so a
         mistake here cannot destroy your container runtime.
      4. Directory deletion is confined to %LOCALAPPDATA%\wsl-ephemeral\<distro>; the base
         directory itself and anything outside it can never be the target.

    Destructive actions require -Force when running non-interactively.

.PARAMETER Action
    New     Create an ephemeral distro (from -Image or -Tarball).
    Run     Run a command inside an existing ephemeral distro.
    List    List ephemeral distros, and show what else exists (never touched).
    Remove  Unregister one ephemeral distro and delete its disk.
    Purge   Remove ALL ephemeral distros (prefix-matched only).

.PARAMETER Image
    OCI image reference, e.g. 'alpine:3.22', 'debian:bullseye-slim', 'fedora:44',
    'archlinux:latest', 'opensuse/tumbleweed', 'rockylinux:9', 'voidlinux/voidlinux'.

.PARAMETER Tarball
    Path to a rootfs tarball (.tar / .tar.gz) to import instead of pulling an image.
    Lets the script work with no container engine installed.

.PARAMETER Name
    Distro name. Auto-generated when omitted. The prefix is added if missing.

.PARAMETER Command
    Shell command to run, via /bin/sh -lc.

.PARAMETER User
    User to run as inside the distro. Default 'root'.

.PARAMETER Ephemeral
    With -Action New: run -Command then immediately destroy the distro.

.PARAMETER Force
    Required for destructive actions when non-interactive. Skips confirmation.

.EXAMPLE
    .\wsl-ephemeral.ps1 -Action New -Image alpine:3.22

.EXAMPLE
    .\wsl-ephemeral.ps1 -Action New -Image debian:bullseye-slim -Command "ldd --version" -Ephemeral -Force

.EXAMPLE
    .\wsl-ephemeral.ps1 -Action Run -Name eph-alpine-3.22-a1b2 -Command "apk add gcc && gcc --version"

.EXAMPLE
    .\wsl-ephemeral.ps1 -Action Purge -Force

.NOTES
    Requires : Windows 10 2004+ / Windows 11 with WSL2.
    Optional : podman or docker (only for -Image).
    Tested on: Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('New', 'Run', 'List', 'Remove', 'Purge')]
    [string]$Action,

    [string]$Image,
    [string]$Tarball,
    [string]$Name,
    [string]$Command,
    [string]$User = 'root',
    [switch]$Ephemeral,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------------------
$script:Prefix  = 'eph-'
$script:BaseDir = Join-Path $env:LOCALAPPDATA 'wsl-ephemeral'

# Names that must NEVER be unregistered, even if somebody prefixes them.
$script:Protected = @(
    'podman-machine-default',
    'docker-desktop',
    'docker-desktop-data',
    'rancher-desktop',
    'rancher-desktop-data'
)

# WSL emits UTF-16LE unless this is set; without it every parsed string is NUL-riddled.
$env:WSL_UTF8 = '1'

# --------------------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  * $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "  ! $Message" -ForegroundColor Yellow }

# --------------------------------------------------------------------------------------
# Process helpers
# --------------------------------------------------------------------------------------
function Invoke-Native {
    <#
      Run a native exe, capture merged stdout+stderr, throw on non-zero exit.
      $ErrorActionPreference is deliberately relaxed for the duration: with it set to
      'Stop', PowerShell 7.3+ turns native stderr captured via 2>&1 into a terminating
      NativeCommandError, which would misreport success as failure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    if (-not $IgnoreExitCode -and $code -ne 0) {
        $joined = ($out | Out-String).Trim()
        throw "$([IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ') failed (exit $code): $joined"
    }
    return $out
}

function Test-Interactive {
    # Read-Host blocks or throws when stdin is not a console; detect that up front.
    if (-not [Environment]::UserInteractive) { return $false }
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Confirm-Destructive {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Operation
    )
    if ($Force) { return $true }
    if (-not (Test-Interactive)) {
        Write-Warn "$Operation on '$Target' needs confirmation, but this session is non-interactive."
        Write-Warn "Re-run with -Force to proceed."
        return $false
    }
    $answer = Read-Host "$Operation on '$Target'? [y/N]"
    return ($answer -match '^(y|yes)$')
}

# --------------------------------------------------------------------------------------
# WSL helpers
# --------------------------------------------------------------------------------------
function Get-WslExe {
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:WINDIR 'System32\wsl.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw "wsl.exe not found. WSL2 is required."
}

function Get-WslDistroNames {
    $wsl  = Get-WslExe
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = & $wsl --list --quiet 2>$null } finally { $ErrorActionPreference = $prev }
    if (-not $raw) { return @() }
    $names = @()
    foreach ($line in $raw) {
        # Belt and braces: strip NULs in case WSL_UTF8 is unsupported on this build.
        $clean = ($line -replace "`0", '').Trim()
        if ($clean) { $names += $clean }
    }
    return $names
}

# --------------------------------------------------------------------------------------
# Naming and safety guards
# --------------------------------------------------------------------------------------
function Test-ProtectedName {
    param([Parameter(Mandatory = $true)][string]$DistroName)
    foreach ($p in $script:Protected) { if ($DistroName -ieq $p) { return $true } }
    return $false
}

function Assert-Removable {
    <# The single choke point for every destructive path. #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$DistroName)

    if ([string]::IsNullOrWhiteSpace($DistroName)) {
        throw "Refusing to remove: empty distro name."
    }
    if (Test-ProtectedName -DistroName $DistroName) {
        throw "REFUSING to remove protected distro '$DistroName'. This is a hard guard."
    }
    if (-not $DistroName.StartsWith($script:Prefix, [StringComparison]::Ordinal)) {
        throw ("REFUSING to remove '$DistroName': it does not start with '$($script:Prefix)'. " +
               "This script only removes distros it created.")
    }
}

function Assert-InsideBaseDir {
    <#
      Guarantees a directory slated for recursive deletion is a *strict* child of BaseDir.
      Without this, an empty or crafted distro name could resolve the target to BaseDir
      itself (or, with traversal, somewhere else entirely).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $baseFull = [IO.Path]::GetFullPath($script:BaseDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar)
    $full     = [IO.Path]::GetFullPath($Path)

    if ($full.TrimEnd('\', '/') -ieq $baseFull.TrimEnd('\', '/')) {
        throw "REFUSING to delete the base directory itself ($full)."
    }
    if (-not $full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "REFUSING to delete '$full': outside $($script:BaseDir)."
    }
}

function ConvertTo-SafeName {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Raw)
    $s = $Raw.ToLowerInvariant() -replace '[^a-z0-9._-]', '-'
    $s = $s -replace '-{2,}', '-'
    $s = $s -replace '\.{2,}', '.'      # kill any ".." traversal component
    return $s.Trim('-', '.')
}

function New-DistroName {
    param([AllowEmptyString()][string]$FromImage)
    $stem = 'rootfs'
    if (-not [string]::IsNullOrWhiteSpace($FromImage)) { $stem = ConvertTo-SafeName -Raw $FromImage }
    if ([string]::IsNullOrWhiteSpace($stem)) { $stem = 'rootfs' }
    if ($stem.Length -gt 32) { $stem = $stem.Substring(0, 32).Trim('-', '.') }
    $suffix = -join ((48..57) + (97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    return "$($script:Prefix)$stem-$suffix"
}

function Resolve-DistroName {
    param([AllowEmptyString()][string]$Requested, [AllowEmptyString()][string]$FromImage)
    if ([string]::IsNullOrWhiteSpace($Requested)) { return (New-DistroName -FromImage $FromImage) }
    $n = ConvertTo-SafeName -Raw $Requested
    if ([string]::IsNullOrWhiteSpace($n)) { throw "Name '$Requested' sanitises to nothing." }
    if (-not $n.StartsWith($script:Prefix, [StringComparison]::Ordinal)) { $n = "$($script:Prefix)$n" }
    return $n
}

# --------------------------------------------------------------------------------------
# Rootfs acquisition
# --------------------------------------------------------------------------------------
function Get-ContainerEngine {
    foreach ($exe in @('podman', 'docker')) {
        $cmd = Get-Command "$exe.exe" -ErrorAction SilentlyContinue
        if ($cmd) { return [pscustomobject]@{ Name = $exe; Path = $cmd.Source } }
    }
    $candidates = @(
        [pscustomobject]@{ Name = 'podman'; Path = (Join-Path $env:LOCALAPPDATA 'Programs\Podman\podman.exe') },
        [pscustomobject]@{ Name = 'podman'; Path = (Join-Path $env:ProgramFiles 'RedHat\Podman\podman.exe') },
        [pscustomobject]@{ Name = 'docker'; Path = (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe') }
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c.Path) { return $c }
    }
    return $null
}

function Export-ImageRootfs {
    <# Pull an OCI image and flatten it to a rootfs tarball. #>
    param(
        [Parameter(Mandatory = $true)][string]$ImageRef,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $engine = Get-ContainerEngine
    if (-not $engine) {
        throw ("No container engine found. Install podman or docker, or pass -Tarball " +
               "with a rootfs archive instead.")
    }
    Write-Step "Engine: $($engine.Name) ($($engine.Path))"

    # Readiness probe: a stopped podman machine otherwise yields a cryptic pull error.
    try { Invoke-Native -FilePath $engine.Path -Arguments @('info', '--format', '{{.Host.Arch}}') | Out-Null }
    catch {
        throw ("$($engine.Name) is installed but not responding. If you use podman on Windows, " +
               "start its VM with:  podman machine start`nUnderlying error: $($_.Exception.Message)")
    }

    Write-Step "Pulling $ImageRef"
    Invoke-Native -FilePath $engine.Path -Arguments @('pull', $ImageRef) | Out-Null

    $cid = $null
    try {
        # 'create' materialises a container without running it; its filesystem is the rootfs.
        # Images with no CMD/ENTRYPOINT reject a bare create, so fall back to naming one.
        try {
            $cid = (Invoke-Native -FilePath $engine.Path -Arguments @('create', $ImageRef) |
                    Select-Object -Last 1).ToString().Trim()
        }
        catch {
            Write-Warn "bare create failed; retrying with an explicit command"
            $cid = (Invoke-Native -FilePath $engine.Path -Arguments @('create', $ImageRef, '/bin/sh') |
                    Select-Object -Last 1).ToString().Trim()
        }
        if ([string]::IsNullOrWhiteSpace($cid)) { throw "Container id was empty." }

        $short = $cid.Substring(0, [Math]::Min(12, $cid.Length))
        Write-Step "Exporting rootfs (container $short)"
        # -o is mandatory: PowerShell redirection corrupts binary streams.
        Invoke-Native -FilePath $engine.Path -Arguments @('export', '-o', $OutFile, $cid) | Out-Null
    }
    finally {
        if ($cid) {
            try { Invoke-Native -FilePath $engine.Path -Arguments @('rm', '-f', $cid) -IgnoreExitCode | Out-Null }
            catch { Write-Warn "could not remove temp container $cid" }
        }
    }

    if (-not (Test-Path -LiteralPath $OutFile)) { throw "Export produced no file at $OutFile" }
    $size = (Get-Item -LiteralPath $OutFile).Length
    if ($size -lt 1KB) { throw "Exported rootfs is implausibly small ($size bytes)." }
    Write-Ok ("rootfs: {0:N1} MiB" -f ($size / 1MB))
}

# --------------------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------------------
function Remove-EphemeralDistro {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [switch]$SkipConfirm
    )
    Assert-Removable -DistroName $DistroName          # hard guard, always first

    if (-not $SkipConfirm) {
        if (-not (Confirm-Destructive -Target $DistroName -Operation 'Unregister WSL distro and DELETE its disk')) {
            Write-Warn "skipped $DistroName"
            return
        }
    }

    $wsl = Get-WslExe
    if ((Get-WslDistroNames) -contains $DistroName) {
        Invoke-Native -FilePath $wsl -Arguments @('--terminate', $DistroName) -IgnoreExitCode | Out-Null
        Invoke-Native -FilePath $wsl -Arguments @('--unregister', $DistroName) | Out-Null
        Write-Ok "unregistered $DistroName"
    }
    else {
        Write-Warn "$DistroName was not registered"
    }

    $dir = Join-Path $script:BaseDir $DistroName
    if (Test-Path -LiteralPath $dir) {
        Assert-InsideBaseDir -Path $dir               # containment guard
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "deleted $dir"
    }
}

function Invoke-ActionNew {
    if (-not $Image -and -not $Tarball) { throw "Action New requires -Image (e.g. alpine:3.22) or -Tarball <path>." }
    if ($Image -and $Tarball)           { throw "Pass either -Image or -Tarball, not both." }

    $distro = Resolve-DistroName -Requested $Name -FromImage $Image
    if (Test-ProtectedName -DistroName $distro) { throw "Refusing to create a distro named '$distro' (protected)." }
    if ((Get-WslDistroNames) -contains $distro) {
        throw "Distro '$distro' already exists. Choose another -Name or remove it first."
    }

    $target  = Join-Path $script:BaseDir $distro
    Assert-InsideBaseDir -Path $target               # validate before we ever create it
    $tarPath = $null
    $tempTar = $false

    try {
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        if ($Tarball) {
            if (-not (Test-Path -LiteralPath $Tarball)) { throw "Tarball not found: $Tarball" }
            $tarPath = (Resolve-Path -LiteralPath $Tarball).Path
        }
        else {
            $tarPath = Join-Path $script:BaseDir ("{0}.tar" -f $distro)
            $tempTar = $true
            Export-ImageRootfs -ImageRef $Image -OutFile $tarPath
        }

        Write-Step "Importing as WSL2 distro '$distro'"
        $wsl = Get-WslExe
        Invoke-Native -FilePath $wsl -Arguments @('--import', $distro, $target, $tarPath, '--version', '2') | Out-Null

        # Smoke test: a distro whose /bin/sh does not run is useless. Fail loudly now.
        # The loop also absorbs a first-boot race: drvfs automount of /mnt/<drive> can lag
        # the first shell by a second or two, which otherwise makes the very first user
        # command fail on a path under /mnt/c for no visible reason.
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $probe = & $wsl -d $distro -u root -- /bin/sh -lc @'
echo __WSL_OK__
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -d /mnt/c ]; then break; fi
    sleep 1
done
if [ ! -d /mnt/c ]; then echo "note: no /mnt/c (Windows drives not mounted)"; fi
head -2 /etc/os-release 2>/dev/null || echo "os-release: n/a"
'@ 2>&1
        }
        finally { $ErrorActionPreference = $prev }

        $probeText = ($probe | Out-String)
        if ($probeText -notmatch '__WSL_OK__') {
            throw "Distro imported but /bin/sh did not run. Output: $($probeText.Trim())"
        }
        Write-Ok "'$distro' is up"
        foreach ($l in ($probeText -split "`r?`n")) {
            $t = $l.Trim()
            if ($t -and $t -ne '__WSL_OK__') { Write-Host "    $t" -ForegroundColor DarkGray }
        }

        if ($Command) {
            Write-Step "Running command as '$User'"
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { & $wsl -d $distro -u $User -- /bin/sh -lc $Command; $rc = $LASTEXITCODE }
            finally { $ErrorActionPreference = $prev }
            if ($rc -ne 0) { Write-Warn "command exited $rc" }
        }

        if ($Ephemeral) {
            Write-Step "-Ephemeral set: tearing down '$distro'"
            Remove-EphemeralDistro -DistroName $distro -SkipConfirm
            return
        }

        Write-Host ""
        Write-Host "  Distro : $distro"        -ForegroundColor White
        Write-Host "  Disk   : $target"        -ForegroundColor White
        Write-Host "  Enter  : wsl -d $distro" -ForegroundColor White
        Write-Host "  Remove : -Action Remove -Name $distro -Force" -ForegroundColor White
    }
    catch {
        Write-Warn "creation failed; rolling back"
        try {
            if ((Get-WslDistroNames) -contains $distro) {
                Assert-Removable -DistroName $distro
                Invoke-Native -FilePath (Get-WslExe) -Arguments @('--unregister', $distro) -IgnoreExitCode | Out-Null
            }
            if (Test-Path -LiteralPath $target) {
                Assert-InsideBaseDir -Path $target
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch { Write-Warn "rollback incomplete: $($_.Exception.Message)" }
        throw
    }
    finally {
        if ($tempTar -and $tarPath -and (Test-Path -LiteralPath $tarPath)) {
            Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ActionRun {
    if (-not $Name)    { throw "Action Run requires -Name." }
    if (-not $Command) { throw "Action Run requires -Command." }
    $distro = Resolve-DistroName -Requested $Name -FromImage ''
    if ((Get-WslDistroNames) -notcontains $distro) {
        throw "Distro '$distro' is not registered. Create it with -Action New."
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & (Get-WslExe) -d $distro -u $User -- /bin/sh -lc $Command; $rc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    exit $rc
}

function Invoke-ActionList {
    $all  = @(Get-WslDistroNames)
    $mine = @($all | Where-Object { $_.StartsWith($script:Prefix, [StringComparison]::Ordinal) })
    Write-Step "Ephemeral distros (prefix '$($script:Prefix)')"
    if ($mine.Count -eq 0) { Write-Host "  (none)" -ForegroundColor DarkGray }
    else { foreach ($m in $mine) { Write-Host "  $m" } }

    Write-Step "Other distros on this system -- never touched by this script"
    $others = @($all | Where-Object { -not $_.StartsWith($script:Prefix, [StringComparison]::Ordinal) })
    if ($others.Count -eq 0) { Write-Host "  (none)" -ForegroundColor DarkGray }
    else {
        foreach ($o in $others) {
            $tag = ''
            if (Test-ProtectedName -DistroName $o) { $tag = '   [PROTECTED]' }
            Write-Host ("  {0}{1}" -f $o, $tag) -ForegroundColor DarkGray
        }
    }
}

function Invoke-ActionPurge {
    $mine = @(Get-WslDistroNames | Where-Object { $_.StartsWith($script:Prefix, [StringComparison]::Ordinal) })
    if ($mine.Count -eq 0) { Write-Ok "nothing to purge"; return }
    Write-Step "Purging $($mine.Count) ephemeral distro(s): $($mine -join ', ')"
    if (-not (Confirm-Destructive -Target "$($mine.Count) distro(s)" -Operation 'Purge ephemeral distros')) { return }
    foreach ($d in $mine) {
        try { Remove-EphemeralDistro -DistroName $d -SkipConfirm }
        catch { Write-Warn "skip ${d}: $($_.Exception.Message)" }
    }
}

# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------
try {
    if ([string]::IsNullOrWhiteSpace($script:BaseDir)) { throw "LOCALAPPDATA is not set; cannot choose a base directory." }
    New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null

    switch ($Action) {
        'New'    { Invoke-ActionNew }
        'Run'    { Invoke-ActionRun }
        'List'   { Invoke-ActionList }
        'Remove' {
            if (-not $Name) { throw "Action Remove requires -Name." }
            Remove-EphemeralDistro -DistroName (Resolve-DistroName -Requested $Name -FromImage '')
        }
        'Purge'  { Invoke-ActionPurge }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
