# TokenClock Windows per-user installer.
#
# One-liner:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Neo-Isshin/TokenClock/windows-port/cli/install.ps1)))
#
# Passing options through a one-liner:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Neo-Isshin/TokenClock/windows-port/cli/install.ps1))) -NoStart -StartMenuShortcut

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Install', 'Update', 'Check', 'Uninstall')]
    [string] $Action = 'Install',
    [string] $Version = 'latest',
    [string] $InstallDir,
    [string] $PackagePath,
    [string] $ChecksumPath,
    [switch] $AllowUnsigned,
    [switch] $NoStart,
    [switch] $StartMenuShortcut,
    [switch] $DesktopShortcut,
    [switch] $EnableAutostart,
    [switch] $RemoveUserData,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = 'Neo-Isshin/TokenClock'
$assetName = 'TokenClock-windows-x86_64.zip'
$checksumAssetName = "$assetName.sha256"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Get-KnownFolder(
    [Environment+SpecialFolder] $Folder,
    [string] $EnvironmentName,
    [string] $Fallback
) {
    $value = [Environment]::GetFolderPath($Folder)
    if ([string]::IsNullOrWhiteSpace($value) -and $EnvironmentName) {
        $value = [Environment]::GetEnvironmentVariable($EnvironmentName, 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Fallback }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Windows did not provide a path for $Folder. Sign in with a normal user profile and retry."
    }
    return $value
}

$userProfile = Get-KnownFolder ([Environment+SpecialFolder]::UserProfile) 'USERPROFILE' $null
$localAppData = Get-KnownFolder ([Environment+SpecialFolder]::LocalApplicationData) 'LOCALAPPDATA' (Join-Path $userProfile 'AppData\Local')
$roamingAppData = Get-KnownFolder ([Environment+SpecialFolder]::ApplicationData) 'APPDATA' (Join-Path $userProfile 'AppData\Roaming')
$desktopDirectory = Get-KnownFolder ([Environment+SpecialFolder]::DesktopDirectory) $null (Join-Path $userProfile 'Desktop')
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $localAppData 'Programs\TokenClock'
}
$startMenuLink = Join-Path $roamingAppData 'Microsoft\Windows\Start Menu\Programs\TokenClock.lnk'
$desktopLink = Join-Path $desktopDirectory 'TokenClock.lnk'
$userDataDir = Join-Path $localAppData 'TokenClock'

function Get-FullPath([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path must not be empty.' }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-SafeOwnedDirectory([string] $Path) {
    $candidate = Get-FullPath $Path
    $protected = @(
        [IO.Path]::GetPathRoot($candidate),
        (Get-FullPath $userProfile),
        (Get-FullPath $localAppData),
        (Get-FullPath $roamingAppData),
        (Get-FullPath (Join-Path $localAppData 'Programs'))
    )
    if ($protected -contains $candidate) { throw "Refusing broad install/uninstall target: $candidate" }
    return $candidate
}

function Test-TokenClockInstallation([string] $Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    $metadataPath = Join-Path $Directory 'install.json'
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($metadata.repository -eq $repo) { return $true }
        } catch { }
    }
    # Compatibility with Windows builds installed before install.json was introduced.
    return (Test-Path -LiteralPath (Join-Path $Directory 'TokenClock.exe') -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $Directory 'swiftCore.dll') -PathType Leaf)
}

function Stop-TokenClock([string] $ExpectedExe) {
    $expected = Get-FullPath $ExpectedExe
    $targets = @(Get-Process TokenClock -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-FullPath $_.Path) -eq $expected } catch { $false }
    })
    foreach ($process in $targets) {
        if ($process.CloseMainWindow()) {
            if ($process.WaitForExit(3000)) { continue }
        }
        if (-not $Force) {
            throw "TokenClock is still running from $expected. Quit it first, or rerun with -Force."
        }
        Stop-Process -Id $process.Id -Force
        [void] $process.WaitForExit(3000)
    }
}

function Remove-ShortcutIfOwned([string] $LinkPath, [string] $ExpectedExe) {
    if (-not (Test-Path -LiteralPath $LinkPath -PathType Leaf)) { return }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($LinkPath)
        if ((Get-FullPath $shortcut.TargetPath) -eq (Get-FullPath $ExpectedExe)) {
            Remove-Item -LiteralPath $LinkPath -Force
        }
    } catch {
        Write-Warning "Could not inspect shortcut $LinkPath; leaving it untouched."
    }
}

function New-Shortcut([string] $LinkPath, [string] $ExePath, [string] $WorkingDirectory) {
    $parent = Split-Path $LinkPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LinkPath)
    $shortcut.TargetPath = $ExePath
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = 'TokenClock normal for Windows'
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

function Test-ReleaseHasWindowsAssets($Release) {
    if ($null -eq $Release) { return $false }
    $names = @($Release.assets | ForEach-Object { [string] $_.name } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    return ($assetName -in $names) -and ($checksumAssetName -in $names)
}

function Get-AssetDownloadUrl($Asset) {
    if ($null -eq $Asset -or [string]::IsNullOrWhiteSpace([string] $Asset.browser_download_url)) {
        return $null
    }
    $url = [string] $Asset.browser_download_url
    $revision = [string] $Asset.id
    if ([string]::IsNullOrWhiteSpace($revision)) { $revision = [string] $Asset.updated_at }
    if ([string]::IsNullOrWhiteSpace($revision)) { return $url }
    $separator = if ($url.Contains('?')) { '&' } else { '?' }
    return ($url + $separator + 'asset_revision=' + [Uri]::EscapeDataString($revision))
}

function Get-Release {
    $headers = @{ 'User-Agent' = 'TokenClock-Windows-Installer'; 'Accept' = 'application/vnd.github+json' }
    if ($Version -eq 'latest') {
        # The repository's newest macOS/Linux release may precede its Windows asset upload.
        # Pick the newest stable release that already contains both the ZIP and its checksum.
        for ($page = 1; $page -le 10; $page++) {
            # Windows PowerShell 5.1 can preserve a top-level JSON array as one pipeline object
            # when Invoke-RestMethod is called directly inside @(...). Assign first so foreach
            # consistently receives individual release objects on both 5.1 and PowerShell 7.
            $response = Invoke-RestMethod "https://api.github.com/repos/$repo/releases?per_page=100&page=$page" -Headers $headers
            $releases = @($response)
            foreach ($release in $releases) {
                if (-not $release.draft -and -not $release.prerelease -and (Test-ReleaseHasWindowsAssets $release)) {
                    return $release
                }
            }
            if ($releases.Count -lt 100) { break }
        }
        throw "No stable TokenClock release contains both $assetName and $checksumAssetName."
    }
    $encoded = [Uri]::EscapeDataString($Version)
    return Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$encoded" -Headers $headers
}

function Read-ExpectedHash([string] $Path) {
    $line = (Get-Content -LiteralPath $Path -Raw).Trim()
    if ($line -notmatch '(?i)\b([a-f0-9]{64})\b') { throw "No SHA-256 digest found in $Path" }
    return $Matches[1].ToLowerInvariant()
}

function Test-ZipEntries([string] $ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($name) -or $name -match '(^|\\)\.\.(\\|$)') {
                throw "Unsafe archive entry: $($entry.FullName)"
            }
        }
    } finally {
        $archive.Dispose()
    }
}

$InstallDir = Assert-SafeOwnedDirectory $InstallDir
$exe = Join-Path $InstallDir 'TokenClock.exe'

if ($Action -eq 'Check') {
    $metadataPath = Join-Path $InstallDir 'install.json'
    $result = [ordered]@{
        installed = (Test-Path -LiteralPath $exe -PathType Leaf)
        installDir = $InstallDir
        executable = $exe
        metadata = if (Test-Path -LiteralPath $metadataPath) { Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json } else { $null }
        autostart = (Get-ItemProperty -Path $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock
    }
    $result | ConvertTo-Json -Depth 6
    return
}

if ($Action -eq 'Uninstall') {
    if ((Test-Path -LiteralPath $InstallDir) -and -not (Test-TokenClockInstallation $InstallDir)) {
        throw "Refusing to uninstall an unrecognized directory: $InstallDir"
    }
    if ($null -ne $PSCmdlet -and -not $PSCmdlet.ShouldProcess($InstallDir, 'Uninstall TokenClock')) { return }
    Stop-TokenClock $exe
    Remove-ShortcutIfOwned $startMenuLink $exe
    Remove-ShortcutIfOwned $desktopLink $exe
    $runValue = (Get-ItemProperty -Path $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock
    if ($runValue -and $runValue.Trim('"') -eq $exe) {
        Remove-ItemProperty -Path $runKey -Name TokenClock -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    if ($RemoveUserData -and (Test-Path -LiteralPath $userDataDir)) {
        Remove-Item -LiteralPath $userDataDir -Recurse -Force
    }
    Write-Host "TokenClock was removed from $InstallDir"
    if (-not $RemoveUserData) { Write-Host "Settings were preserved in $userDataDir (use -RemoveUserData to delete them)." }
    return
}

if ((Test-Path -LiteralPath $InstallDir) -and -not (Test-TokenClockInstallation $InstallDir)) {
    throw "Refusing to replace an unrecognized directory: $InstallDir"
}
# Invoke-Expression runs downloaded text in its caller's scope and does not create $PSCmdlet,
# even when that text contains CmdletBinding. Keep the short pipeline form compatible while
# explicit scriptblock invocation continues to provide ShouldProcess and WhatIf normally.
if ($null -ne $PSCmdlet -and -not $PSCmdlet.ShouldProcess($InstallDir, "$Action TokenClock")) { return }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("TokenClockInstaller-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $zip = Join-Path $temporaryRoot $assetName
    $sha = Join-Path $temporaryRoot $checksumAssetName
    $releaseTag = 'local-package'

    if ($PackagePath) {
        Copy-Item -LiteralPath (Get-FullPath $PackagePath) -Destination $zip
        if ($ChecksumPath) { Copy-Item -LiteralPath (Get-FullPath $ChecksumPath) -Destination $sha }
    } else {
        Write-Host "Fetching TokenClock release metadata ($Version)..."
        $release = Get-Release
        if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string] $release.tag_name)) {
            throw 'GitHub returned release metadata without a tag name. Retry shortly or specify -Version v1.5.2.'
        }
        $releaseTag = [string] $release.tag_name
        $zipAsset = $release.assets | Where-Object name -eq $assetName | Select-Object -First 1
        $shaAsset = $release.assets | Where-Object name -eq $checksumAssetName | Select-Object -First 1
        # A workflow and a local release may replace an asset under the same public filename.
        # Include the GitHub asset id so CDNs cannot serve bytes from the previous asset object.
        $zipUrl = Get-AssetDownloadUrl $zipAsset
        $shaUrl = Get-AssetDownloadUrl $shaAsset
        if (-not $zipUrl) { throw "Release '$releaseTag' has no $assetName asset." }
        Invoke-WebRequest $zipUrl -OutFile $zip -Headers @{ 'User-Agent' = 'TokenClock-Windows-Installer' }
        if ($shaUrl) { Invoke-WebRequest $shaUrl -OutFile $sha -Headers @{ 'User-Agent' = 'TokenClock-Windows-Installer' } }
    }

    if (Test-Path -LiteralPath $sha -PathType Leaf) {
        $expected = Read-ExpectedHash $sha
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "SHA-256 mismatch: expected $expected, got $actual" }
        Write-Host "SHA-256 verified: $actual"
    } elseif (-not $AllowUnsigned) {
        throw "No checksum was published for $assetName. Refusing installation; use -AllowUnsigned only if you trust the source."
    } else {
        Write-Warning 'Installing without checksum verification because -AllowUnsigned was explicitly supplied.'
    }

    Test-ZipEntries $zip
    $staging = Join-Path $temporaryRoot 'staging'
    Expand-Archive -LiteralPath $zip -DestinationPath $staging
    $stagedExe = Join-Path $staging 'TokenClock.exe'
    if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) { throw 'Archive does not contain TokenClock.exe at its root.' }
    if (-not (Get-ChildItem -LiteralPath $staging -Filter 'swiftCore.dll' -File -ErrorAction SilentlyContinue)) {
        throw 'Archive does not contain the Swift runtime (swiftCore.dll).'
    }

    Stop-TokenClock $exe
    $parent = Split-Path $InstallDir -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $backup = "$InstallDir.backup-$([guid]::NewGuid().ToString('N'))"
    $hadPrevious = Test-Path -LiteralPath $InstallDir
    try {
        if ($hadPrevious) { Move-Item -LiteralPath $InstallDir -Destination $backup }
        Move-Item -LiteralPath $staging -Destination $InstallDir
        [ordered]@{
            repository = $repo
            release = $releaseTag
            asset = $assetName
            installedAt = [DateTimeOffset]::Now.ToString('o')
            sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir 'install.json') -Encoding UTF8
        if ($hadPrevious) { Remove-Item -LiteralPath $backup -Recurse -Force }
    } catch {
        if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
        if ($hadPrevious -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $InstallDir }
        throw
    }

    if ($StartMenuShortcut) { New-Shortcut $startMenuLink $exe $InstallDir }
    if ($DesktopShortcut) { New-Shortcut $desktopLink $exe $InstallDir }
    if ($EnableAutostart) {
        if (-not (Test-Path -LiteralPath $runKey)) { New-Item -Path $runKey -Force | Out-Null }
        New-ItemProperty -Path $runKey -Name TokenClock -PropertyType String -Value ('"' + $exe + '"') -Force | Out-Null
    }
    if (-not $NoStart) { Start-Process -FilePath $exe -WorkingDirectory $InstallDir }

    Write-Host "TokenClock $releaseTag installed to $InstallDir"
    if (-not $StartMenuShortcut -and -not $DesktopShortcut) {
        Write-Host 'No shortcut was created. Add -StartMenuShortcut or -DesktopShortcut explicitly if desired.'
    }
    if (-not $EnableAutostart) { Write-Host 'Autostart was not changed. Add -EnableAutostart explicitly if desired.' }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
