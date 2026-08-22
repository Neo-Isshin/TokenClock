param(
    [Parameter(Mandatory = $true)]
    [string]$Exe,
    [string]$Out = "$env:TEMP\TokenClockCodeBuddySmoke",
    [int]$TokenClockPort = 21988,
    [int]$CodeBuddyPort = 18080,
    [int]$EnabledSampleSeconds = 120,
    [int]$DisabledSampleSeconds = 60
)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TCCBWin {
  public delegate bool EnumProc(IntPtr h,IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint data,UIntPtr e);
  public static IntPtr Find(string cls,uint pid) {
    IntPtr found=IntPtr.Zero;EnumProc cb=delegate(IntPtr h,IntPtr l){StringBuilder s=new StringBuilder(128);GetClassName(h,s,128);uint p;GetWindowThreadProcessId(h,out p);if(p==pid&&s.ToString()==cls&&IsWindowVisible(h)){found=h;return false;}return true;};EnumWindows(cb,IntPtr.Zero);return found;
  }
}
'@

function Wait-Window([string]$Class,[uint32]$TargetPid,[int]$Milliseconds=15000){$h=[IntPtr]::Zero;for($i=0;$i-lt[Math]::Ceiling($Milliseconds/100)-and$h-eq[IntPtr]::Zero;$i++){$h=[TCCBWin]::Find($Class,$TargetPid);if($h-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 100}};$h}
function Rect([IntPtr]$Handle){$r=New-Object TCCBWin+RECT;[void][TCCBWin]::GetWindowRect($Handle,[ref]$r);[ordered]@{left=$r.L;top=$r.T;width=$r.R-$r.L;height=$r.B-$r.T}}
function Click([IntPtr]$Handle,[int]$X,[int]$Y){$r=Rect $Handle;[void][TCCBWin]::SetForegroundWindow($Handle);[void][TCCBWin]::SetCursorPos($r.left+$X,$r.top+$Y);[TCCBWin]::mouse_event(2,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 70;[TCCBWin]::mouse_event(4,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 400}

function Write-IsolatedSettings([bool]$CodeBuddyEnabled){
    $enabled=@('Aider');if($CodeBuddyEnabled){$enabled+='CodeBuddy CLI'}
    [ordered]@{TC_language='en';TC_clockSize='medium';TC_clockSizeUserChosen=$true;TC_selectedTheme='classic';TC_enabledTools=$enabled;TC_apiServerEnabled=$true;TC_apiServerPort=$TokenClockPort;TC_hasRunInitialDetection=$true;TC_selectedCity='Seattle';TC_aiderPath=$script:aiderFixture;TC_codeBuddyEndpoint="http://127.0.0.1:$CodeBuddyPort"}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
}

function Wait-Usage([int]$Milliseconds=15000){$value=$null;$until=(Get-Date).AddMilliseconds($Milliseconds);do{try{$value=Invoke-RestMethod "http://127.0.0.1:$TokenClockPort/api/usage" -TimeoutSec 2}catch{Start-Sleep -Milliseconds 150}}while($null-eq$value-and(Get-Date)-lt$until);$value}

function Start-IsolatedTokenClock([bool]$CodeBuddyEnabled){
    Write-IsolatedSettings $CodeBuddyEnabled
    $env:LOCALAPPDATA=$script:localAppData;$env:TC_WEATHER_MOCK='1';Remove-Item Env:TC_MOCK -ErrorAction SilentlyContinue
    $p=Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
    $main=Wait-Window 'TokenClock' ([uint32]$p.Id) 15000;if($main-eq[IntPtr]::Zero){throw 'TokenClock window did not start'}
    $usage=Wait-Usage 15000;if($null-eq$usage){throw 'TokenClock API did not start'}
    [void][TCCBWin]::PostMessage($main,0x0111,[IntPtr]160,[IntPtr]::Zero);Start-Sleep -Milliseconds 1800
    [ordered]@{process=$p;main=$main;usage=(Wait-Usage 5000)}
}

function Stop-IsolatedTokenClock($Run){
    if($null-eq$Run){return};$p=$Run.process
    if(-not$p.HasExited){[void][TCCBWin]::PostMessage($Run.main,0x0111,[IntPtr]1,[IntPtr]::Zero);Start-Sleep -Milliseconds 800}
    if(-not$p.HasExited){$p|Stop-Process -Force}
    for($i=0;$i-lt50-and(Get-NetTCPConnection -LocalPort $TokenClockPort -State Listen -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 100}
}

function Sample-Run($Run,[string]$Name,[int]$Seconds){
    $p=$Run.process;$samples=New-Object Collections.ArrayList;$lastCpu=$p.TotalProcessorTime.TotalMilliseconds;$lastAt=Get-Date
    for($i=1;$i-le$Seconds;$i++){
        if(($i%30)-eq0){[void][TCCBWin]::PostMessage($Run.main,0x0111,[IntPtr]160,[IntPtr]::Zero)}
        Start-Sleep -Seconds 1;if($p.HasExited){throw "TokenClock exited during $Name"};$p.Refresh();$now=Get-Date;$elapsed=($now-$lastAt).TotalMilliseconds;$cpu=$p.TotalProcessorTime.TotalMilliseconds
        [void]$samples.Add([pscustomobject]@{at=$now.ToString('o');coreCpuPercent=if($elapsed-gt0){[Math]::Round(($cpu-$lastCpu)/$elapsed*100,3)}else{0};workingSetMiB=[Math]::Round($p.WorkingSet64/1MB,3);privateMiB=[Math]::Round($p.PrivateMemorySize64/1MB,3);handles=$p.HandleCount;threads=$p.Threads.Count;responding=$p.Responding})
        $lastCpu=$cpu;$lastAt=$now
    }
    [ordered]@{name=$Name;seconds=$Seconds;averageCoreCpuPercent=[Math]::Round(($samples|Measure-Object coreCpuPercent -Average).Average,3);peakCoreCpuPercent=($samples|Measure-Object coreCpuPercent -Maximum).Maximum;startWorkingSetMiB=$samples[0].workingSetMiB;endWorkingSetMiB=$samples[-1].workingSetMiB;peakWorkingSetMiB=($samples|Measure-Object workingSetMiB -Maximum).Maximum;startPrivateMiB=$samples[0].privateMiB;endPrivateMiB=$samples[-1].privateMiB;peakPrivateMiB=($samples|Measure-Object privateMiB -Maximum).Maximum;startHandles=$samples[0].handles;endHandles=$samples[-1].handles;peakHandles=($samples|Measure-Object handles -Maximum).Maximum;peakThreads=($samples|Measure-Object threads -Maximum).Maximum;allResponding=(@($samples|Where-Object{-not$_.responding}).Count-eq0);samples=$samples}
}

function Capture-PercentDetail($Run){
    $mainRect=Rect $Run.main;Click $Run.main ([int]($mainRect.width/2)) 100;$detail=Wait-Window 'TokenClockDetail' ([uint32]$Run.process.Id) 8000
    if($detail-eq[IntPtr]::Zero){return $null};Click $detail 256 125;$r=Rect $detail;$bitmap=New-Object Drawing.Bitmap $r.width,$r.height;$graphics=[Drawing.Graphics]::FromImage($bitmap);$graphics.CopyFromScreen($r.left,$r.top,0,0,$bitmap.Size);$graphics.Dispose();$path=Join-Path $Out 'codebuddy-by-percent.png';$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose();Click $Run.main ([int]($mainRect.width/2)) 100;$path
}

function Descendant-Pids([int]$RootPid){$seen=New-Object Collections.Generic.HashSet[int];$queue=New-Object Collections.Queue;$queue.Enqueue($RootPid);while($queue.Count){$parent=[int]$queue.Dequeue();foreach($child in Get-CimInstance Win32_Process -Filter "ParentProcessId=$parent" -ErrorAction SilentlyContinue){if($seen.Add([int]$child.ProcessId)){$queue.Enqueue([int]$child.ProcessId)}}};@($seen)}

if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){throw "TokenClock executable missing: $Exe"}
if(Get-NetTCPConnection -LocalPort $CodeBuddyPort -State Listen -ErrorAction SilentlyContinue){throw "Port $CodeBuddyPort is already in use; refusing to touch an existing service."}
if(Get-Process TokenClock -ErrorAction SilentlyContinue){throw 'TokenClock is already running; close it before isolated CodeBuddy acceptance.'}
if(Test-Path -LiteralPath $Out){Remove-Item -LiteralPath $Out -Recurse -Force}
$script:localAppData=Join-Path $Out 'localappdata';$tokenClockData=Join-Path $script:localAppData 'TokenClock';New-Item -ItemType Directory -Path $tokenClockData,(Join-Path $Out 'fixtures'),(Join-Path $Out 'codebuddy') -Force|Out-Null
$script:settingsPath=Join-Path $tokenClockData 'settings.json';$script:aiderFixture=Join-Path $Out 'fixtures\aider-analytics.jsonl';$now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();('{"event":"message_send","time":'+$now+',"properties":{"prompt_tokens":1234,"completion_tokens":4321}}')|Set-Content -LiteralPath $script:aiderFixture -Encoding ASCII

$result=[ordered]@{started=(Get-Date).ToString('o');codeBuddy=[ordered]@{};disabledBaseline=[ordered]@{};enabled=[ordered]@{};restored=[ordered]@{};checks=[ordered]@{};errors=@()}
$codeBuddyLauncher=$null;$ownedServerPid=$null;$run=$null
try{
    $command=Get-Command codebuddy.cmd -ErrorAction Stop
    $stdout=Join-Path $Out 'codebuddy\stdout.log';$stderr=Join-Path $Out 'codebuddy\stderr.log'
    $arguments=@('--serve','--host','127.0.0.1','--port',"$CodeBuddyPort",'--no-session-persistence','--session-id','tokenclock-final-smoke')
    $codeBuddyLauncher=Start-Process -FilePath $command.Source -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $until=(Get-Date).AddSeconds(25);do{$listener=Get-NetTCPConnection -LocalPort $CodeBuddyPort -State Listen -ErrorAction SilentlyContinue|Select-Object -First 1;if($null-eq$listener){Start-Sleep -Milliseconds 200}}while($null-eq$listener-and(Get-Date)-lt$until)
    if($null-eq$listener){throw 'Official CodeBuddy local server did not listen on 127.0.0.1:18080'}
    if($listener.LocalAddress-notin@('127.0.0.1','::1')){throw "CodeBuddy listener escaped loopback: $($listener.LocalAddress)"}
    $ownedServerPid=[int]$listener.OwningProcess
    $headers=@{'X-CodeBuddy-Request'='1'};$sessionContract=Invoke-RestMethod "http://127.0.0.1:$CodeBuddyPort/api/v1/stats/session" -Headers $headers -TimeoutSec 5
    $result.codeBuddy=[ordered]@{command=$command.Source;arguments=$arguments;launcherPid=$codeBuddyLauncher.Id;listenerPid=$ownedServerPid;localAddress=$listener.LocalAddress;sessionContractReturned=($null-ne$sessionContract)}

    $run=Start-IsolatedTokenClock $false;$baselineUsage=$run.usage;$baselineHistory=Invoke-RestMethod "http://127.0.0.1:$TokenClockPort/api/history?days=1&detail=sessions" -TimeoutSec 3;$baselinePerf=Sample-Run $run 'codebuddy-disabled-baseline' $DisabledSampleSeconds
    $result.disabledBaseline=[ordered]@{totalTokens=$baselineUsage.totalTokens;historyTotalTokens=$baselineHistory.days[0].totalTokens;performance=$baselinePerf};Stop-IsolatedTokenClock $run;$run=$null

    $run=Start-IsolatedTokenClock $true;$enabledUsage=$run.usage;$enabledHistory=Invoke-RestMethod "http://127.0.0.1:$TokenClockPort/api/history?days=1&detail=sessions" -TimeoutSec 3;$tool=$enabledUsage.tools|Where-Object name -eq 'CodeBuddy CLI'|Select-Object -First 1;$percentScreenshot=Capture-PercentDetail $run;$enabledPerf=Sample-Run $run 'codebuddy-enabled-idle-and-scan' $EnabledSampleSeconds
    $result.enabled=[ordered]@{totalTokens=$enabledUsage.totalTokens;historyTotalTokens=$enabledHistory.days[0].totalTokens;tool=$tool;percentScreenshot=$percentScreenshot;performance=$enabledPerf};Stop-IsolatedTokenClock $run;$run=$null

    $run=Start-IsolatedTokenClock $false;$restoredUsage=$run.usage;$restoredPerf=Sample-Run $run 'codebuddy-disabled-restored' $DisabledSampleSeconds
    $result.restored=[ordered]@{totalTokens=$restoredUsage.totalTokens;performance=$restoredPerf};Stop-IsolatedTokenClock $run;$run=$null

    $historyToolNames=@($enabledHistory.days[0].tools|ForEach-Object name)
    $result.checks=[ordered]@{
        codeBuddyPresent=($null-ne$tool);scopeCurrentSession=($tool.scope-eq'currentSession');unitTokens=($tool.unit-eq'tokens');statisticsAvailable=($tool.statisticsAvailable-eq$true);valueZero=($tool.value-eq0)
        totalTokensUnchanged=($enabledUsage.totalTokens-eq$baselineUsage.totalTokens);historyTotalUnchanged=($enabledHistory.days[0].totalTokens-eq$baselineHistory.days[0].totalTokens);codeBuddyExcludedFromHistory=('CodeBuddy CLI'-notin$historyToolNames)
        percentScreenshotCreated=($null-ne$percentScreenshot-and(Test-Path -LiteralPath $percentScreenshot));enabledResponsive=$enabledPerf.allResponding;restoredResponsive=$restoredPerf.allResponding
        handleDeltaEnabledVsBaseline=($enabledPerf.endHandles-$baselinePerf.endHandles);workingSetDeltaEnabledVsBaselineMiB=[Math]::Round($enabledPerf.endWorkingSetMiB-$baselinePerf.endWorkingSetMiB,3);privateDeltaEnabledVsBaselineMiB=[Math]::Round($enabledPerf.endPrivateMiB-$baselinePerf.endPrivateMiB,3)
        handleRestoredNearBaseline=([Math]::Abs($restoredPerf.endHandles-$baselinePerf.endHandles)-le32);workingSetRestoredNearBaseline=([Math]::Abs($restoredPerf.endWorkingSetMiB-$baselinePerf.endWorkingSetMiB)-le10)
    }
    $booleanChecks=@('codeBuddyPresent','scopeCurrentSession','unitTokens','statisticsAvailable','valueZero','totalTokensUnchanged','historyTotalUnchanged','codeBuddyExcludedFromHistory','percentScreenshotCreated','enabledResponsive','restoredResponsive','handleRestoredNearBaseline','workingSetRestoredNearBaseline')
    $result.status=if(@($booleanChecks|Where-Object{$result.checks[$_]-ne$true}).Count-eq0){'PASS'}else{'PARTIAL'}
}catch{$result.status='FAIL';$result.errors+=$_.Exception.ToString()}
finally{
    if($run){Stop-IsolatedTokenClock $run}
    if($ownedServerPid){
        $pids=@(Descendant-Pids $ownedServerPid)+@($ownedServerPid)|Select-Object -Unique
        foreach($pidToStop in ($pids|Sort-Object -Descending)){Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue}
    }
    if($codeBuddyLauncher-and-not$codeBuddyLauncher.HasExited){Stop-Process -Id $codeBuddyLauncher.Id -Force -ErrorAction SilentlyContinue}
    for($i=0;$i-lt50-and(Get-NetTCPConnection -LocalPort $CodeBuddyPort -State Listen -ErrorAction SilentlyContinue);$i++){Start-Sleep -Milliseconds 100}
    $result.codeBuddy.portClosedAfterTest=(-not[bool](Get-NetTCPConnection -LocalPort $CodeBuddyPort -State Listen -ErrorAction SilentlyContinue))
    $result.completed=(Get-Date).ToString('o');$result|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $Out 'codebuddy-results.json') -Encoding UTF8
}

$result|ConvertTo-Json -Depth 14
