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
    swift build -c release
} finally { Pop-Location }

$exe = Join-Path $root '.build\release\TokenClock.exe'
if (-not (Test-Path $exe)) { throw "build did not produce $exe" }

# Swift 运行时目录：先从 PATH 里找含 swiftCore.dll 的 Swift\Runtimes 条目（最稳），再退回从 swift.exe 推导。
$runtimeBin = $null
foreach ($p in ($env:PATH -split ';')) {
    if ($p -and ($p -match 'Runtimes') -and (Test-Path (Join-Path $p 'swiftCore.dll'))) { $runtimeBin = $p; break }
}
if (-not $runtimeBin) {
    $swift = (Get-Command swift -ErrorAction SilentlyContinue).Source
    if (-not $swift) { $sw = @(where.exe swift); if ($sw) { $swift = $sw[0] } }
    if ($swift) {
        $swiftRoot = Split-Path (Split-Path (Split-Path (Split-Path $swift)))   # …\Swift
        foreach ($d in (Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory -ErrorAction SilentlyContinue)) {
            $cand = Join-Path $d.FullName 'usr\bin'
            if (Test-Path (Join-Path $cand 'swiftCore.dll')) { $runtimeBin = $cand; break }
        }
    }
}
if (-not $runtimeBin) { throw 'cannot locate Swift runtime (swiftCore.dll): neither PATH nor swift.exe resolved it' }
Write-Host "== runtime DLLs: $runtimeBin =="
$vcrt = Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\*\BuildTools\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT\vcruntime140.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

$dist = Join-Path $root 'dist'
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory -Path $dist | Out-Null

Copy-Item $exe $dist
Copy-Item (Join-Path $runtimeBin '*.dll') $dist
if ($vcrt -and -not (Test-Path (Join-Path $dist 'vcruntime140.dll'))) { Copy-Item $vcrt $dist }

$count = (Get-ChildItem $dist).Count
$mb = [math]::Round((Get-ChildItem $dist | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "== dist: $count files, $mb MB =="

if ($Zip) {
    $zipPath = Join-Path $root 'TokenClock-windows-x86_64.zip'
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    "$hash  $(Split-Path $zipPath -Leaf)" | Set-Content ($zipPath + '.sha256') -NoNewline
    Write-Host "== zip: $zipPath  sha256: $($hash.Substring(0,12))… =="
}
