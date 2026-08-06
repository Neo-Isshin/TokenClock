param(
    [string]$Exe = "$PSScriptRoot\..\.build\x86_64-unknown-windows-msvc\release\TokenClock.exe",
    [string]$Out = "$env:TEMP\TokenClockWindowsSmoke"
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
}
"@

Get-Process TokenClock -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out, "$Out\themes", "$Out\fixtures", "$Out\localappdata" | Out-Null
Start-Transcript -LiteralPath "$Out\transcript.txt" -Force | Out-Null
trap {
    ($_ | Format-List * -Force | Out-String) | Set-Content -LiteralPath "$Out\error.txt" -Encoding UTF8
    Stop-Transcript | Out-Null
    break
}
$events = New-Object Collections.ArrayList
$metrics = New-Object Collections.ArrayList
$failures = New-Object Collections.ArrayList

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
function Is-Alive([IntPtr]$Handle) {
    $p=Get-Process TokenClock -ErrorAction SilentlyContinue | Select-Object -First 1
    [ordered]@{ alive=($null-ne$p -and [TCWinTest]::IsWindow($Handle)); responding=if($p){$p.Responding}else{$false}; hung=if($p){[TCWinTest]::IsHungAppWindow($Handle)}else{$null} }
}
function Record([string]$Name,[IntPtr]$Handle) {
    $a=Is-Alive $Handle
    [void]$events.Add([ordered]@{name=$Name;alive=$a.alive;responding=$a.responding;hung=$a.hung;rect=if($a.alive){Window-Rect $Handle}else{$null};at=(Get-Date).ToString("o")})
    if($Name-ne"quit"-and(-not $a.alive -or -not $a.responding -or $a.hung)){[void]$failures.Add("$Name left the app dead/hung")}
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
function Get-Text([IntPtr]$Dialog,[int]$Id) {$s=New-Object Text.StringBuilder 2048;[void][TCWinTest]::SendMessage([TCWinTest]::GetDlgItem($Dialog,$Id),0x000D,[IntPtr]2048,$s);$s.ToString()}
function Set-Text([IntPtr]$Dialog,[int]$Id,[string]$Value) {[void][TCWinTest]::SendMessageText([TCWinTest]::GetDlgItem($Dialog,$Id),0x000C,[IntPtr]::Zero,$Value)}
function Get-Check([IntPtr]$Dialog,[int]$Id) {[int][TCWinTest]::SendMessage([TCWinTest]::GetDlgItem($Dialog,$Id),0x00F0,[IntPtr]::Zero,[IntPtr]::Zero)}
function Set-Check([IntPtr]$Dialog,[int]$Id,[int]$Value) {[void][TCWinTest]::SendMessage([TCWinTest]::GetDlgItem($Dialog,$Id),0x00F1,[IntPtr]$Value,[IntPtr]::Zero)}
function Close-Dialog([IntPtr]$Dialog,[int]$Id) {[void][TCWinTest]::PostMessage($Dialog,0x0111,[IntPtr]$Id,[IntPtr]::Zero);for($i=0;$i-lt80-and[TCWinTest]::IsWindowVisible($Dialog);$i++){Start-Sleep -Milliseconds 100};Start-Sleep -Milliseconds 250}
function Wait-Control([IntPtr]$Dialog,[int]$Id,[int]$Milliseconds=8000) {
    $c=[IntPtr]::Zero
    for($i=0;$i-lt[Math]::Ceiling($Milliseconds/50)-and$c-eq[IntPtr]::Zero;$i++){$c=[TCWinTest]::GetDlgItem($Dialog,$Id);if($c-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 50}}
    $c
}
function Open-Settings([IntPtr]$Handle,[uint32]$TargetPid) {
    [void][TCWinTest]::PostMessage($Handle,0x0111,[IntPtr]120,[IntPtr]::Zero);$d=Wait-Dialog "TCDialog" $TargetPid
    if($d-eq[IntPtr]::Zero-or(Wait-Control $d 412)-eq[IntPtr]::Zero){throw "Settings dialog controls missing"};Start-Sleep -Milliseconds 150;$d
}
function Open-Custom([IntPtr]$Handle,[uint32]$TargetPid) {
    [void][TCWinTest]::PostMessage($Handle,0x0111,[IntPtr]140,[IntPtr]::Zero);$d=Wait-Dialog "TCDialog" $TargetPid
    if($d-eq[IntPtr]::Zero-or(Wait-Control $d 540)-eq[IntPtr]::Zero){throw "Custom editor controls missing"};Start-Sleep -Milliseconds 150;$d
}
function Api([int]$Port=9988) {try{Invoke-RestMethod "http://127.0.0.1:$Port/api/usage" -TimeoutSec 1}catch{$null}}
function Wait-Api([int]$Port=9988,[int]$Milliseconds=12000) {$v=$null;$deadline=(Get-Date).AddMilliseconds($Milliseconds);do{$v=Api $Port;if($null-eq$v){Start-Sleep -Milliseconds 150}}while($null-eq$v-and(Get-Date)-lt$deadline);$v}
function Sample([string]$Name,[int]$Seconds=2) {
    $p=Get-Process TokenClock -ErrorAction Stop;$p.Refresh();$cpu0=$p.TotalProcessorTime.TotalMilliseconds;Start-Sleep -Seconds $Seconds;$p.Refresh()
    $cpu=[Math]::Round((($p.TotalProcessorTime.TotalMilliseconds-$cpu0)/($Seconds*1000*[Environment]::ProcessorCount))*100,3)
    [void]$metrics.Add([ordered]@{name=$Name;workingSetMiB=[Math]::Round($p.WorkingSet64/1MB,2);privateMiB=[Math]::Round($p.PrivateMemorySize64/1MB,2);cpuPercent=$cpu;threads=$p.Threads.Count;handles=$p.HandleCount})
}

$env:LOCALAPPDATA="$Out\localappdata"
$env:TC_MOCK="session"
$env:TC_WEATHER_MOCK="1"
$started=Get-Date
$process=Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
$h=Wait-Main; $startupWindowMs=[int]((Get-Date)-$started).TotalMilliseconds
$usage=Wait-Api; $startupApiMs=[int]((Get-Date)-$started).TotalMilliseconds
Start-Sleep -Seconds 2;Record "startup" $h;Capture "01-startup-classic" $h;Sample "idle-stable"
$pidApp=[uint32]$process.Id

# Main-window drag and real left/right click paths.
$r0=Window-Rect $h;$x=[int]($r0.width/2);$y=100;[void][TCWinTest]::SetForegroundWindow($h);[void][TCWinTest]::SetCursorPos($r0.left+$x,$r0.top+$y)
[TCWinTest]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 120;[void][TCWinTest]::SetCursorPos($r0.left+$x+38,$r0.top+$y+28)
$moveParam=[IntPtr]((($y+28)-shl16)-bor(($x+38)-band0xffff));[void][TCWinTest]::PostMessage($h,0x0200,[IntPtr]1,$moveParam);Start-Sleep -Milliseconds 100
[TCWinTest]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 450
$rDrag=Window-Rect $h;Record "real-drag" $h
Click-Client $h ([int]($rDrag.width/2)) 100 "left-click-detail-open" 650;$detail0=Window-Rect $h
if($detail0.height-le240){Start-Sleep -Milliseconds 250;Click-Client $h ([int]($detail0.width/2)) 100 "left-click-detail-open-retry" 650;$detail0=Window-Rect $h}
Capture "02-detail-session" $h
$forecastOffset=if($detail0.height-ge500){76}else{0}
Click-Client $h ([int]($detail0.width*0.75)) (274+$forecastOffset) "detail-group-model" 550;Capture "03-detail-model" $h
Click-Client $h ([int]($detail0.width*0.80)) (299+$forecastOffset) "detail-percentage" 550;Capture "04-detail-model-percent" $h
$beforeExpand=Window-Rect $h;Click-Client $h ([int]($beforeExpand.width/2)) (344+$forecastOffset) "detail-expand-first-row" 650;$afterExpand=Window-Rect $h;Capture "05-detail-expanded" $h;Sample "detail-expanded"
Click-Client $h ([int]($afterExpand.width/2)) 100 "left-click-detail-close" 450
if((Window-Rect $h).height-gt240){Start-Sleep -Milliseconds 250;Click-Client $h ([int]((Window-Rect $h).width/2)) 100 "left-click-detail-close-retry" 450}

$rr=Window-Rect $h;[void][TCWinTest]::SetForegroundWindow($h);[void][TCWinTest]::SetCursorPos($rr.left+[int]($rr.width/2),$rr.top+100)
[TCWinTest]::mouse_event(0x0008,0,0,0,[UIntPtr]::Zero);[TCWinTest]::mouse_event(0x0010,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 700;Capture-Screen "06-main-context-menu"
[TCWinTest]::keybd_event(0x1B,0,0,[UIntPtr]::Zero);[TCWinTest]::keybd_event(0x1B,0,2,[UIntPtr]::Zero);Start-Sleep -Milliseconds 350;Record "main-context-menu" $h

# All built-in faces plus custom, in exact WindowsClockTheme.allCases order.
$themes=@("glass","classic","glacier","midnight","luxe","gufeng","railgun","sky","custom")
for($i=0;$i-lt$themes.Count;$i++){Command $h (60+$i) ("theme-"+$themes[$i]) 450;Capture (("{0:D2}-" -f $i)+$themes[$i]) $h "$Out\themes"}

# Four macOS-normal sizes: transparent window width = dial + 80, height = dial when collapsed.
$sizes=@();foreach($s in @(@(20,"small",280,200),@(21,"medium",320,240),@(22,"large",380,300),@(23,"extraLarge",440,360))){Command $h $s[0] ("size-"+$s[1]) 350;$r=Window-Rect $h;$sizes+=[ordered]@{name=$s[1];width=$r.width;height=$r.height;passed=($r.width-eq$s[2]-and$r.height-eq$s[3])}}
Command $h 21 "size-restore-medium" 300

# Every stable menu command/subcommand and clipboard behavior.
foreach($i in 0..3){Command $h (150+$i) ("opacity-"+(25*($i+1))) 180}
$clipboardBefore="sentinel";[Windows.Forms.Clipboard]::SetText($clipboardBefore);Command $h 100 "api-copy" 250;$clipboardAfter=[Windows.Forms.Clipboard]::GetText()
$top0=(([TCWinTest]::GetWindowLong($h,-20)-band8)-ne0);Command $h 10 "topmost-toggle"; $top1=(([TCWinTest]::GetWindowLong($h,-20)-band8)-ne0);Command $h 10 "topmost-restore"
foreach($i in 0..1){Command $h (70+$i) ("temperature-"+$i) 250}
foreach($i in 0..6){Command $h (80+$i) ("city-"+$i) 260}
Start-Sleep -Seconds 4
Click-Client $h ([int]((Window-Rect $h).width/2)) 100 "weather-detail-open" 700;$weatherDetail=Window-Rect $h;Capture "06b-weather-forecast" $h
Click-Client $h ([int]($weatherDetail.width/2)) 100 "weather-detail-close" 450
foreach($i in 0..7){Command $h (90+$i) ("timezone-"+$i) 180}
foreach($i in 0..2){Command $h (30+$i) ("language-"+$i) 250}
Command $h 160 "refresh-full" 700;Sample "after-full-refresh"
$runKey="HKCU:\Software\Microsoft\Windows\CurrentVersion\Run";$run0=(Get-ItemProperty $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock
Command $h 40 "autostart-toggle" 250;$run1=(Get-ItemProperty $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock;Command $h 40 "autostart-restore" 250;$run2=(Get-ItemProperty $runKey -Name TokenClock -ErrorAction SilentlyContinue).TokenClock

# Settings: all controls, Cancel semantics, folder picker Cancel, auto-detect, live provider reload,
# API toggle/port, strict thresholds, and path expansion.
$d=Open-Settings $h $pidApp;Capture "07-settings" $d;Sample "settings-open" 1
$paths=@();$checks=@();$browse=@();for($i=0;$i-lt14;$i++){$paths+=Get-Text $d (200+$i);$checks+=Get-Check $d (300+$i);$browse+=([TCWinTest]::GetDlgItem($d,600+$i).ToInt64())}
$rate0=Get-Text $d 400;Set-Text $d 400 "77";Set-Text $d 200 "cancel-sentinel";Close-Dialog $d 2
$d=Open-Settings $h $pidApp;$cancelPassed=((Get-Text $d 400)-eq$rate0-and(Get-Text $d 200)-ne"cancel-sentinel")
[void][TCWinTest]::PostMessage($d,0x0111,[IntPtr]600,[IntPtr]::Zero);$picker=Wait-Dialog "#32770" $pidApp 5000
if($picker-ne[IntPtr]::Zero){[void][TCWinTest]::PostMessage($picker,0x0111,[IntPtr]2,[IntPtr]::Zero);for($i=0;$i-lt50-and[TCWinTest]::IsWindowVisible($picker);$i++){Start-Sleep -Milliseconds 100}}
[void][TCWinTest]::PostMessage($d,0x0111,[IntPtr]700,[IntPtr]::Zero);Start-Sleep -Milliseconds 1200;$detectLabel=Get-Text $d 700;$detectedOpenClaw=Get-Text $d 200
for($i=0;$i-lt14;$i++){Set-Check $d (300+$i) 0};Set-Check $d 309 1
$analytics="$Out\fixtures\analytics.jsonl";$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();('{"event":"message_send","time":'+$now+',"properties":{"prompt_tokens":1234,"completion_tokens":4321}}')|Set-Content -LiteralPath $analytics -Encoding ASCII
Set-Text $d 209 $analytics;Set-Text $d 400 "15";Set-Text $d 401 "100";Set-Text $d 402 "200";Set-Text $d 403 "300";Set-Text $d 404 "400"
Set-Check $d 411 0
$preSave=[ordered]@{aider=(Get-Text $d 209);rate=(Get-Text $d 400);burst=(Get-Text $d 401);hot=(Get-Text $d 402);active=(Get-Text $d 403);calm=(Get-Text $d 404);api=(Get-Check $d 411);enabled=@(for($i=0;$i-lt14;$i++){Get-Check $d (300+$i)})}
$preSave|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$Out\settings-before-save.json" -Encoding UTF8
Close-Dialog $d 1;Start-Sleep -Milliseconds 900
Copy-Item -LiteralPath "$Out\localappdata\TokenClock\settings.json" -Destination "$Out\settings-after-disable.json" -Force
$apiDisabled=($null-eq(Api 9988))
$d=Open-Settings $h $pidApp;$expandedAider=Get-Text $d 209;$savedRate=Get-Text $d 400;$thresholds=@((Get-Text $d 401),(Get-Text $d 402),(Get-Text $d 403),(Get-Text $d 404))
Set-Check $d 411 1;Set-Text $d 412 "19988";Close-Dialog $d 1;$newUsage=Wait-Api 19988 12000;Command $h 160 "refresh-after-path-save" 1000;$newUsage=Wait-Api 19988 5000
$aiderUsage=$null;if($newUsage){$aiderUsage=$newUsage.tools|Where-Object{$_.name-eq"Aider"}|Select-Object -First 1}
Sample "after-settings-save"
$d=Open-Settings $h $pidApp;Set-Text $d 412 "19989";Close-Dialog $d 1;$rebindUsage=Wait-Api 19989 8000;Sample "api-rebind-19989"
$d=Open-Settings $h $pidApp;Set-Text $d 412 "19988";Close-Dialog $d 1;$newUsage=Wait-Api 19988 8000;Sample "api-rebind-restored"

# Named custom face create/save/apply/delete and editor persistence.
$d=Open-Custom $h $pidApp;Capture "08-custom-editor" $d;Set-Text $d 540 "Smoke Face";Set-Text $d 530 "9.5";Set-Text $d 531 "7";Set-Check $d 550 1;[void][TCWinTest]::PostMessage($d,0x0111,[IntPtr]520,[IntPtr]::Zero);$handAfter=Get-Text $d 520;Close-Dialog $d 1;Start-Sleep -Milliseconds 500;Capture "09-custom-saved" $h
Command $h 200 "saved-theme-apply" 300;$d=Open-Custom $h $pidApp;$customName=Get-Text $d 540;$customRim=Get-Text $d 530;$customHour=Get-Text $d 531;Close-Dialog $d 2
[void][TCWinTest]::PostMessage($h,0x0111,[IntPtr]240,[IntPtr]::Zero);$deleteConfirm=Wait-Dialog "#32770" $pidApp 5000
if($deleteConfirm-ne[IntPtr]::Zero){[void][TCWinTest]::PostMessage($deleteConfirm,0x0111,[IntPtr]6,[IntPtr]::Zero);Start-Sleep -Milliseconds 350};Record "saved-theme-delete-confirmed" $h
Sample "after-custom-theme"

# About dialog, repeated API load, ordinary Quit and isolated-settings persistence restart.
[void][TCWinTest]::PostMessage($h,0x0111,[IntPtr]50,[IntPtr]::Zero);$about=Wait-Dialog "#32770" $pidApp 5000
if($about-ne[IntPtr]::Zero){Capture "10-about" $about;[void][TCWinTest]::PostMessage($about,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 300};Record "about" $h;Sample "before-api-load"
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
  windows=[ordered]@{version=[Environment]::OSVersion.VersionString;logicalProcessors=[Environment]::ProcessorCount;session=(Get-Process -Id $PID).SessionId}
  startup=[ordered]@{windowMs=$startupWindowMs;apiMs=$startupApiMs;apiReady=($null-ne$usage)}
  events=$events;failures=$failures;sizes=$sizes
  drag=[ordered]@{before=$r0;after=$rDrag;moved=($r0.left-ne$rDrag.left-or$r0.top-ne$rDrag.top)}
  details=[ordered]@{initial=$detail0;beforeExpand=$beforeExpand;afterExpand=$afterExpand;expandedHeightChanged=($beforeExpand.height-ne$afterExpand.height);weather=$weatherDetail;forecastVisible=($weatherDetail.height-ge500)}
  menu=[ordered]@{clipboard=$clipboardAfter;clipboardPassed=($clipboardAfter-match"/api/usage$");topmostBefore=$top0;topmostAfter=$top1;autostartBefore=$run0;autostartToggled=$run1;autostartRestored=$run2}
  settings=[ordered]@{allBrowseButtons=(($browse|Where-Object{$_-ne0}).Count-eq14);cancelPassed=$cancelPassed;folderPickerFound=($picker-ne[IntPtr]::Zero);detectLabel=$detectLabel;detectedOpenClaw=$detectedOpenClaw;apiDisabled=$apiDisabled;apiNewPort=($null-ne$newUsage);apiRebind=($null-ne$rebindUsage);aiderTokens=if($aiderUsage){$aiderUsage.todayTokens}else{$null};rate=$savedRate;thresholds=$thresholds;expandedAiderPath=$expandedAider}
  custom=[ordered]@{name=$customName;rim=$customRim;hourWidth=$customHour;hand=$handAfter;saved=($customName-eq"Smoke Face"-and$customRim-eq"9.5"-and$customHour-eq"7")}
  aboutFound=($about-ne[IntPtr]::Zero);deleteConfirmFound=($deleteConfirm-ne[IntPtr]::Zero);api100Ms=$api100Ms;historyPassed=($null-ne$apiHistory);quitPassed=$quitPassed
  restart=[ordered]@{rect=$restartRect;apiPortPersisted=($null-ne$restartApi)};metrics=$metrics;final=Is-Alive $h
}
$result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath "$Out\results.json" -Encoding UTF8
[void][TCWinTest]::PostMessage($h,0x0111,[IntPtr]1,[IntPtr]::Zero)
Stop-Transcript | Out-Null
