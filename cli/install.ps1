# cli/install.ps1 —— TokenClock Windows 一键安装。
# 下载最新 release 的便携 zip（exe + Swift/VC++ 运行时），解压到 %LOCALAPPDATA%\Programs\TokenClock，
# 建开始菜单快捷方式并启动。开机自启用应用右键菜单里的「Launch at Login」即可（写 HKCU\…\Run）。
#
# 一键用法（PowerShell）：
#   irm https://raw.githubusercontent.com/Neo-Isshin/tokenclock/main/cli/install.ps1 | iex
#（Windows 源码合并到 main 之前，把上面 main 换成 windows-port）
$ErrorActionPreference = 'Stop'

$repo       = 'Neo-Isshin/tokenclock'
$asset      = 'TokenClock-windows-x86_64.zip'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\TokenClock'

Write-Host 'Fetching latest release…'
$rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'tokenclock-installer' }
$dl  = ($rel.assets | Where-Object name -eq $asset).browser_download_url
if (-not $dl) { throw "Asset '$asset' not found on the latest release. Publish the Windows zip to a release first." }

# 若已在运行，先关掉（否则 exe 被占用、无法覆盖）
Get-Process TokenClock -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

$tmp = (New-TemporaryFile).FullName + '.zip'
Write-Host "Downloading $asset…"
Invoke-WebRequest $dl -OutFile $tmp

if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
Expand-Archive $tmp -DestinationPath $installDir -Force
Remove-Item $tmp

# 开始菜单快捷方式
$exe = Join-Path $installDir 'TokenClock.exe'
$sc  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\TokenClock.lnk'
$ws  = New-Object -ComObject WScript.Shell
$s   = $ws.CreateShortcut($sc)
$s.TargetPath       = $exe
$s.WorkingDirectory = $installDir
$s.WindowStyle      = 7   # 最小化（浮窗本身无影响，托盘照常）
$s.Save()

Start-Process $exe -WorkingDirectory $installDir
Write-Host "✅ TokenClock installed to $installDir and started."
Write-Host '右键托盘图标查看菜单（尺寸/置顶/语言/开机自启/关于/退出）。'
