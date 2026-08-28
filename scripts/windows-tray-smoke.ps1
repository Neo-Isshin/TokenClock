param(
    [string]$Exe = "$PSScriptRoot\..\dist\TokenClock.exe",
    [string]$Out = "$env:TEMP\TokenClockTraySmoke",
    [int]$Port = 9993
)

$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TCTrayTest {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int command);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
  public static IntPtr FindByClassAndPid(string wanted, uint wantedPid) {
    IntPtr found=IntPtr.Zero;
    EnumProc cb=delegate(IntPtr h, IntPtr l) {
      StringBuilder c=new StringBuilder(128); GetClassName(h,c,128); uint p; GetWindowThreadProcessId(h,out p);
      if(c.ToString()==wanted && p==wantedPid){found=h;return false;} return true;
    }; EnumWindows(cb,IntPtr.Zero); return found;
  }
}
"@

if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){throw "TokenClock executable not found: $Exe"}
if(Test-Path -LiteralPath $Out){Remove-Item -LiteralPath $Out -Recurse -Force}
New-Item -ItemType Directory -Force -Path $Out,"$Out\localappdata\TokenClock","$Out\user\AppData\Roaming","$Out\user\AppData\Local"|Out-Null

$env:LOCALAPPDATA="$Out\localappdata"
$env:USERPROFILE="$Out\user"
$env:APPDATA="$Out\user\AppData\Roaming"
$env:TC_WEATHER_MOCK='1'
[ordered]@{
  TC_language='en';TC_clockSize='medium';TC_clockSizeUserChosen=$true;
  TC_selectedTheme='classic';TC_enabledTools=@();TC_hasRunInitialDetection=$true;
  TC_apiServerEnabled=$true;TC_apiServerPort=$Port;TC_selectedCity='Seattle'
}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$Out\localappdata\TokenClock\settings.json" -Encoding UTF8

function Wait-Until([scriptblock]$Condition,[int]$Milliseconds=12000){
  $deadline=(Get-Date).AddMilliseconds($Milliseconds)
  do {if(& $Condition){return $true};Start-Sleep -Milliseconds 100} while((Get-Date)-lt$deadline)
  $false
}
function Api-Ready {
  try {$null=Invoke-RestMethod "http://127.0.0.1:$Port/api/usage" -TimeoutSec 1;$true}catch{$false}
}

Get-Process TokenClock -ErrorAction SilentlyContinue|Stop-Process -Force
$process=Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
$h=[IntPtr]::Zero
try {
  if(-not(Wait-Until {$script:h=[TCTrayTest]::FindWindow('TokenClock','TokenClock');return ($script:h -ne [IntPtr]::Zero)})){throw 'main window did not appear'}
  if(-not(Wait-Until {Api-Ready})){throw 'API did not become ready'}
  $pidApp=[uint32]$process.Id

  # cmdVisibility=2 is the real right-click menu command.
  [void][TCTrayTest]::PostMessage($h,0x0111,[IntPtr]2,[IntPtr]::Zero)
  $hidden=Wait-Until {-not [TCTrayTest]::IsWindowVisible($h)}
  $aliveWhileHidden=(-not $process.HasExited) -and [TCTrayTest]::IsWindow($h) -and (-not [TCTrayTest]::IsHungAppWindow($h))
  $apiWhileHidden=Api-Ready

  # NOTIFYICON_VERSION_4: HIWORD=icon id 1, LOWORD=WM_LBUTTONUP.
  [void][TCTrayTest]::PostMessage($h,0x8001,[IntPtr]::Zero,[IntPtr]0x00010202)
  $restored=Wait-Until {[TCTrayTest]::IsWindowVisible($h)}
  $restoredWithLegacyTrayPayload=$false
  if(-not $restored){
    # Some window stations deliver the pre-v4 payload (event only). The production
    # WndProc intentionally accepts it because it reads only LOWORD(lParam).
    [void][TCTrayTest]::PostMessage($h,0x8001,[IntPtr]::Zero,[IntPtr]0x0202)
    $restoredWithLegacyTrayPayload=Wait-Until {[TCTrayTest]::IsWindowVisible($h)} 1500
    $restored=$restoredWithLegacyTrayPayload
  }
  $menuToggleCanRestore=$false
  if(-not $restored){
    [void][TCTrayTest]::PostMessage($h,0x0111,[IntPtr]2,[IntPtr]::Zero)
    $menuToggleCanRestore=Wait-Until {[TCTrayTest]::IsWindowVisible($h)} 1500
  }
  $directShowCanRestore=$false
  $asyncShowCanRestore=$false
  $setWindowPosCanRestore=$false
  if(-not $restored -and -not $menuToggleCanRestore){
    [void][TCTrayTest]::ShowWindow($h,5)
    $directShowCanRestore=Wait-Until {[TCTrayTest]::IsWindowVisible($h)} 1500
    if(-not $directShowCanRestore){
      [void][TCTrayTest]::ShowWindowAsync($h,5)
      $asyncShowCanRestore=Wait-Until {[TCTrayTest]::IsWindowVisible($h)} 1500
      if(-not $asyncShowCanRestore){
        [void][TCTrayTest]::SetWindowPos($h,[IntPtr]::Zero,0,0,0,0,0x47)
        $setWindowPosCanRestore=Wait-Until {[TCTrayTest]::IsWindowVisible($h)} 1500
      }
    }
  }
  # Explorer sends WM_LBUTTONDBLCLK after the first up; the debounce must ignore it.
  [void][TCTrayTest]::PostMessage($h,0x8001,[IntPtr]::Zero,[IntPtr]0x00010203)
  Start-Sleep -Milliseconds 200
  $detail=[TCTrayTest]::FindByClassAndPid('TokenClockDetail',$pidApp)
  $detailStayedClosed=($detail -eq [IntPtr]::Zero) -or (-not [TCTrayTest]::IsWindowVisible($detail))

  $passed=$hidden-and$aliveWhileHidden-and$apiWhileHidden-and$restored-and$detailStayedClosed
  $result=[ordered]@{
    passed=$passed;hidden=$hidden;aliveWhileHidden=$aliveWhileHidden;
    apiWhileHidden=$apiWhileHidden;restoredByTrayLeftClick=$restored;
    restoredWithLegacyTrayPayload=$restoredWithLegacyTrayPayload;
    menuToggleCanRestore=$menuToggleCanRestore;
    directShowCanRestore=$directShowCanRestore;
    asyncShowCanRestore=$asyncShowCanRestore;
    setWindowPosCanRestore=$setWindowPosCanRestore;
    doubleClickDidNotOpenDetail=$detailStayedClosed;pid=$process.Id;hwnd=$h.ToInt64()
  }
  $result|ConvertTo-Json -Depth 4|Set-Content -LiteralPath "$Out\result.json" -Encoding UTF8
  $result|ConvertTo-Json -Compress
  if(-not$passed){exit 1}
} finally {
  if($h -ne [IntPtr]::Zero){[void][TCTrayTest]::PostMessage($h,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)}
  if(-not(Wait-Until {$process.HasExited} 4000)){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}
}
