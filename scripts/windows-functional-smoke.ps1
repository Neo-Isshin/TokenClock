param(
    [string]$Exe = "$PSScriptRoot\..\.build\x86_64-unknown-windows-msvc\release\TokenClock.exe",
    [string]$Out = "$env:TEMP\TokenClockWindowsSmoke",
    [switch]$AllowFluentFallback
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TCWinTest {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c,string t);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,StringBuilder s);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] public static extern IntPtr SendMessageText(IntPtr h,uint m,IntPtr w,string s);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr h,string t);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int i);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr h,string name);
  [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process,uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint data,UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk,byte scan,uint f,UIntPtr extra);
  public static IntPtr FindByClassAndPid(string wanted,uint wantedPid) {
    IntPtr found=IntPtr.Zero;
    EnumProc cb=delegate(IntPtr h,IntPtr l) {
      StringBuilder c=new StringBuilder(256); GetClassName(h,c,256); uint p; GetWindowThreadProcessId(h,out p);
      if(c.ToString()==wanted && p==wantedPid && IsWindowVisible(h)){found=h;return false;} return true;
    }; EnumWindows(cb,IntPtr.Zero); return found;
  }
  public static IntPtr FindByClassPidAndControl(string wanted,uint wantedPid,int controlId) {
    IntPtr found=IntPtr.Zero;
    EnumProc cb=delegate(IntPtr h,IntPtr l) {
      StringBuilder c=new StringBuilder(256); GetClassName(h,c,256); uint p; GetWindowThreadProcessId(h,out p);
      if(c.ToString()==wanted && p==wantedPid && IsWindowVisible(h) && GetDlgItem(h,controlId)!=IntPtr.Zero){found=h;return false;} return true;
    }; EnumWindows(cb,IntPtr.Zero); return found;
  }
}
"@

Get-Process TokenClock -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out, "$Out\themes", "$Out\fixtures", "$Out\localappdata\TokenClock", "$Out\isolated-user\AppData\Roaming", "$Out\isolated-user\AppData\Local" | Out-Null
Start-Transcript -LiteralPath "$Out\transcript.txt" -Force | Out-Null
trap {
    ($_ | Format-List * -Force | Out-String) | Set-Content -LiteralPath "$Out\error.txt" -Encoding UTF8
    Stop-Transcript | Out-Null
    break
}
$events = New-Object Collections.ArrayList
$metrics = New-Object Collections.ArrayList
$failures = New-Object Collections.ArrayList
$fluentChecks = New-Object Collections.ArrayList
$providerCount = 16
$fileSystemProviderCount = 15

function Window-Rect([IntPtr]$Handle) {
    $r = New-Object TCWinTest+RECT
    [void][TCWinTest]::GetWindowRect($Handle, [ref]$r)
    [ordered]@{ left=$r.L; top=$r.T; right=$r.R; bottom=$r.B; width=($r.R-$r.L); height=($r.B-$r.T) }
}
function Find-Main { [TCWinTest]::FindWindow("TokenClock", "TokenClock") }
function Wait-Main([int]$Milliseconds = 15000) {
    $h=[IntPtr]::Zero
    for($i=0; $i -lt [Math]::Ceiling($Milliseconds/100) -and $h -eq [IntPtr]::Zero; $i++) {
        $h=Find-Main; if($h -eq [IntPtr]::Zero){Start-Sleep -Milliseconds 100}
    }
    if($h -eq [IntPtr]::Zero){throw "TokenClock main window did not appear"}; $h
}
function Wait-Dialog([string]$Class,[uint32]$TargetPid,[int]$Milliseconds = 8000) {
    $d=[IntPtr]::Zero
    for($i=0; $i -lt [Math]::Ceiling($Milliseconds/100) -and $d -eq [IntPtr]::Zero; $i++) {
        $d=[TCWinTest]::FindByClassAndPid($Class,$TargetPid); if($d -eq [IntPtr]::Zero){Start-Sleep -Milliseconds 100}
    }; $d
}
function Wait-DialogControl([string]$Class,[uint32]$TargetPid,[int]$ControlId,[int]$Milliseconds = 8000) {
    $d=[IntPtr]::Zero
    for($i=0;$i-lt[Math]::Ceiling($Milliseconds/100)-and$d-eq[IntPtr]::Zero;$i++){
        $d=[TCWinTest]::FindByClassPidAndControl($Class,$TargetPid,$ControlId);if($d-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 100}
    };$d
}
function Wait-Hidden([IntPtr]$Handle,[int]$Milliseconds = 8000) {
    for($i=0;$i-lt[Math]::Ceiling($Milliseconds/100)-and[TCWinTest]::IsWindowVisible($Handle);$i++){Start-Sleep -Milliseconds 100}
    -not [TCWinTest]::IsWindowVisible($Handle)
}
function Wait-Detail([uint32]$TargetPid,[int]$Milliseconds = 8000) { Wait-Dialog "TokenClockDetail" $TargetPid $Milliseconds }
function Is-Alive([IntPtr]$Handle) {
    $p=Get-Process TokenClock -ErrorAction SilentlyContinue | Select-Object -First 1
    [ordered]@{ alive=($null-ne$p -and [TCWinTest]::IsWindow($Handle)); responding=if($p){$p.Responding}else{$false}; hung=if($p){[TCWinTest]::IsHungAppWindow($Handle)}else{$null} }
}
function Record([string]$Name,[IntPtr]$Handle) {
    $a=Is-Alive $Handle
    [void]$events.Add([ordered]@{name=$Name;alive=$a.alive;responding=$a.responding;hung=$a.hung;rect=if($a.alive){Window-Rect $Handle}else{$null};at=(Get-Date).ToString("o")})
    if($Name-ne"quit"-and(-not $a.alive -or -not $a.responding -or $a.hung)){[void]$failures.Add("$Name left the app dead/hung")}
}
function Check-Fluent([string]$Name,[IntPtr]$Handle,[int]$ExpectedMaterial,[switch]$LayeredExpected) {
    $style=[TCWinTest]::GetWindowLong($Handle,-20)
    $layered=(($style-band0x00080000)-ne0)
    $raw=[TCWinTest]::GetProp($Handle,"TokenClock.FluentApplied").ToInt64()
    $applied=if($raw-gt0){[int]($raw-1)}else{-1}
    $passed=if($LayeredExpected){$layered-and$raw-eq0}else{-not$layered-and$raw-gt0-and($AllowFluentFallback-or$applied-eq$ExpectedMaterial)}
    [void]$fluentChecks.Add([ordered]@{name=$Name;hwnd=$Handle.ToInt64();layered=$layered;propertyRaw=$raw;appliedMaterial=$applied;expectedMaterial=$ExpectedMaterial;fallbackAllowed=[bool]$AllowFluentFallback;passed=$passed})
    if(-not$passed){[void]$failures.Add("$Name Fluent check failed (layered=$layered, applied=$applied, expected=$ExpectedMaterial)")}
    $passed
}
function Command([IntPtr]$Handle,[int]$Id,[string]$Name,[int]$Wait=350) {
    [void][TCWinTest]::PostMessage($Handle,0x0111,[IntPtr]$Id,[IntPtr]::Zero); Start-Sleep -Milliseconds $Wait; Record $Name $Handle
}
function Click-Client([IntPtr]$Handle,[int]$X,[int]$Y,[string]$Name,[int]$Wait=500) {
    $r=Window-Rect $Handle; [void][TCWinTest]::SetForegroundWindow($Handle); [void][TCWinTest]::SetCursorPos($r.left+$X,$r.top+$Y)
    [TCWinTest]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [TCWinTest]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds $Wait; Record $Name $Handle
}
function Capture([string]$Name,[IntPtr]$Handle,[string]$Directory=$Out) {
    $r=Window-Rect $Handle; $screen=[Windows.Forms.Screen]::PrimaryScreen.Bounds
    $x=[Math]::Max($screen.Left,$r.left-24);$y=[Math]::Max($screen.Top,$r.top-24)
    $right=[Math]::Min($screen.Right,$r.right+24);$bottom=[Math]::Min($screen.Bottom,$r.bottom+24)
    $bmp=New-Object Drawing.Bitmap ([Math]::Max(1,$right-$x)),([Math]::Max(1,$bottom-$y));$g=[Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x,$y,0,0,$bmp.Size);$g.Dispose();$bmp.Save((Join-Path $Directory ($Name+".png")),[Drawing.Imaging.ImageFormat]::Png);$bmp.Dispose()
}
function Capture-Screen([string]$Name) {
    $s=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$bmp=New-Object Drawing.Bitmap $s.Width,$s.Height;$g=[Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($s.Left,$s.Top,0,0,$s.Size);$g.Dispose();$bmp.Save((Join-Path $Out ($Name+".png")),[Drawing.Imaging.ImageFormat]::Png);$bmp.Dispose()
}
function Capture-Exact([string]$Name,[IntPtr]$Handle) {
    $r=Window-Rect $Handle;$bmp=New-Object Drawing.Bitmap $r.width,$r.height;$g=[Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.left,$r.top,0,0,$bmp.Size);$g.Dispose();$path=Join-Path $Out ($Name+".png");$bmp.Save($path,[Drawing.Imaging.ImageFormat]::Png);$bmp.Dispose();$path
}
function Compare-Images([string]$First,[string]$Second) {
    $a=[Drawing.Bitmap]::FromFile($First);$b=[Drawing.Bitmap]::FromFile($Second)
    try {
        if($a.Width-ne$b.Width-or$a.Height-ne$b.Height){return [ordered]@{sameSize=$false}}
        [double]$sum=0;[int]$changed=0;[int]$count=0
        for($y=0;$y-lt$a.Height;$y+=4){for($x=0;$x-lt$a.Width;$x+=4){
            $p=$a.GetPixel($x,$y);$q=$b.GetPixel($x,$y);$d=([Math]::Abs([int]$p.R-[int]$q.R)+[Math]::Abs([int]$p.G-[int]$q.G)+[Math]::Abs([int]$p.B-[int]$q.B))/3.0
            $sum+=$d;if($d-ge8){$changed++};$count++
        }}
        $ratio=if($count){$changed/[double]$count}else{0}
        [ordered]@{sameSize=$true;sampledPixels=$count;meanAbsoluteRgbDifference=[Math]::Round($sum/[Math]::Max(1,$count),3);changedPixelRatio=[Math]::Round($ratio,4);wholeCardClearlyChanges=($ratio-ge0.65)}
    } finally {$a.Dispose();$b.Dispose()}
}
function Get-Text([IntPtr]$Dialog,[int]$Id) {$s=New-Object Text.StringBuilder 2048;[void][TCWinTest]::SendMessage([TCWinTest]::GetDlgItem($Dialog,$Id),0x000D,[IntPtr]2048,$s);$s.ToString()}
function Set-Text([IntPtr]$Dialog,[int]$Id,[string]$Value) {[void][TCWinTest]::SendMessageText([TCWinTest]::GetDlgItem($Dialog,$Id),0x000C,[IntPtr]::Zero,$Value)}
function Get-Check([IntPtr]$Dialog,[int]$Id) {[int][TCWinTest]::SendMessage([TCWinTest]::GetDlgItem($Dialog,$Id),0x00F0,[IntPtr]::Zero,[IntPtr]::Zero)}
function Set-Check([IntPtr]$Dialog,[int]$Id,[int]$Value) {[void][TCWinTest]::SendMessage([TCWinTest]::GetDlgItem($Dialog,$Id),0x00F1,[IntPtr]$Value,[IntPtr]::Zero)}
function Set-ClipboardRetry([string]$Value,[int]$Attempts=12) {
  for($i=0;$i-lt$Attempts;$i++) {
    try {[Windows.Forms.Clipboard]::SetDataObject($Value,$true,3,80);return}
    catch {if($i-eq$Attempts-1){throw};Start-Sleep -Milliseconds 100}
  }
}
function Get-ClipboardRetry([int]$Attempts=12) {
  for($i=0;$i-lt$Attempts;$i++) {
    try {return [Windows.Forms.Clipboard]::GetText()}
    catch {if($i-eq$Attempts-1){throw};Start-Sleep -Milliseconds 100}
  }
}
function Close-Dialog([IntPtr]$Dialog,[int]$Id) {[void][TCWinTest]::PostMessage($Dialog,0x0111,[IntPtr]$Id,[IntPtr]::Zero);for($i=0;$i-lt80-and[TCWinTest]::IsWindowVisible($Dialog);$i++){Start-Sleep -Milliseconds 100};Start-Sleep -Milliseconds 250}
function Click-Control([IntPtr]$Dialog,[int]$Id) {
    $control=[TCWinTest]::GetDlgItem($Dialog,$Id);if($control-eq[IntPtr]::Zero){throw "Control $Id missing"}
    $rect=New-Object TCWinTest+RECT;[void][TCWinTest]::GetWindowRect($control,[ref]$rect)
    [void][TCWinTest]::SetForegroundWindow($Dialog);[void][TCWinTest]::SetCursorPos([int](($rect.L+$rect.R)/2),[int](($rect.T+$rect.B)/2))
    [TCWinTest]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 80;[TCWinTest]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 180
}
function Wait-Control([IntPtr]$Dialog,[int]$Id,[int]$Milliseconds=8000) {
    $c=[IntPtr]::Zero
    for($i=0;$i-lt[Math]::Ceiling($Milliseconds/50)-and$c-eq[IntPtr]::Zero;$i++){$c=[TCWinTest]::GetDlgItem($Dialog,$Id);if($c-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 50}}
    $c
}
function Open-Settings([IntPtr]$Handle,[uint32]$TargetPid) {
    [void][TCWinTest]::PostMessage($Handle,0x0111,[IntPtr]120,[IntPtr]::Zero);$d=Wait-Dialog "TCDialog" $TargetPid
    if($d-eq[IntPtr]::Zero-or(Wait-Control $d 714)-eq[IntPtr]::Zero){throw "Settings overview controls missing"};Start-Sleep -Milliseconds 150;$d
}
function Open-Custom([IntPtr]$Handle,[uint32]$TargetPid) {
    [void][TCWinTest]::PostMessage($Handle,0x0111,[IntPtr]140,[IntPtr]::Zero);$d=Wait-Dialog "TCDialog" $TargetPid
    if($d-eq[IntPtr]::Zero-or(Wait-Control $d 540)-eq[IntPtr]::Zero){throw "Custom editor controls missing"};Start-Sleep -Milliseconds 150;$d
}
function Open-Section([IntPtr]$Overview,[uint32]$TargetPid,[int]$CommandId,[int]$ExpectedControl) {
    [void][TCWinTest]::PostMessage($Overview,0x0111,[IntPtr]$CommandId,[IntPtr]::Zero)
    $control=Wait-Control $Overview $ExpectedControl
    if($control-eq[IntPtr]::Zero-or-not[TCWinTest]::IsWindowVisible($Overview)){throw "Accordion section $CommandId control $ExpectedControl missing"}
    Start-Sleep -Milliseconds 150;$Overview
}
function Close-Section([IntPtr]$Overview,[int]$CommandId,[int]$ExpectedControl) {
    [void][TCWinTest]::PostMessage($Overview,0x0111,[IntPtr]$CommandId,[IntPtr]::Zero)
    for($i=0;$i-lt160-and[TCWinTest]::GetDlgItem($Overview,$ExpectedControl)-ne[IntPtr]::Zero;$i++){Start-Sleep -Milliseconds 50}
    if([TCWinTest]::GetDlgItem($Overview,$ExpectedControl)-ne[IntPtr]::Zero){throw "Accordion section $CommandId did not collapse"}
    Start-Sleep -Milliseconds 120;$Overview
}
function Open-ChildDialog([IntPtr]$Overview,[uint32]$TargetPid,[int]$CommandId,[int]$ExpectedControl) {
    [void][TCWinTest]::PostMessage($Overview,0x0111,[IntPtr]$CommandId,[IntPtr]::Zero)
    if(-not(Wait-Hidden $Overview)){throw "Custom overview did not close for section $CommandId"}
    $d=Wait-Dialog "TCDialog" $TargetPid
    if($d-eq[IntPtr]::Zero-or(Wait-Control $d $ExpectedControl)-eq[IntPtr]::Zero){throw "Custom section $CommandId control $ExpectedControl missing"}
    Start-Sleep -Milliseconds 150;$d
}
function Wait-Overview([uint32]$TargetPid,[int]$ExpectedControl=714) {
    $d=Wait-Dialog "TCDialog" $TargetPid
    if($d-eq[IntPtr]::Zero-or(Wait-Control $d $ExpectedControl)-eq[IntPtr]::Zero){throw "Overview did not return"};$d
}
function Api([int]$Port=9988) {try{Invoke-RestMethod "http://127.0.0.1:$Port/api/usage" -TimeoutSec 1}catch{$null}}
function Wait-Api([int]$Port=9988,[int]$Milliseconds=12000) {$v=$null;$deadline=(Get-Date).AddMilliseconds($Milliseconds);do{$v=Api $Port;if($null-eq$v){Start-Sleep -Milliseconds 150}}while($null-eq$v-and(Get-Date)-lt$deadline);$v}
function Sample([string]$Name,[int]$Seconds=2) {
    $p=Get-Process TokenClock -ErrorAction Stop;$p.Refresh();$cpu0=$p.TotalProcessorTime.TotalMilliseconds;Start-Sleep -Seconds $Seconds;$p.Refresh()
    $cpu=[Math]::Round((($p.TotalProcessorTime.TotalMilliseconds-$cpu0)/($Seconds*1000*[Environment]::ProcessorCount))*100,3)
    [void]$metrics.Add([ordered]@{name=$Name;workingSetMiB=[Math]::Round($p.WorkingSet64/1MB,2);privateMiB=[Math]::Round($p.PrivateMemorySize64/1MB,2);cpuPercent=$cpu;threads=$p.Threads.Count;handles=$p.HandleCount;gdiObjects=[TCWinTest]::GetGuiResources($p.Handle,0);userObjects=[TCWinTest]::GetGuiResources($p.Handle,1)})
}

$env:LOCALAPPDATA="$Out\localappdata"
$env:USERPROFILE="$Out\isolated-user"
$env:APPDATA="$Out\isolated-user\AppData\Roaming"
$emptyRoot="$Out\fixtures\provider-roots";New-Item -ItemType Directory -Force -Path $emptyRoot|Out-Null
$env:OPENCLAW_STATE_DIR="$emptyRoot\openclaw";$env:CLAUDE_CONFIG_DIR="$emptyRoot\claude";$env:GEMINI_CLI_HOME="$emptyRoot\gemini-parent";$env:CODEX_HOME="$emptyRoot\codex"
$env:HERMES_HOME="$emptyRoot\hermes";$env:OPENCODE_DB="$emptyRoot\opencode\state.db";$env:QWEN_RUNTIME_DIR="$emptyRoot\qwen";$env:COPILOT_OTEL_FILE_EXPORTER_PATH="$emptyRoot\copilot\otel.jsonl"
$env:GROK_HOME="$emptyRoot\grok";$env:ANTIGRAVITY_HOME="$emptyRoot\antigravity";$env:CLINE_HOME="$emptyRoot\cline";$env:CONTINUE_HOME="$emptyRoot\continue";$env:CURSOR_AGENT_HOME="$emptyRoot\cursor";$env:KIRO_HOME="$emptyRoot\kiro"
foreach($directory in @($env:OPENCLAW_STATE_DIR,$env:CLAUDE_CONFIG_DIR,$env:GEMINI_CLI_HOME,$env:CODEX_HOME,$env:HERMES_HOME,(Split-Path $env:OPENCODE_DB -Parent),$env:QWEN_RUNTIME_DIR,(Split-Path $env:COPILOT_OTEL_FILE_EXPORTER_PATH -Parent),$env:GROK_HOME,$env:ANTIGRAVITY_HOME,$env:CLINE_HOME,$env:CONTINUE_HOME,$env:CURSOR_AGENT_HOME,$env:KIRO_HOME)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
$initialAnalytics="$Out\fixtures\analytics.jsonl";$initialNow=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();('{"event":"message_send","time":'+$initialNow+',"properties":{"prompt_tokens":1234,"completion_tokens":4321}}')|Set-Content -LiteralPath $initialAnalytics -Encoding ASCII
$env:AIDER_ANALYTICS_LOG=$initialAnalytics;$env:CODEBUDDY_STATS_ENDPOINT='http://127.0.0.1:9'
[ordered]@{TC_language='en';TC_clockSize='medium';TC_clockSizeUserChosen=$true;TC_selectedTheme='classic';TC_enabledTools=@('Aider');TC_hasRunInitialDetection=$true;TC_apiServerEnabled=$true;TC_apiServerPort=9988;TC_aiderPath=$initialAnalytics;TC_codeBuddyEndpoint='http://127.0.0.1:9';TC_selectedCity='Seattle'}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$Out\localappdata\TokenClock\settings.json" -Encoding UTF8
$env:TC_MOCK="session"
$env:TC_WEATHER_MOCK="1"
$started=Get-Date
$process=Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
$h=Wait-Main; $startupWindowMs=[int]((Get-Date)-$started).TotalMilliseconds
$usage=Wait-Api; $startupApiMs=[int]((Get-Date)-$started).TotalMilliseconds
Start-Sleep -Seconds 2;Record "startup" $h;Capture "01-startup-classic" $h;Sample "idle-stable"
$pidApp=[uint32]$process.Id
[void](Check-Fluent "layered-clock-dial" $h 0 -LayeredExpected)

# Main-window drag and real left/right click paths. The round layered dial must stay compact;
# the detail content is a separate non-layered TokenClockDetail Acrylic HWND.
$r0=Window-Rect $h;$x=[int]($r0.width/2);$y=100;[void][TCWinTest]::SetForegroundWindow($h);[void][TCWinTest]::SetCursorPos($r0.left+$x,$r0.top+$y)
[TCWinTest]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 120;[void][TCWinTest]::SetCursorPos($r0.left+$x+38,$r0.top+$y+28)
$moveParam=[IntPtr]((($y+28)-shl16)-bor(($x+38)-band0xffff));[void][TCWinTest]::PostMessage($h,0x0200,[IntPtr]1,$moveParam);Start-Sleep -Milliseconds 100
[TCWinTest]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 450
$rDrag=Window-Rect $h;Record "real-drag" $h
Click-Client $h ([int]($rDrag.width/2)) 100 "left-click-detail-open" 650;$detail=Wait-Detail $pidApp
if($detail-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 250;Click-Client $h ([int]($rDrag.width/2)) 100 "left-click-detail-open-retry" 650;$detail=Wait-Detail $pidApp}
if($detail-eq[IntPtr]::Zero){throw "Independent TokenClockDetail window did not appear"}
$detail0=Window-Rect $detail;$dialWhileOpen=Window-Rect $h
[void](Check-Fluent "detail-acrylic" $detail 2)
Capture "02-detail-session" $detail;Capture-Screen "02b-dial-and-detail"
$forecastOffset=76 # TC_WEATHER_MOCK always provides the fixed four-slot forecast strip.
Click-Client $detail ([int]($detail0.width*0.75)) (20+$forecastOffset) "detail-group-model" 550;Capture "03-detail-model" $detail
for($toggleRound=1;$toggleRound-le3;$toggleRound++){
  Click-Client $detail ([int]($detail0.width*0.25)) (20+$forecastOffset) ("detail-group-session-repeat-$toggleRound") 180
  Click-Client $detail ([int]($detail0.width*0.75)) (20+$forecastOffset) ("detail-group-model-repeat-$toggleRound") 180
}
Capture "03b-detail-model-after-repeated-switches" $detail
Click-Client $detail ([int]($detail0.width*0.80)) (49+$forecastOffset) "detail-percentage" 300
for($toggleRound=1;$toggleRound-le3;$toggleRound++){
  Click-Client $detail ([int]($detail0.width*0.80)) (49+$forecastOffset) ("detail-percentage-off-repeat-$toggleRound") 180
  Click-Client $detail ([int]($detail0.width*0.80)) (49+$forecastOffset) ("detail-percentage-on-repeat-$toggleRound") 180
}
$detailSettings=Get-Content -Raw -LiteralPath "$Out\localappdata\TokenClock\settings.json" | ConvertFrom-Json
$costModePersisted=([int]$detailSettings.TC_dropdownValueMode-eq1)
if(-not$costModePersisted){[void]$failures.Add("By Cost click did not persist TC_dropdownValueMode=1")}
Capture "04-detail-model-percent" $detail;Capture "04c-detail-model-percent-after-repeated-switches" $detail
Click-Client $detail ([int]($detail0.width*0.20)) (49+$forecastOffset) "detail-codex-quota" 700;Capture "04b-detail-codex-quota" $detail
Click-Client $detail ([int]($detail0.width*0.20)) (49+$forecastOffset) "detail-codex-quota-close" 450
$beforeExpand=Window-Rect $detail;Click-Client $detail ([int]($beforeExpand.width/2)) (101+$forecastOffset) "detail-expand-first-row" 650;$afterExpand=Window-Rect $detail;Capture "05-detail-expanded" $detail
[void][TCWinTest]::PostMessage($detail,0x020A,[IntPtr](-120-shl16),[IntPtr]::Zero);Start-Sleep -Milliseconds 500;Record "detail-scroll" $h;Capture "05b-detail-scrolled" $detail;Sample "detail-expanded"
Click-Client $h ([int]((Window-Rect $h).width/2)) 100 "left-click-detail-close" 450
if([TCWinTest]::IsWindowVisible($detail)){Start-Sleep -Milliseconds 250;Click-Client $h ([int]((Window-Rect $h).width/2)) 100 "left-click-detail-close-retry" 450}
$detailClosed=(-not [TCWinTest]::IsWindowVisible($detail))

$rr=Window-Rect $h;[void][TCWinTest]::SetForegroundWindow($h);[void][TCWinTest]::SetCursorPos($rr.left+[int]($rr.width/2),$rr.top+100)
[TCWinTest]::mouse_event(0x0008,0,0,0,[UIntPtr]::Zero);[TCWinTest]::mouse_event(0x0010,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 700;Capture-Screen "06-main-context-menu"
[TCWinTest]::keybd_event(0x1B,0,0,[UIntPtr]::Zero);[TCWinTest]::keybd_event(0x1B,0,2,[UIntPtr]::Zero);Start-Sleep -Milliseconds 350;Record "main-context-menu" $h

# All built-in faces plus custom, in exact WindowsClockTheme.allCases order.
$themes=@("glass","classic","glacier","midnight","luxe","gufeng","railgun","sky","custom")
for($i=0;$i-lt$themes.Count;$i++){Command $h (60+$i) ("theme-"+$themes[$i]) 450;Capture (("{0:D2}-" -f $i)+$themes[$i]) $h "$Out\themes"}

# The real menu opens a visual 3x3 transient Acrylic picker rather than exposing raw theme IDs.
[void][TCWinTest]::PostMessage($h,0x0111,[IntPtr]125,[IntPtr]::Zero);$themePicker=Wait-Dialog "TCThemePicker" $pidApp 8000
if($themePicker-eq[IntPtr]::Zero){throw "Theme picker did not appear"}
[void](Check-Fluent "theme-picker-acrylic" $themePicker 2);Capture "06a-theme-picker" $themePicker
[void][TCWinTest]::PostMessage($themePicker,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);[void](Wait-Hidden $themePicker);Start-Sleep -Milliseconds 250;Record "theme-picker-cancel" $h

# Four macOS-normal sizes: transparent window width = dial + 80, height = dial when collapsed.
$sizes=@();foreach($s in @(@(20,"small",280,200),@(21,"medium",320,240),@(22,"large",380,300),@(23,"extraLarge",440,360))){Command $h $s[0] ("size-"+$s[1]) 350;$r=Window-Rect $h;$sizes+=[ordered]@{name=$s[1];width=$r.width;height=$r.height;passed=($r.width-eq$s[2]-and$r.height-eq$s[3])}}
Command $h 21 "size-restore-medium" 300

# Warm all bitmap caches, then repeatedly exercise the resize path that previously leaked
# selected GDI bitmaps. The stabilized cache must return to within two GDI objects.
Command $h 20 "gdi-warm-small" 180;Command $h 23 "gdi-warm-extra-large" 180;Command $h 21 "gdi-warm-medium" 220
$gdiProcess=Get-Process -Id $process.Id;$gdiProcess.Refresh();$gdiCycleBefore=[TCWinTest]::GetGuiResources($gdiProcess.Handle,0);$gdiCycles=@()
for($round=1;$round-le10;$round++){
  Command $h 20 ("gdi-cycle-$round-small") 110;Command $h 23 ("gdi-cycle-$round-extra-large") 110;Command $h 21 ("gdi-cycle-$round-medium") 140
  $gdiProcess.Refresh();$gdiCycles+=[ordered]@{round=$round;gdiObjects=[TCWinTest]::GetGuiResources($gdiProcess.Handle,0);alive=$gdiProcess.Responding}
}
$gdiProcess.Refresh();$gdiCycleAfter=[TCWinTest]::GetGuiResources($gdiProcess.Handle,0);$gdiCycleDelta=$gdiCycleAfter-$gdiCycleBefore
if($gdiCycleDelta-gt2){[void]$failures.Add("Repeated Small/XL/Medium GDI delta was $gdiCycleDelta (expected <= 2 after cache warmup)")}

# Every stable menu command/subcommand and clipboard behavior.
foreach($i in 0..3){Command $h (150+$i) ("opacity-"+(25*($i+1))) 180}
# Capture the complete detail HWND at each public opacity. At 100%, the native Acrylic
# property must be restored (raw value 3 = applied Acrylic 2); lower levels may use the
# whole-window fallback, but every adjacent pair must visibly change most of the card.
$opacityCaptures=@();$opacityPaths=@{}
foreach($opacityCase in @(@(150,25,"06c"),@(151,50,"06d"),@(152,75,"06e"),@(153,100,"06f"))){
  $opacity=[int]$opacityCase[1]
  Command $h ([int]$opacityCase[0]) ("opacity-$opacity-detail-special") 250
  Click-Client $h ([int]((Window-Rect $h).width/2)) 100 ("opacity-$opacity-detail-open") 600;$opacityDetail=Wait-Detail $pidApp
  if($opacityDetail-eq[IntPtr]::Zero){throw "Detail did not open at opacity $opacity"}
  $opacityPath=Capture-Exact ($opacityCase[2]+"-detail-opacity-$opacity") $opacityDetail;$opacityPaths[$opacity]=$opacityPath
  $opacityRaw=[TCWinTest]::GetProp($opacityDetail,"TokenClock.FluentApplied").ToInt64()
  $opacityCaptures+=[ordered]@{opacity=$opacity;path=$opacityPath;fluentPropertyRaw=$opacityRaw;alive=(Is-Alive $h)}
  Click-Client $h ([int]((Window-Rect $h).width/2)) 100 ("opacity-$opacity-detail-close") 400
}
$opacityComparisons=[ordered]@{
  '25to50'=Compare-Images $opacityPaths[25] $opacityPaths[50]
  '50to75'=Compare-Images $opacityPaths[50] $opacityPaths[75]
  '75to100'=Compare-Images $opacityPaths[75] $opacityPaths[100]
  '25to100'=Compare-Images $opacityPaths[25] $opacityPaths[100]
}
$opacityAllWholeCard=(@($opacityComparisons.Values|Where-Object{-not$_.wholeCardClearlyChanges}).Count-eq0)
$opacity100Raw=($opacityCaptures|Where-Object { $_.opacity -eq 100 }|Select-Object -First 1).fluentPropertyRaw
if($opacity100Raw-ne3){[void]$failures.Add("100% detail did not restore Acrylic property raw=3 (actual $opacity100Raw)")}
$clipboardBefore="sentinel";Set-ClipboardRetry $clipboardBefore;Command $h 100 "api-copy" 250;$clipboardAfter=Get-ClipboardRetry
if($clipboardAfter-notmatch'/api/usage$'){[void]$failures.Add("API Copy left unexpected clipboard text: $clipboardAfter")}
$top0=(([TCWinTest]::GetWindowLong($h,-20)-band8)-ne0);Command $h 10 "topmost-toggle"; $top1=(([TCWinTest]::GetWindowLong($h,-20)-band8)-ne0);Command $h 10 "topmost-restore"
foreach($i in 0..1){Command $h (70+$i) ("temperature-"+$i) 250}
foreach($i in 0..6){Command $h (80+$i) ("city-"+$i) 260}
Start-Sleep -Seconds 4
Click-Client $h ([int]((Window-Rect $h).width/2)) 100 "weather-detail-open" 700;$weatherDetailHandle=Wait-Detail $pidApp;$weatherDetail=Window-Rect $weatherDetailHandle;Capture "06b-weather-forecast" $weatherDetailHandle
Click-Client $h ([int]((Window-Rect $h).width/2)) 100 "weather-detail-close" 450
foreach($i in 0..7){Command $h (90+$i) ("timezone-"+$i) 180}
foreach($i in 0..2){Command $h (30+$i) ("language-"+$i) 250}
Command $h 160 "refresh-full" 700;Sample "after-full-refresh"
$runKey="HKCU:\Software\Microsoft\Windows\CurrentVersion\Run";$run0=(Get-ItemProperty $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock
Command $h 40 "autostart-toggle" 250;$run1=(Get-ItemProperty $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock;Command $h 40 "autostart-restore" 250;$run2=(Get-ItemProperty $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock

# One scrollable Mica settings window with seven accordion sections. The shell
# folder picker is only cancelled and is not classified as a TokenClock surface.
$d=Open-Settings $h $pidApp;Capture "07-settings-overview" $d;[void](Check-Fluent "settings-overview-mica" $d 1);Sample "settings-open" 1
Click-Control $d 700;if((Wait-Control $d 701)-eq[IntPtr]::Zero){throw "Real mouse click did not expand Auto Detect"};Capture "07a0-settings-detect" $d
$detectLabel='';[void][TCWinTest]::PostMessage($d,0x0111,[IntPtr]701,[IntPtr]::Zero)
for($i=0;$i-lt240-and$detectLabel-notmatch'^Detected \d+/\d+$';$i++){$detectLabel=Get-Text $d 702;if($detectLabel-notmatch'^Detected \d+/\d+$'){Start-Sleep -Milliseconds 50}}
Capture "07a1-settings-detected" $d
if($detectLabel-notmatch'^Detected \d+/\d+$'){[void]$failures.Add("Auto Detect accordion status did not update: $detectLabel")}
$d=Close-Section $d 700 701

# Cancel applies to the whole in-memory draft, matching the single-window model.
$d=Open-Section $d $pidApp 712 400;$rate0=Get-Text $d 400;Set-Text $d 400 "77";Close-Dialog $d 2
$d=Open-Settings $h $pidApp;$d=Open-Section $d $pidApp 712 400;$cancelPassed=((Get-Text $d 400)-eq$rate0);$d=Close-Section $d 712 400

$d=Open-Section $d $pidApp 710 300;[void](Check-Fluent "settings-tools-mica" $d 1);Capture "07a-settings-tools" $d
$checks=@();for($i=0;$i-lt$providerCount;$i++){$checks+=Get-Check $d (300+$i)}
for($i=0;$i-lt$providerCount;$i++){Set-Check $d (300+$i) 0};Set-Check $d 309 1
$d=Close-Section $d 710 300

$d=Open-Section $d $pidApp 711 200;[void](Check-Fluent "settings-paths-mica" $d 1);Capture "07b-settings-paths" $d
$pathHeaderBefore=(Window-Rect ([TCWinTest]::GetDlgItem($d,711))).top;$settingsRect=Window-Rect $d
[void][TCWinTest]::SetForegroundWindow($d);[void][TCWinTest]::SetCursorPos([int](($settingsRect.left+$settingsRect.right)/2),[int](($settingsRect.top+$settingsRect.bottom)/2))
$wheelDown=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]-120),0);[TCWinTest]::mouse_event(0x0800,0,0,$wheelDown,[UIntPtr]::Zero);Start-Sleep -Milliseconds 250
$pathHeaderAfter=(Window-Rect ([TCWinTest]::GetDlgItem($d,711))).top;Capture "07b2-settings-paths-wheel" $d;$settingsWheelPassed=($pathHeaderAfter-lt$pathHeaderBefore)
if(-not$settingsWheelPassed){[void]$failures.Add("Real mouse wheel did not scroll the expanded Settings accordion")}
$paths=@();$browse=@();for($i=0;$i-lt$providerCount;$i++){$paths+=Get-Text $d (200+$i);$browse+=([TCWinTest]::GetDlgItem($d,600+$i).ToInt64())}
[void][TCWinTest]::PostMessage($d,0x0111,[IntPtr]600,[IntPtr]::Zero);$picker=Wait-Dialog "#32770" $pidApp 5000
if($picker-ne[IntPtr]::Zero){[void][TCWinTest]::PostMessage($picker,0x0111,[IntPtr]2,[IntPtr]::Zero);[void](Wait-Hidden $picker 5000)}
$analytics="$Out\fixtures\analytics.jsonl";$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();('{"event":"message_send","time":'+$now+',"properties":{"prompt_tokens":1234,"completion_tokens":4321}}')|Set-Content -LiteralPath $analytics -Encoding ASCII
Set-Text $d 209 $analytics
$d=Close-Section $d 711 200

$d=Open-Section $d $pidApp 712 400;[void](Check-Fluent "settings-thresholds-mica" $d 1);Capture "07d-settings-thresholds" $d
Set-Text $d 400 "15";Set-Text $d 401 "400";Set-Text $d 402 "300";Set-Text $d 403 "200";Set-Text $d 404 "100"
$preThresholds=@((Get-Text $d 401),(Get-Text $d 402),(Get-Text $d 403),(Get-Text $d 404));$d=Close-Section $d 712 400

$d=Open-Section $d $pidApp 715 800;[void](Check-Fluent "settings-pricing-mica" $d 1);Capture "07c-settings-pricing" $d
$pricingCatalogBefore=Get-Text $d 760
$pricingSecondInitiallyHidden=(-not[TCWinTest]::IsWindowVisible([TCWinTest]::GetDlgItem($d,801)))
[void][TCWinTest]::PostMessage($d,0x0111,[IntPtr]751,[IntPtr]::Zero);Start-Sleep -Milliseconds 250
$pricingAddRowPassed=($pricingSecondInitiallyHidden-and[TCWinTest]::IsWindowVisible([TCWinTest]::GetDlgItem($d,801)))
Capture "07c2-settings-pricing-added-row" $d
[void][TCWinTest]::PostMessage($d,0x0111,[IntPtr]750,[IntPtr]::Zero);Start-Sleep -Milliseconds 2600
$pricingCatalogAfter=Get-Text $d 760
Set-Text $d 800 "smoke-price-model";Set-Text $d 810 "1.25";Set-Text $d 820 "10";Set-Text $d 830 "0.125";Set-Text $d 840 "2"
$d=Close-Section $d 715 800;$d=Open-Section $d $pidApp 715 800
$pricingCustomPersisted=((Get-Text $d 800)-eq"smoke-price-model"-and(Get-Text $d 810)-eq"1.25"-and(Get-Text $d 820)-eq"10")
Set-Text $d 800 "";$d=Close-Section $d 715 800;$d=Open-Section $d $pidApp 715 800
$pricingCustomRemoved=((Get-Text $d 800)-eq"");$d=Close-Section $d 715 800
if(-not$pricingCustomPersisted){[void]$failures.Add("Custom model pricing did not persist across accordion collapse/reopen")}
if(-not$pricingCustomRemoved){[void]$failures.Add("Clearing a custom price row did not persist in the settings draft")}
if(-not$pricingAddRowPassed){[void]$failures.Add("Add custom price did not reveal the next Fluent row")}

$d=Open-Section $d $pidApp 713 716;Capture "07f-settings-custom" $d;Click-Control $d 716
$inlineCustom=Wait-DialogControl "TCDialog" $pidApp 540 8000;$inlineCustomPassed=($inlineCustom-ne[IntPtr]::Zero-and$inlineCustom-ne$d)
if($inlineCustomPassed){Capture "07f2-settings-custom-editor" $inlineCustom;Close-Dialog $inlineCustom 2}else{[void]$failures.Add("Accordion Open editor did not present the custom-face editor")}
if((Wait-Control $d 716)-eq[IntPtr]::Zero){[void]$failures.Add("Settings accordion did not resume after closing the custom-face editor")}
$d=Close-Section $d 713 716
$d=Open-Section $d $pidApp 714 411;[void](Check-Fluent "settings-api-mica" $d 1);Capture "07e-settings-api" $d;Set-Check $d 411 0;$d=Close-Section $d 714 411
$preSave=[ordered]@{aider=$analytics;rate="15";thresholds=$preThresholds;api=0;enabled=@(for($i=0;$i-lt$providerCount;$i++){if($i-eq9){1}else{0}});providerCount=$providerCount;fileSystemProviderCount=$fileSystemProviderCount;codeBuddyPath=$paths[15]}
$preSave|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$Out\settings-before-save.json" -Encoding UTF8
Close-Dialog $d 1;Start-Sleep -Milliseconds 900
Copy-Item -LiteralPath "$Out\localappdata\TokenClock\settings.json" -Destination "$Out\settings-after-disable.json" -Force
$apiDisabled=($null-eq(Api 9988))
$d=Open-Settings $h $pidApp
$d=Open-Section $d $pidApp 711 200;$expandedAider=Get-Text $d 209;$d=Close-Section $d 711 200
$d=Open-Section $d $pidApp 712 400;$savedRate=Get-Text $d 400;$thresholds=@((Get-Text $d 401),(Get-Text $d 402),(Get-Text $d 403),(Get-Text $d 404));$d=Close-Section $d 712 400
$d=Open-Section $d $pidApp 714 411;Set-Check $d 411 1;Set-Text $d 412 "19988";$d=Close-Section $d 714 411;Close-Dialog $d 1
$newUsage=Wait-Api 19988 12000;Command $h 160 "refresh-after-path-save" 1000;$newUsage=Wait-Api 19988 5000
$aiderUsage=$null;if($newUsage){$aiderUsage=$newUsage.tools|Where-Object{$_.name-eq"Aider"}|Select-Object -First 1}
Sample "after-settings-save"
$d=Open-Settings $h $pidApp;$d=Open-Section $d $pidApp 714 411;Set-Text $d 412 "19989";$d=Close-Section $d 714 411;Close-Dialog $d 1;$rebindUsage=Wait-Api 19989 8000;Sample "api-rebind-19989"
$d=Open-Settings $h $pidApp;$d=Open-Section $d $pidApp 714 411;Set-Text $d 412 "19988";$d=Close-Section $d 714 411;Close-Dialog $d 1;$newUsage=Wait-Api 19988 8000;Sample "api-rebind-restored"

# Warm the dialog classes once, then make sure repeatedly opening and cancelling
# the redesigned overview does not leak GDI objects.
$d=Open-Settings $h $pidApp;Close-Dialog $d 2;Start-Sleep -Milliseconds 150
$settingsGdiProcess=Get-Process -Id $process.Id;$settingsGdiProcess.Refresh();$settingsGdiBefore=[TCWinTest]::GetGuiResources($settingsGdiProcess.Handle,0)
foreach($round in 1..20){$d=Open-Settings $h $pidApp;Close-Dialog $d 2;Start-Sleep -Milliseconds 80}
$settingsGdiProcess.Refresh();$settingsGdiAfter=[TCWinTest]::GetGuiResources($settingsGdiProcess.Handle,0);$settingsGdiDelta=$settingsGdiAfter-$settingsGdiBefore
if($settingsGdiDelta-gt2){[void]$failures.Add("Repeated Settings open/cancel GDI delta was $settingsGdiDelta (expected <= 2 after warmup)")}

# Named custom face create/save/apply/delete and editor persistence across overview,
# colors, and geometry pages.
$d=Open-Custom $h $pidApp;Capture "08-custom-overview" $d;[void](Check-Fluent "custom-overview-mica" $d 1);Set-Text $d 540 "Smoke Face"
$colorDlg=Open-ChildDialog $d $pidApp 570 500;[void](Check-Fluent "custom-colors-mica" $colorDlg 1);Capture "08a-custom-colors" $colorDlg;Close-Dialog $colorDlg 2;$d=Wait-Overview $pidApp 540
$geometryDlg=Open-ChildDialog $d $pidApp 571 520;[void](Check-Fluent "custom-geometry-mica" $geometryDlg 1);Capture "08b-custom-geometry" $geometryDlg
Set-Text $geometryDlg 530 "9.5";Set-Text $geometryDlg 531 "7";Set-Check $geometryDlg 550 1;[void][TCWinTest]::PostMessage($geometryDlg,0x0111,[IntPtr]520,[IntPtr]::Zero);Start-Sleep -Milliseconds 200;$handAfter=Get-Text $geometryDlg 520
Close-Dialog $geometryDlg 1;$d=Wait-Overview $pidApp 540;Close-Dialog $d 1;Start-Sleep -Milliseconds 500;Capture "09-custom-saved" $h
Command $h 200 "saved-theme-apply" 300;$d=Open-Custom $h $pidApp;$customName=Get-Text $d 540
$geometryDlg=Open-ChildDialog $d $pidApp 571 520;$customRim=Get-Text $geometryDlg 530;$customHour=Get-Text $geometryDlg 531;Close-Dialog $geometryDlg 2;$d=Wait-Overview $pidApp 540;Close-Dialog $d 2
[void][TCWinTest]::PostMessage($h,0x0111,[IntPtr]240,[IntPtr]::Zero);$deleteConfirm=Wait-Dialog "#32770" $pidApp 5000
if($deleteConfirm-ne[IntPtr]::Zero){[void][TCWinTest]::PostMessage($deleteConfirm,0x0111,[IntPtr]6,[IntPtr]::Zero);Start-Sleep -Milliseconds 350};Record "saved-theme-delete-confirmed" $h
Sample "after-custom-theme"

# About dialog, repeated API load, ordinary Quit and isolated-settings persistence restart.
[void][TCWinTest]::PostMessage($h,0x0111,[IntPtr]50,[IntPtr]::Zero);$about=Wait-Dialog "TCDialog" $pidApp 5000
if($about-ne[IntPtr]::Zero){[void](Check-Fluent "about-mica" $about 1);Capture "10-about" $about;[void][TCWinTest]::PostMessage($about,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 300};Record "about" $h;Sample "before-api-load"
$loadPort=if($newUsage){19988}elseif(Api 9988){9988}else{0};$api100Ms=-1;$apiHistory=$null
if($loadPort-gt0){
  $apiHistory=Invoke-RestMethod "http://127.0.0.1:$loadPort/api/history?days=7&detail=sessions" -TimeoutSec 3
  $apiStart=Get-Date
  for($i=0;$i-lt100;$i++){
    $requestOk=$false
    for($attempt=0;$attempt-lt2-and-not$requestOk;$attempt++){
      try{$null=Invoke-RestMethod "http://127.0.0.1:$loadPort/api/usage" -TimeoutSec 3;$requestOk=$true}catch{if($attempt-eq0){Start-Sleep -Milliseconds 100}else{throw}}
    }
  }
  $api100Ms=[int]((Get-Date)-$apiStart).TotalMilliseconds
}
Sample "after-100-api-requests"
Start-Sleep -Seconds 12;Sample "api-load-settled"
Command $h 1 "quit" 600;$quitPassed=(-not [bool](Get-Process TokenClock -ErrorAction SilentlyContinue))
$process=Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru;$h=Wait-Main;Start-Sleep -Seconds 2;$restartRect=Window-Rect $h;$restartApi=Wait-Api 19988 6000;Record "restart-persistence" $h;Sample "restart-idle"

$result=[ordered]@{
  status=if($failures.Count-gt0){'FAIL'}elseif($opacityAllWholeCard){'PASS'}else{'PARTIAL'}
  windows=[ordered]@{version=[Environment]::OSVersion.VersionString;logicalProcessors=[Environment]::ProcessorCount;session=(Get-Process -Id $PID).SessionId}
  startup=[ordered]@{windowMs=$startupWindowMs;apiMs=$startupApiMs;apiReady=($null-ne$usage)}
  events=$events;failures=$failures;sizes=$sizes
  drag=[ordered]@{before=$r0;after=$rDrag;moved=($r0.left-ne$rDrag.left-or$r0.top-ne$rDrag.top)}
  details=[ordered]@{dialWhileOpen=$dialWhileOpen;initial=$detail0;beforeExpand=$beforeExpand;afterExpand=$afterExpand;fixedHeight=($beforeExpand.height-eq$afterExpand.height);closed=$detailClosed;weather=$weatherDetail;forecastVisible=($weatherDetail.height-eq547);costModePersisted=$costModePersisted}
  menu=[ordered]@{clipboard=$clipboardAfter;clipboardPassed=($clipboardAfter-match"/api/usage$");topmostBefore=$top0;topmostAfter=$top1;autostartBefore=$run0;autostartToggled=$run1;autostartRestored=$run2;opacityCaptures=$opacityCaptures;opacityComparisons=$opacityComparisons;opacity100AcrylicRestored=($opacity100Raw-eq3);opacityAssessment=if($opacityAllWholeCard){'all-four-levels-whole-detail-visually-changed'}else{'partial-Windows-material-limitation'}}
  gdiResize=[ordered]@{sequence='Small -> Extra Large -> Medium';rounds=10;before=$gdiCycleBefore;after=$gdiCycleAfter;delta=$gdiCycleDelta;passed=($gdiCycleDelta-le2);samples=$gdiCycles}
  fluent=$fluentChecks
  settings=[ordered]@{providerCount=$checks.Count;allProviderControls=($checks.Count-eq$providerCount);browseButtonCount=(($browse|Where-Object{$_-ne0}).Count);allBrowseButtons=(($browse|Where-Object{$_-ne0}).Count-eq$fileSystemProviderCount);codeBuddyHasNoBrowse=($browse[15]-eq0);cancelPassed=$cancelPassed;folderPickerFound=($picker-ne[IntPtr]::Zero);mouseWheelPassed=$settingsWheelPassed;inlineCustomEditorPassed=$inlineCustomPassed;detectLabel=$detectLabel;pricingCatalogBefore=$pricingCatalogBefore;pricingCatalogAfter=$pricingCatalogAfter;pricingRefreshReturned=($pricingCatalogAfter-match"206");pricingAddRowPassed=$pricingAddRowPassed;pricingCustomPersisted=$pricingCustomPersisted;pricingCustomRemoved=$pricingCustomRemoved;gdiReopen=[ordered]@{rounds=20;before=$settingsGdiBefore;after=$settingsGdiAfter;delta=$settingsGdiDelta;passed=($settingsGdiDelta-le2)};apiDisabled=$apiDisabled;apiNewPort=($null-ne$newUsage);apiRebind=($null-ne$rebindUsage);aiderTokens=if($aiderUsage){$aiderUsage.todayTokens}else{$null};rate=$savedRate;thresholds=$thresholds;expandedAiderPath=$expandedAider}
  custom=[ordered]@{name=$customName;rim=$customRim;hourWidth=$customHour;hand=$handAfter;saved=($customName-eq"Smoke Face"-and$customRim-eq"9.5"-and$customHour-eq"7")}
  aboutFound=($about-ne[IntPtr]::Zero);deleteConfirmFound=($deleteConfirm-ne[IntPtr]::Zero);api100Ms=$api100Ms;historyPassed=($null-ne$apiHistory);quitPassed=$quitPassed
  restart=[ordered]@{rect=$restartRect;apiPortPersisted=($null-ne$restartApi)};metrics=$metrics;final=Is-Alive $h
}
$result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath "$Out\results.json" -Encoding UTF8
[void][TCWinTest]::PostMessage($h,0x0111,[IntPtr]1,[IntPtr]::Zero)
Stop-Transcript | Out-Null
