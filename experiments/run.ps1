<#
.SYNOPSIS
    Reproduce the cross-libc dlopen evidence table end to end.

.DESCRIPTION
    Orchestrates three throwaway containers over one shared volume:

      alpine:3.22          -> builds a faithful musl-linked probe library
      debian:trixie-slim   -> builds libraries needing NEWER glibc symbols (2.36/2.38)
                              and stages that newer runtime
      debian:bullseye-slim -> glibc 2.31: the "older bundled glibc" under test

    Every experiment declares a prediction; the harness reports MATCH / MISMATCH.
    Exit code 0 means every prediction held.

.PARAMETER Engine
    Path to podman.exe or docker.exe. Auto-detected when omitted.

.PARAMETER Keep
    Keep the shared volume afterwards (for poking at the artifacts).

.EXAMPLE
    .\run.ps1
#>
[CmdletBinding()]
param(
    [string]$Engine,
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VolumeName = 'cross-libc-dlopen'
$Here       = Split-Path -Parent $MyInvocation.MyCommand.Path

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

function Invoke-Stage {
    <#
      Run a stage script inside a container by bind-mounting this directory read-only.

      Deliberately NOT piped over stdin: PowerShell re-encodes a piped string on its way
      to a native process, which corrupts the tail of the script and yields a bogus
      "sh: : not found" (exit 127) even though every command ran. Mounting the file
      sidesteps encoding entirely.

      The scripts must have LF endings; .gitattributes enforces that, and this function
      verifies it rather than trusting it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$ScriptFile,
        [Parameter(Mandatory = $true)][string]$Shell
    )
    $path = Join-Path $Here $ScriptFile
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing stage script: $path" }
    if ([IO.File]::ReadAllText($path).Contains("`r")) {
        throw ("$ScriptFile contains CR characters. Shell scripts here must be LF-only; " +
               "check core.autocrlf / .gitattributes.")
    }

    Write-Host "==> $Image  ($ScriptFile)" -ForegroundColor Cyan
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        # Out-Host, not bare invocation: anything left on the success stream would be
        # returned alongside the exit code, making the caller's `$rc` an array.
        # /repo is the repository root: stage 3 builds src/ and tools/ from it
        # so the fix is tested as it actually ships, not as a copy.
        $repo = Split-Path -Parent $Here
        & $engineExe run --rm `
            -v "${VolumeName}:/work" `
            -v "${Here}:/scripts:ro" `
            -v "${repo}:/repo:ro" `
            $Image $Shell "/scripts/$ScriptFile" 2>&1 | Out-Host
        $rc = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    return $rc
}

$engineExe = Resolve-Engine
Write-Host "engine: $engineExe" -ForegroundColor DarkGray

# A stale volume would silently reuse artifacts from a previous run.
& $engineExe volume rm -f $VolumeName 2>&1 | Out-Null

try {
    $rc = Invoke-Stage -Image 'alpine:3.22'          -ScriptFile '10-build-musl.sh'      -Shell 'sh'
    if ($rc -ne 0) { throw "stage 1 failed (exit $rc)" }

    $rc = Invoke-Stage -Image 'debian:trixie-slim'   -ScriptFile '20-build-newglibc.sh'  -Shell 'sh'
    if ($rc -ne 0) { throw "stage 2 failed (exit $rc)" }

    $rc = Invoke-Stage -Image 'debian:bullseye-slim' -ScriptFile '30-run-tests.sh'       -Shell 'bash'

    Write-Host ""
    if ($rc -eq 0) { Write-Host "ALL PREDICTIONS HELD" -ForegroundColor Green }
    else           { Write-Host "SOME PREDICTIONS DID NOT HOLD (exit $rc) -- investigate, this is a finding" -ForegroundColor Yellow }
    exit $rc
}
finally {
    if (-not $Keep) { & $engineExe volume rm -f $VolumeName 2>&1 | Out-Null }
    else { Write-Host "volume '$VolumeName' kept" -ForegroundColor DarkGray }
}
