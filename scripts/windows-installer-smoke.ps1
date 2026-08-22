# Non-destructive smoke test for cli/install.ps1.
# It installs a tiny fixture package into a disposable directory under the current user profile,
# verifies checksum enforcement/default side effects/check/uninstall, and removes only files that
# carry this script's marker.
param(
    [string] $TestRoot = (Join-Path $env:USERPROFILE 'TokenClockInstallerSmoke'),
    [switch] $KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $root 'cli\install.ps1'
$marker = Join-Path $TestRoot '.tokenclock-installer-smoke'

if (Test-Path -LiteralPath $TestRoot) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Refusing to reuse unmarked test directory: $TestRoot"
    }
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $TestRoot | Out-Null
Set-Content -LiteralPath $marker -Value 'owned by windows-installer-smoke.ps1' -Encoding ASCII
try {
    $payload = Join-Path $TestRoot 'payload'
    $install = Join-Path $TestRoot 'installed\TokenClock'
    New-Item -ItemType Directory -Path $payload | Out-Null
    Set-Content -LiteralPath (Join-Path $payload 'TokenClock.exe') -Value 'fixture executable' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $payload 'swiftCore.dll') -Value 'fixture runtime' -Encoding ASCII
    $zip = Join-Path $TestRoot 'TokenClock-windows-x86_64.zip'
    Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip
    $sha = "$zip.sha256"
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $sha -Value "$hash  TokenClock-windows-x86_64.zip" -NoNewline -Encoding ASCII

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runBefore = (Get-ItemProperty -Path $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock
    $startLink = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\TokenClock.lnk'
    $desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'TokenClock.lnk'
    $startBefore = Test-Path -LiteralPath $startLink
    $desktopBefore = Test-Path -LiteralPath $desktopLink

    & $installer -Action Install -InstallDir $install -PackagePath $zip -ChecksumPath $sha -NoStart
    if (-not (Test-Path -LiteralPath (Join-Path $install 'TokenClock.exe'))) { throw 'Fixture install failed.' }
    $originalExe = Get-Content -LiteralPath (Join-Path $install 'TokenClock.exe') -Raw
    $check = (& $installer -Action Check -InstallDir $install | ConvertFrom-Json)
    if (-not $check.installed) { throw 'Installer Check did not report the fixture installation.' }

    # Some fresh/minimal user sessions do not export the legacy profile variables even though
    # Windows known-folder APIs work. Installer initialization must not pass null into Join-Path.
    $savedProfileEnvironment = @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)
    $nullEnvironmentPassed = $false
    try {
        $env:USERPROFILE = $null
        $env:LOCALAPPDATA = $null
        $env:APPDATA = $null
        $nullEnvironmentCheck = (& $installer -Action Check -InstallDir $install | ConvertFrom-Json)
        $nullEnvironmentPassed = [bool] $nullEnvironmentCheck.installed
    } finally {
        $env:USERPROFILE = $savedProfileEnvironment[0]
        $env:LOCALAPPDATA = $savedProfileEnvironment[1]
        $env:APPDATA = $savedProfileEnvironment[2]
    }
    if (-not $nullEnvironmentPassed) { throw 'Installer did not tolerate missing legacy profile environment variables.' }

    # Reproduce Invoke-Expression execution: downloaded script text has no $PSCmdlet. Inject only
    # disposable fixture defaults so this stays offline and cannot touch the normal install path.
    $iexInstall = Join-Path $TestRoot 'invoke-expression\TokenClock'
    $iexSource = Get-Content -LiteralPath $installer -Raw
    $installParameter = "[string] " + '$InstallDir' + " = '" + $iexInstall.Replace("'", "''") + "',"
    $packageParameter = "[string] " + '$PackagePath' + " = '" + $zip.Replace("'", "''") + "',"
    $checksumParameter = "[string] " + '$ChecksumPath' + " = '" + $sha.Replace("'", "''") + "',"
    $iexSource = $iexSource.Replace('[string] $InstallDir,', $installParameter)
    $iexSource = $iexSource.Replace('[string] $PackagePath,', $packageParameter)
    $iexSource = $iexSource.Replace('[string] $ChecksumPath,', $checksumParameter)
    $iexSource = $iexSource.Replace('[switch] $NoStart,', '[switch] $NoStart = $true,')
    $invokeExpressionPassed = & {
        param([string] $Source, [string] $Target)
        Invoke-Expression $Source
        Test-Path -LiteralPath (Join-Path $Target 'TokenClock.exe') -PathType Leaf
    } $iexSource $iexInstall
    if (-not $invokeExpressionPassed) { throw 'Invoke-Expression one-liner path did not install the fixture.' }
    & $installer -Action Uninstall -InstallDir $iexInstall

    $runAfter = (Get-ItemProperty -Path $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock
    if ($runAfter -ne $runBefore) { throw 'Default install unexpectedly changed autostart.' }
    if ((Test-Path -LiteralPath $startLink) -ne $startBefore) { throw 'Default install unexpectedly changed Start Menu shortcuts.' }
    if ((Test-Path -LiteralPath $desktopLink) -ne $desktopBefore) { throw 'Default install unexpectedly changed desktop shortcuts.' }

    $badSha = Join-Path $TestRoot 'bad.sha256'
    Set-Content -LiteralPath $badSha -Value (('0' * 64) + '  TokenClock-windows-x86_64.zip') -Encoding ASCII
    $mismatchRejected = $false
    try {
        & $installer -Action Update -InstallDir $install -PackagePath $zip -ChecksumPath $badSha -NoStart
    } catch {
        $mismatchRejected = $_.Exception.Message -match 'SHA-256 mismatch'
    }
    if (-not $mismatchRejected) { throw 'Installer did not reject a bad checksum.' }

    # A fully verified but invalid staged package must not replace the existing installation.
    $invalidPayload = Join-Path $TestRoot 'invalid-payload'
    New-Item -ItemType Directory -Path $invalidPayload | Out-Null
    Set-Content -LiteralPath (Join-Path $invalidPayload 'TokenClock.exe') -Value 'invalid update' -Encoding ASCII
    $invalidZip = Join-Path $TestRoot 'invalid-update.zip'
    Compress-Archive -Path (Join-Path $invalidPayload '*') -DestinationPath $invalidZip
    $invalidSha = "$invalidZip.sha256"
    $invalidHash = (Get-FileHash -LiteralPath $invalidZip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $invalidSha -Value "$invalidHash  invalid-update.zip" -Encoding ASCII
    $invalidUpdateRejected = $false
    try {
        & $installer -Action Update -InstallDir $install -PackagePath $invalidZip -ChecksumPath $invalidSha -NoStart
    } catch {
        $invalidUpdateRejected = $_.Exception.Message -match 'Swift runtime'
    }
    if (-not $invalidUpdateRejected) { throw 'Installer accepted an invalid staged update.' }
    if ((Get-Content -LiteralPath (Join-Path $install 'TokenClock.exe') -Raw) -ne $originalExe) {
        throw 'Failed staged update changed the previous installation.'
    }

    # Reject traversal before extraction, even when the archive checksum is valid.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipSlip = Join-Path $TestRoot 'zip-slip.zip'
    $archive = [IO.Compression.ZipFile]::Open($zipSlip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('../escape.txt')
        $writer = New-Object IO.StreamWriter ($entry.Open())
        try { $writer.Write('must not escape') } finally { $writer.Dispose() }
    } finally {
        $archive.Dispose()
    }
    $zipSlipSha = "$zipSlip.sha256"
    $zipSlipHash = (Get-FileHash -LiteralPath $zipSlip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $zipSlipSha -Value "$zipSlipHash  zip-slip.zip" -Encoding ASCII
    $zipSlipRejected = $false
    try {
        & $installer -Action Update -InstallDir $install -PackagePath $zipSlip -ChecksumPath $zipSlipSha -NoStart
    } catch {
        $zipSlipRejected = $_.Exception.Message -match 'Unsafe archive entry'
    }
    if (-not $zipSlipRejected) { throw 'Installer did not reject a zip-slip entry.' }
    if (Test-Path -LiteralPath (Join-Path $TestRoot 'escape.txt')) { throw 'Zip-slip payload escaped the staging directory.' }

    $whatIfInstall = Join-Path $TestRoot 'whatif\TokenClock'
    & $installer -Action Install -InstallDir $whatIfInstall -PackagePath $zip -ChecksumPath $sha -NoStart -WhatIf
    if (Test-Path -LiteralPath $whatIfInstall) { throw 'WhatIf created the install target.' }

    $unowned = Join-Path $TestRoot 'unowned\TokenClock'
    New-Item -ItemType Directory -Path $unowned -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $unowned 'keep.txt') -Value 'owned by somebody else' -Encoding ASCII
    $unownedRejected = $false
    try {
        & $installer -Action Install -InstallDir $unowned -PackagePath $zip -ChecksumPath $sha -NoStart
    } catch {
        $unownedRejected = $_.Exception.Message -match 'unrecognized directory'
    }
    if (-not $unownedRejected -or -not (Test-Path -LiteralPath (Join-Path $unowned 'keep.txt'))) {
        throw 'Installer replaced or damaged an unrecognized directory.'
    }

    & $installer -Action Uninstall -InstallDir $install
    if (Test-Path -LiteralPath $install) { throw 'Fixture uninstall left the install directory behind.' }

    # Dot-source the installer in an isolated child scope, mock the GitHub response, and verify
    # that "latest" skips a newer release until it finds both Windows assets together.
    $releaseResolution = & {
        . $installer -Action Check -InstallDir $install | Out-Null
        function Invoke-RestMethod {
            param([string] $Uri, [hashtable] $Headers)
            $mockReleases = @(
                [pscustomobject]@{
                    tag_name = 'v2.0.0'; draft = $false; prerelease = $false
                    assets = @([pscustomobject]@{ name = 'TokenClock-normal-universal.tar.gz' })
                },
                [pscustomobject]@{
                    tag_name = 'v1.9.0'; draft = $false; prerelease = $false
                    assets = @(
                        [pscustomobject]@{ name = 'TokenClock-windows-x86_64.zip' },
                        [pscustomobject]@{ name = 'TokenClock-windows-x86_64.zip.sha256' }
                    )
                }
            )
            # Match Windows PowerShell 5.1 Invoke-RestMethod, which can emit a top-level JSON
            # array as one non-enumerated pipeline object.
            Write-Output -NoEnumerate $mockReleases
        }
        $Version = 'latest'
        $selectedRelease = Get-Release
        [pscustomobject]@{
            selectionPassed = ($selectedRelease.tag_name -eq 'v1.9.0')
            cacheBustingPassed = (
                (Get-AssetDownloadUrl ([pscustomobject]@{
                    id = 12345
                    browser_download_url = 'https://example.invalid/TokenClock.zip'
                })) -eq 'https://example.invalid/TokenClock.zip?asset_revision=12345'
            )
        }
    }
    $releaseSelectionPassed = [bool] $releaseResolution.selectionPassed
    $assetCacheBustingPassed = [bool] $releaseResolution.cacheBustingPassed
    if (-not $releaseSelectionPassed) { throw 'Latest release selection did not require both Windows assets.' }
    if (-not $assetCacheBustingPassed) { throw 'Release asset URL did not include its immutable asset revision.' }

    [ordered]@{
        passed = $true
        checksumVerified = $true
        checksumMismatchRejected = $mismatchRejected
        invalidUpdateRejected = $invalidUpdateRejected
        previousInstallPreserved = $true
        zipSlipRejected = $zipSlipRejected
        whatIfNoInstall = (-not (Test-Path -LiteralPath $whatIfInstall))
        unownedDirectoryRejected = $unownedRejected
        defaultAutostartUnchanged = ($runAfter -eq $runBefore)
        defaultShortcutsUnchanged = $true
        checkActionPassed = $check.installed
        missingProfileEnvironmentHandled = $nullEnvironmentPassed
        latestWindowsAssetPairSelection = $releaseSelectionPassed
        releaseAssetCacheBusting = $assetCacheBustingPassed
        invokeExpressionOneLinerPassed = $invokeExpressionPassed
        uninstallPassed = $true
        testRoot = $TestRoot
    } | ConvertTo-Json
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
