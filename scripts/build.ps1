# Build odit for a given target/config and stage the runtime files next
# to the produced binary. Invoked from .vscode/tasks.json.
#
#     scripts/build.ps1 -Target windows -Config debug
#
# Layout produced:
#     out/<target>/<config>/odit(.exe)
#     out/<target>/<config>/<vendored runtime deps>
#     out/<target>/<config>/font.ttf

param(
    [Parameter(Mandatory=$true)][ValidateSet('windows','linux','macos')] [string]$Target,
    [Parameter(Mandatory=$true)][ValidateSet('debug','release')]          [string]$Config
)

$ErrorActionPreference = 'Stop'

$odinTargetByPlatform = @{
    'windows' = 'windows_amd64'
    'linux'   = 'linux_amd64'
    'macos'   = 'darwin_arm64'
}
$odinTarget = $odinTargetByPlatform[$Target]

$outputDirectory = Join-Path 'out' (Join-Path $Target $Config)
$executableName  = if ($Target -eq 'windows') { 'odit.exe' } else { 'odit' }
$outputBinary    = Join-Path $outputDirectory $executableName

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$odinArguments = @('build', 'src', "-target:$odinTarget", "-out:$outputBinary")
if ($Config -eq 'debug') {
    $odinArguments += '-debug'
} else {
    $odinArguments += '-o:speed'
    $odinArguments += '-no-bounds-check'
    $odinArguments += '-subsystem:windows'
}

Write-Host "==> odin $($odinArguments -join ' ')"
& odin @odinArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

function Copy-IfChanged {
    param([string]$Source, [string]$DestinationDirectory)

    $sourceItem      = Get-Item -LiteralPath $Source
    $destinationPath = Join-Path $DestinationDirectory $sourceItem.Name

    if (Test-Path -LiteralPath $destinationPath) {
        $destinationItem = Get-Item -LiteralPath $destinationPath
        if ($destinationItem.Length -eq $sourceItem.Length -and
            $destinationItem.LastWriteTimeUtc -ge $sourceItem.LastWriteTimeUtc) {
            Write-Host "    up-to-date: $($sourceItem.Name)"
            return
        }
    }

    Copy-Item -Force -LiteralPath $sourceItem.FullName -Destination $destinationPath
    Write-Host "    staged: $($sourceItem.Name)"
}

# Copy platform-specific runtime libraries (DLLs / .so / .dylib).
$vendorPlatformDirectory = Join-Path 'vendor' $Target
if (Test-Path $vendorPlatformDirectory) {
    Get-ChildItem -Path $vendorPlatformDirectory -File | Where-Object { $_.Name -ne 'README.md' } | ForEach-Object {
        Copy-IfChanged -Source $_.FullName -DestinationDirectory $outputDirectory
    }
}

# Shared cross-platform assets.
$sharedFont = Join-Path 'vendor' 'font.ttf'
if (Test-Path $sharedFont) {
    Copy-IfChanged -Source $sharedFont -DestinationDirectory $outputDirectory
}

Write-Host "==> build complete: $outputBinary"
