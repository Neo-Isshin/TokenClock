# scripts/build-windows.ps1 —— 在 Windows 上构建 TokenClock（normal，Win32）并打成可分发的
# 便携 zip：TokenClock.exe + Swift 运行时 DLL（动态链接）+ VC++ 运行时 + 生成 sha256。
#
# Swift on Windows 的 --static-swift-stdlib 在官方工具链里没有静态库可用，故运行时仍动态链接；
# 把运行时 DLL 铺到 exe 同目录即可（Windows 加载器优先搜 exe 目录），形成自包含便携包。
#
# 用法（本地或 CI）：
#   pwsh scripts/build-windows.ps1              # 产物写到 .\dist\
#   pwsh scripts/build-windows.ps1 -Zip         # 额外打 zip + sha256
param([switch]$Zip)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

Write-Host '== swift build -c release (dynamic stdlib) =='
Push-Location $root
try {
    # SwiftPM does not automatically compile Win32 .rc files. Compile the version resource with
    # the LLVM tools bundled by Swift and pass it directly to lld-link so Explorer/installer APIs
    # expose FileVersion/ProductVersion/ProductName instead of empty metadata.
    $llvmRc = (Get-Command llvm-rc.exe -ErrorAction Stop).Source
    $resourceDir = Join-Path $root '.build\windows-resources'
    New-Item -ItemType Directory -Path $resourceDir -Force | Out-Null
    $resource = Join-Path $resourceDir 'TokenClock.res'
    & $llvmRc /FO $resource (Join-Path $root 'Sources\Win32Shim\TokenClock.rc')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $resource)) { throw 'failed to compile TokenClock.rc' }
    swift build -c release -Xlinker $resource
} finally { Pop-Location }

$exe = Join-Path $root '.build\release\TokenClock.exe'
if (-not (Test-Path $exe)) { throw "build did not produce $exe" }

# The Windows app deliberately uses native WinHTTP/Winsock. Swift 6.3.3's
# FoundationNetworking runtime has produced repeatable 0xc000001d cold-start crashes on the
# supported Windows 11 test host, so fail packaging if a URLSession dependency is reintroduced.
$llvmReadObj = (Get-Command llvm-readobj.exe -ErrorAction Stop).Source
$peImports = (& $llvmReadObj --coff-imports $exe | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'failed to inspect TokenClock.exe PE imports' }
if ($peImports -match '(?i)FoundationNetworking\.dll') {
    throw 'Windows build unexpectedly links FoundationNetworking.dll; use the native HTTP client'
}

# Swift 运行时目录必须与本次编译实际使用的工具链一致。机器上可能并存多套
# Swift；直接拿 PATH 中第一个 Runtimes 目录会把新版 EXE 和旧版 Foundation DLL
# 混装，最终在启动时崩溃。优先读取同一 swiftc 的 target-info，仅在旧工具链不
# 支持该查询时才使用兼容回退。
$runtimeBin = $null
$swiftCommand = Get-Command swift -ErrorAction Stop
$swiftc = Join-Path (Split-Path $swiftCommand.Source) 'swiftc.exe'
if (-not (Test-Path $swiftc)) { $swiftc = (Get-Command swiftc -ErrorAction Stop).Source }
try {
    $targetInfoText = (& $swiftc -print-target-info | Out-String)
    if ($LASTEXITCODE -eq 0 -and $targetInfoText) {
        $targetInfo = $targetInfoText | ConvertFrom-Json
        foreach ($candidate in @($targetInfo.paths.runtimeLibraryPaths)) {
            if ($candidate -and (Test-Path (Join-Path $candidate 'swiftCore.dll'))) {
                $runtimeBin = $candidate
                break
            }
        }
    }
} catch {
    Write-Warning "swiftc target-info unavailable; trying compatibility runtime discovery"
}
if (-not $runtimeBin) {
    foreach ($p in ($env:PATH -split ';')) {
        if ($p -and ($p -match 'Runtimes') -and (Test-Path (Join-Path $p 'swiftCore.dll'))) {
            $runtimeBin = $p
            break
        }
    }
}
if (-not $runtimeBin) { throw 'cannot locate the Swift runtime matching the active compiler' }
Write-Host "== runtime DLLs: $runtimeBin =="
$vcrt = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\*\BuildTools\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT\vcruntime140.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

$dist = Join-Path $root 'dist'
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory -Path $dist | Out-Null

Copy-Item $exe $dist
Get-ChildItem -LiteralPath $runtimeBin -Filter '*.dll' -File |
    Where-Object { $_.Name -ine 'FoundationNetworking.dll' } |
    Copy-Item -Destination $dist
if ($vcrt -and -not (Test-Path (Join-Path $dist 'vcruntime140.dll'))) { Copy-Item $vcrt $dist }
$resources = Join-Path (Split-Path $exe) 'TokenClock_TokenClock.resources'
if (-not (Test-Path $resources)) { throw "build did not produce resource bundle $resources" }
Copy-Item $resources (Join-Path $dist 'TokenClock_TokenClock.resources') -Recurse

$files = @(Get-ChildItem $dist -Recurse -File)
$count = $files.Count
$mb = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "== dist: $count files, $mb MB =="

if ($Zip) {
    $zipPath = Join-Path $root 'TokenClock-windows-x86_64.zip'
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    "$hash  $(Split-Path $zipPath -Leaf)" | Set-Content ($zipPath + '.sha256') -NoNewline
    Write-Host "== zip: $zipPath  sha256: $($hash.Substring(0,12))… =="
}
