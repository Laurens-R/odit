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

function Copy-FileIfChanged {
    param([string]$Source, [string]$Destination, [string]$DisplayName)

    $sourceItem = Get-Item -LiteralPath $Source

    if (Test-Path -LiteralPath $Destination) {
        $destinationItem = Get-Item -LiteralPath $Destination
        if ($destinationItem.Length -eq $sourceItem.Length -and
            $destinationItem.LastWriteTimeUtc -ge $sourceItem.LastWriteTimeUtc) {
            Write-Host "    up-to-date: $DisplayName"
            return
        }
    }

    $destinationDirectory = [System.IO.Path]::GetDirectoryName($Destination)
    if (-not [string]::IsNullOrEmpty($destinationDirectory) -and -not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    }

    Copy-Item -Force -LiteralPath $sourceItem.FullName -Destination $Destination
    Write-Host "    staged: $DisplayName"
}

# Two-pass copy from vendor/:
#   Pass 1 — every file under vendor/ that isn't inside a platform-specific
#            subdir (linux/, macos/, windows/) gets staged. Preserves any
#            nested directory layout so vendor/shared/foo/bar.txt lands at
#            out/<target>/<config>/shared/foo/bar.txt.
#   Pass 2 — files under vendor/<target>/ are then staged on TOP of pass 1,
#            with the platform dir itself stripped from the destination
#            path. vendor/windows/lsp/ols.exe → out/windows/debug/lsp/ols.exe.
# README.md files at any depth are docs and skipped.

$platformSubdirectoryNames = @('linux', 'macos', 'windows')

if (Test-Path 'vendor') {
    $vendorRootFullPath = (Get-Item -LiteralPath 'vendor').FullName

    # Pass 1: shared.
    Get-ChildItem -Path 'vendor' -File -Recurse | Where-Object { $_.Name -ne 'README.md' } | ForEach-Object {
        $relativePath = $_.FullName.Substring($vendorRootFullPath.Length).TrimStart('\','/')

        $isPlatformSpecific = $false
        foreach ($platformName in $platformSubdirectoryNames) {
            if ($relativePath.StartsWith("$platformName\", [System.StringComparison]::OrdinalIgnoreCase) -or
                $relativePath.StartsWith("$platformName/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $isPlatformSpecific = $true
                break
            }
        }
        if ($isPlatformSpecific) { return }

        $destinationPath = Join-Path $outputDirectory $relativePath
        Copy-FileIfChanged -Source $_.FullName -Destination $destinationPath -DisplayName $relativePath
    }

    # Pass 2: platform-specific overlay.
    $vendorPlatformDirectory = Join-Path 'vendor' $Target
    if (Test-Path $vendorPlatformDirectory) {
        $vendorPlatformFullPath = (Get-Item -LiteralPath $vendorPlatformDirectory).FullName
        Get-ChildItem -Path $vendorPlatformDirectory -File -Recurse | Where-Object { $_.Name -ne 'README.md' } | ForEach-Object {
            $relativePath    = $_.FullName.Substring($vendorPlatformFullPath.Length).TrimStart('\','/')
            $destinationPath = Join-Path $outputDirectory $relativePath
            Copy-FileIfChanged -Source $_.FullName -Destination $destinationPath -DisplayName $relativePath
        }
    }
}

Write-Host "==> build complete: $outputBinary"
