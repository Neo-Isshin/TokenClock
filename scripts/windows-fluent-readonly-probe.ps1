param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string]$Out
)
$ErrorActionPreference='Stop'
Add-Type @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public static class TCFluentProbe {
 public delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")]public static extern bool EnumWindows(EnumProc c,IntPtr l);
 [DllImport("user32.dll")]public static extern bool EnumChildWindows(IntPtr h,EnumProc c,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern IntPtr GetProp(IntPtr h,string n);
 [DllImport("user32.dll")]public static extern uint GetSysColor(int i);
 public static IntPtr Find(string cls,uint pid){IntPtr f=IntPtr.Zero;EnumProc c=delegate(IntPtr h,IntPtr l){StringBuilder s=new StringBuilder(128);GetClassName(h,s,128);uint p;GetWindowThreadProcessId(h,out p);if(p==pid&&s.ToString()==cls&&IsWindowVisible(h)){f=h;return false;}return true;};EnumWindows(c,IntPtr.Zero);return f;}
 public static string Class(IntPtr h){StringBuilder s=new StringBuilder(128);GetClassName(h,s,128);return s.ToString();}
 public static IntPtr[] Children(IntPtr parent){List<IntPtr> values=new List<IntPtr>();EnumProc c=delegate(IntPtr h,IntPtr l){values.Add(h);return true;};EnumChildWindows(parent,c,IntPtr.Zero);return values.ToArray();}
}
'@
function Wait-Window([string]$Class,[uint32]$TargetPid){$h=[IntPtr]::Zero;for($i=0;$i-lt100-and$h-eq[IntPtr]::Zero;$i++){$h=[TCFluentProbe]::Find($Class,$TargetPid);if($h-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 100}};$h}
function Color([int]$Index){$c=[TCFluentProbe]::GetSysColor($Index);'{0:X2}{1:X2}{2:X2}'-f($c-band255),(($c-shr8)-band255),(($c-shr16)-band255)}
if(Test-Path $Out){Remove-Item $Out -Recurse -Force};New-Item -ItemType Directory -Path (Join-Path $Out 'localappdata\TokenClock'),(Join-Path $Out 'isolated-user\AppData\Roaming'),(Join-Path $Out 'isolated-user\AppData\Local'),(Join-Path $Out 'fixtures') -Force|Out-Null
[ordered]@{TC_language='en';TC_enabledTools=@('Aider');TC_hasRunInitialDetection=$true;TC_apiServerEnabled=$false;TC_alwaysOnTop=$true}|ConvertTo-Json|Set-Content (Join-Path $Out 'localappdata\TokenClock\settings.json') -Encoding UTF8
$theme=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
$result=[ordered]@{registry=[ordered]@{AppsUseLightTheme=$theme.AppsUseLightTheme;SystemUsesLightTheme=$theme.SystemUsesLightTheme;EnableTransparency=$theme.EnableTransparency};systemColors=[ordered]@{COLOR_WINDOW=Color 5;COLOR_WINDOWTEXT=Color 8;COLOR_BTNFACE=Color 15;COLOR_BTNTEXT=Color 18};settings=[ordered]@{};picker=[ordered]@{};errors=@()}
$p=$null
try{
 $env:LOCALAPPDATA=Join-Path $Out 'localappdata';$env:USERPROFILE=Join-Path $Out 'isolated-user';$env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming';$env:AIDER_ANALYTICS_LOG=Join-Path $Out 'fixtures\empty.jsonl';Set-Content $env:AIDER_ANALYTICS_LOG -Value '' -Encoding ASCII;$env:TC_WEATHER_MOCK='1';$p=Start-Process $Exe -WorkingDirectory (Split-Path $Exe) -PassThru;$main=Wait-Window 'TokenClock' ([uint32]$p.Id);if($main-eq[IntPtr]::Zero){$p.Refresh();throw "main missing; exited=$($p.HasExited) exitCode=$(if($p.HasExited){$p.ExitCode}else{-1})"}
 [void][TCFluentProbe]::PostMessage($main,0x0111,[IntPtr]120,[IntPtr]::Zero);$dialog=Wait-Window 'TCDialog' ([uint32]$p.Id);if($dialog-eq[IntPtr]::Zero){throw 'settings missing'}
 $children=@([TCFluentProbe]::Children($dialog)|ForEach-Object{[ordered]@{hwnd=$_.ToInt64();class=[TCFluentProbe]::Class($_);enabled=[TCFluentProbe]::IsWindowEnabled($_);visible=[TCFluentProbe]::IsWindowVisible($_)}})
 $result.settings=[ordered]@{dialogEnabled=[TCFluentProbe]::IsWindowEnabled($dialog);fluentRaw=[TCFluentProbe]::GetProp($dialog,'TokenClock.FluentApplied').ToInt64();saveEnabled=[TCFluentProbe]::IsWindowEnabled([TCFluentProbe]::GetDlgItem($dialog,1));cancelEnabled=[TCFluentProbe]::IsWindowEnabled([TCFluentProbe]::GetDlgItem($dialog,2));autoDetectEnabled=[TCFluentProbe]::IsWindowEnabled([TCFluentProbe]::GetDlgItem($dialog,700));childCount=$children.Count;disabledChildren=@($children|Where-Object{-not$_.enabled}).Count;children=$children}
 [void][TCFluentProbe]::PostMessage($dialog,0x0111,[IntPtr]2,[IntPtr]::Zero);Start-Sleep -Milliseconds 500
 [void][TCFluentProbe]::PostMessage($main,0x0111,[IntPtr]125,[IntPtr]::Zero);$picker=Wait-Window 'TCThemePicker' ([uint32]$p.Id);if($picker-eq[IntPtr]::Zero){throw 'picker missing'}
 $pickerChildren=@([TCFluentProbe]::Children($picker)|ForEach-Object{[ordered]@{class=[TCFluentProbe]::Class($_);enabled=[TCFluentProbe]::IsWindowEnabled($_);visible=[TCFluentProbe]::IsWindowVisible($_)}})
 $result.picker=[ordered]@{windowEnabled=[TCFluentProbe]::IsWindowEnabled($picker);fluentRaw=[TCFluentProbe]::GetProp($picker,'TokenClock.FluentApplied').ToInt64();childCount=$pickerChildren.Count;disabledChildren=@($pickerChildren|Where-Object{-not$_.enabled}).Count;children=$pickerChildren}
 [void][TCFluentProbe]::PostMessage($picker,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 300
}catch{$result.errors+=$_.Exception.ToString()}finally{if($p-and-not$p.HasExited){$main=[TCFluentProbe]::Find('TokenClock',[uint32]$p.Id);if($main-ne[IntPtr]::Zero){[void][TCFluentProbe]::PostMessage($main,0x0111,[IntPtr]1,[IntPtr]::Zero);Start-Sleep -Milliseconds 500};if(-not$p.HasExited){$p|Stop-Process -Force}};$result|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Out 'fluent-readonly-probe.json') -Encoding UTF8}
$result|ConvertTo-Json -Depth 8
