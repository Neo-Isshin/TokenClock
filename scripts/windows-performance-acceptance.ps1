param(
    [Parameter(Mandatory = $true)]
    [string]$Exe,
    [string]$Out = "$env:TEMP\TokenClockWindowsPerformance",
    [int]$Port = 20988,
    [ValidateRange(60, 86400)]
    [int]$SoakSeconds = 600,
    [ValidateRange(250, 5000)]
    [int]$SampleIntervalMs = 1000
)

$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TCPerfNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr h,string name);
  [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process,uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint data,UIntPtr extra);
  public static IntPtr FindByClassAndPid(string wanted,uint wantedPid) {
    IntPtr found=IntPtr.Zero;
    EnumProc cb=delegate(IntPtr h,IntPtr l) {
      StringBuilder c=new StringBuilder(128); GetClassName(h,c,128); uint p; GetWindowThreadProcessId(h,out p);
      if(c.ToString()==wanted && p==wantedPid && IsWindowVisible(h)){found=h;return false;} return true;
    }; EnumWindows(cb,IntPtr.Zero); return found;
  }
}
'@

function Wait-Window([string]$Class,[uint32]$TargetPid,[int]$Milliseconds=15000) {
    $h=[IntPtr]::Zero
    for($i=0;$i-lt[Math]::Ceiling($Milliseconds/100)-and$h-eq[IntPtr]::Zero;$i++){
        $h=[TCPerfNative]::FindByClassAndPid($Class,$TargetPid)
        if($h-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 100}
    }
    $h
}

function Window-Rect([IntPtr]$Handle) {
    $r=New-Object TCPerfNative+RECT;[void][TCPerfNative]::GetWindowRect($Handle,[ref]$r)
    [ordered]@{left=$r.L;top=$r.T;width=$r.R-$r.L;height=$r.B-$r.T}
}

function Click-Client([IntPtr]$Handle,[int]$X,[int]$Y) {
    $r=Window-Rect $Handle;[void][TCPerfNative]::SetForegroundWindow($Handle);[void][TCPerfNative]::SetCursorPos($r.left+$X,$r.top+$Y)
    [TCPerfNative]::mouse_event(2,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 70
    [TCPerfNative]::mouse_event(4,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 350
}

function Fluent-Material([IntPtr]$Handle) {
    $raw=[TCPerfNative]::GetProp($Handle,'TokenClock.FluentApplied').ToInt64()
    if($raw-gt0){[int]($raw-1)}else{-1}
}

function Get-ProcessGpuPercent([int]$TargetPid) {
    try {
        $counter=Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop
        $values=@($counter.CounterSamples | Where-Object { $_.InstanceName -like "pid_$($TargetPid)_*" } | ForEach-Object CookedValue)
        if($values.Count-eq0){return 0.0}
        return [Math]::Round(($values|Measure-Object -Sum).Sum,3)
    } catch { return $null }
}

$rawSamples=New-Object Collections.ArrayList
$logical=[Environment]::ProcessorCount
function Collect-Phase([Diagnostics.Process]$Process,[string]$Name,[double]$Seconds,[int]$GpuEvery=5) {
    $phase=New-Object Collections.ArrayList
    $lastCpu=$Process.TotalProcessorTime.TotalMilliseconds;$lastAt=Get-Date;$until=(Get-Date).AddSeconds($Seconds);$index=0
    do {
        Start-Sleep -Milliseconds $SampleIntervalMs
        if($Process.HasExited){throw "TokenClock exited during $Name"}
        $Process.Refresh();$now=Get-Date;$elapsed=($now-$lastAt).TotalMilliseconds;$cpuNow=$Process.TotalProcessorTime.TotalMilliseconds
        $coreCpu=if($elapsed-gt0){($cpuNow-$lastCpu)/$elapsed*100}else{0.0}
        $gpu=if(($index%$GpuEvery)-eq0){Get-ProcessGpuPercent $Process.Id}else{$null}
        $sample=[pscustomobject][ordered]@{
            phase=$Name;at=$now.ToString('o');coreCpuPercent=[Math]::Round($coreCpu,3);systemCpuPercent=[Math]::Round($coreCpu/$logical,4)
            workingSetMiB=[Math]::Round($Process.WorkingSet64/1MB,3);privateMiB=[Math]::Round($Process.PrivateMemorySize64/1MB,3)
            threads=$Process.Threads.Count;handles=$Process.HandleCount;gdiObjects=[TCPerfNative]::GetGuiResources($Process.Handle,0);userObjects=[TCPerfNative]::GetGuiResources($Process.Handle,1)
            processGpuPercent=$gpu;responding=$Process.Responding
        }
        [void]$phase.Add($sample);[void]$rawSamples.Add($sample)
        $lastCpu=$cpuNow;$lastAt=$now;$index++
    } while((Get-Date)-lt$until)
    $gpuValues=@($phase|Where-Object{$null-ne$_.processGpuPercent}|ForEach-Object processGpuPercent)
    [ordered]@{
        name=$Name;durationSeconds=$Seconds;samples=$phase.Count
        averageCoreCpuPercent=[Math]::Round(($phase|Measure-Object coreCpuPercent -Average).Average,3)
        peakCoreCpuPercent=[Math]::Round(($phase|Measure-Object coreCpuPercent -Maximum).Maximum,3)
        averageSystemCpuPercent=[Math]::Round(($phase|Measure-Object systemCpuPercent -Average).Average,4)
        startWorkingSetMiB=$phase[0].workingSetMiB;endWorkingSetMiB=$phase[-1].workingSetMiB;peakWorkingSetMiB=($phase|Measure-Object workingSetMiB -Maximum).Maximum
        startPrivateMiB=$phase[0].privateMiB;endPrivateMiB=$phase[-1].privateMiB;peakPrivateMiB=($phase|Measure-Object privateMiB -Maximum).Maximum
        startHandles=$phase[0].handles;endHandles=$phase[-1].handles;peakHandles=($phase|Measure-Object handles -Maximum).Maximum
        startGdiObjects=$phase[0].gdiObjects;endGdiObjects=$phase[-1].gdiObjects;peakGdiObjects=($phase|Measure-Object gdiObjects -Maximum).Maximum
        peakThreads=($phase|Measure-Object threads -Maximum).Maximum
        peakProcessGpuPercent=if($gpuValues.Count){[Math]::Round(($gpuValues|Measure-Object -Maximum).Maximum,3)}else{$null}
        allResponding=(@($phase|Where-Object{-not$_.responding}).Count-eq0)
    }
}

if(-not(Test-Path -LiteralPath $Exe -PathType Leaf)){throw "TokenClock executable not found: $Exe"}
if(Test-Path -LiteralPath $Out){Remove-Item -LiteralPath $Out -Recurse -Force}
New-Item -ItemType Directory -Path $Out,(Join-Path $Out 'localappdata\TokenClock') -Force|Out-Null

$aiderFixture=Join-Path $Out 'controlled-aider-analytics.jsonl';$fixtureNow=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();('{"event":"message_send","time":'+$fixtureNow+',"properties":{"prompt_tokens":1234,"completion_tokens":4321}}')|Set-Content -LiteralPath $aiderFixture -Encoding ASCII
$enabledProviders=@('Aider')
[ordered]@{
    TC_language='en';TC_clockSize='medium';TC_clockSizeUserChosen=$true;TC_selectedTheme='classic'
    TC_enabledTools=$enabledProviders;TC_alwaysOnTop=$true;TC_apiServerEnabled=$true;TC_apiServerPort=$Port
    TC_hasRunInitialDetection=$true;TC_selectedCity='Seattle';TC_aiderPath=$aiderFixture;TC_codeBuddyEndpoint='http://127.0.0.1:9'
}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $Out 'localappdata\TokenClock\settings.json') -Encoding UTF8

$result=[ordered]@{started=(Get-Date).ToString('o');environment=[ordered]@{};surfaces=[ordered]@{};phases=@();api=[ordered]@{};acceptance=[ordered]@{};errors=@()}
$process=$null
try {
    Get-Process TokenClock -ErrorAction SilentlyContinue|Stop-Process -Force
    $os=Get-CimInstance Win32_OperatingSystem;$cpu=Get-CimInstance Win32_Processor|Select-Object -First 1;$computer=Get-CimInstance Win32_ComputerSystem
    $exeItem=Get-Item -LiteralPath $Exe;$distBytes=(Get-ChildItem -LiteralPath (Split-Path $Exe) -File -Recurse|Measure-Object Length -Sum).Sum
    $result.environment=[ordered]@{
        os=$os.Caption;version=$os.Version;build=$os.BuildNumber;cpu=$cpu.Name;logicalProcessors=$logical;ramGiB=[Math]::Round($computer.TotalPhysicalMemory/1GB,1)
        session=(Get-Process -Id $PID).SessionId;sampleIntervalMs=$SampleIntervalMs;soakSeconds=$SoakSeconds
        executableMiB=[Math]::Round($exeItem.Length/1MB,2);distributionMiB=[Math]::Round($distBytes/1MB,2);gpuCounter='GPU Engine process instances; null means unavailable'
    }
    $env:LOCALAPPDATA=Join-Path $Out 'localappdata';$env:USERPROFILE=Join-Path $Out 'isolated-user';$env:APPDATA=Join-Path $env:USERPROFILE 'AppData\Roaming';New-Item -ItemType Directory -Path $env:APPDATA -Force|Out-Null
    $env:AIDER_ANALYTICS_LOG=$aiderFixture;$env:CODEBUDDY_STATS_ENDPOINT='http://127.0.0.1:9';$env:TC_MOCK='session';$env:TC_WEATHER_MOCK='1';$env:TC_FLUENT_REPORT='1'
    $startup=[Diagnostics.Stopwatch]::StartNew();$process=Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
    $main=[IntPtr]::Zero;$windowReadyMs=$null;$apiReadyMs=$null
    while($startup.Elapsed.TotalSeconds-lt15-and($null-eq$windowReadyMs-or$null-eq$apiReadyMs)){
        Start-Sleep -Milliseconds 100
        if($process.HasExited){throw 'TokenClock exited during cold start'}
        if($null-eq$windowReadyMs){$main=[TCPerfNative]::FindByClassAndPid('TokenClock',[uint32]$process.Id);if($main-ne[IntPtr]::Zero){$windowReadyMs=[Math]::Round($startup.Elapsed.TotalMilliseconds,1)}}
        if($null-eq$apiReadyMs){try{$null=Invoke-RestMethod "http://127.0.0.1:$Port/api/usage" -TimeoutSec 1;$apiReadyMs=[Math]::Round($startup.Elapsed.TotalMilliseconds,1)}catch{}}
    }
    if($main-eq[IntPtr]::Zero){$main=Wait-Window 'TokenClock' ([uint32]$process.Id) 3000}
    if($main-eq[IntPtr]::Zero){throw 'TokenClock main window did not become ready'}
    $result.startup=[ordered]@{windowReadyMs=$windowReadyMs;apiReadyMs=$apiReadyMs}
    $result.surfaces.main=[ordered]@{class='TokenClock';rect=Window-Rect $main;layeredDial=$true;fluentMaterial=Fluent-Material $main}
    $result.phases+=Collect-Phase $process 'cold-start-settle' 12 4
    $result.phases+=Collect-Phase $process 'stable-idle' 30 5

    Click-Client $main ([int]((Window-Rect $main).width/2)) 100;$detail=Wait-Window 'TokenClockDetail' ([uint32]$process.Id) 8000
    if($detail-eq[IntPtr]::Zero){throw 'TokenClockDetail did not open for performance test'}
    $result.surfaces.detail=[ordered]@{class='TokenClockDetail';rect=Window-Rect $detail;fluentMaterial=Fluent-Material $detail}
    $result.phases+=Collect-Phase $process 'detail-acrylic-open' 15 3
    Click-Client $detail 64 125
    $result.phases+=Collect-Phase $process 'codex-quota-panel' 15 3

    [void][TCPerfNative]::PostMessage($main,0x0111,[IntPtr]120,[IntPtr]::Zero);$settings=Wait-Window 'TCDialog' ([uint32]$process.Id) 8000
    if($settings-eq[IntPtr]::Zero){throw 'Settings did not open for performance test'}
    $result.surfaces.settings=[ordered]@{class='TCDialog';rect=Window-Rect $settings;fluentMaterial=Fluent-Material $settings}
    $result.phases+=Collect-Phase $process 'settings-mica-open' 10 2
    [void][TCPerfNative]::PostMessage($settings,0x0111,[IntPtr]2,[IntPtr]::Zero);Start-Sleep -Milliseconds 500

    [void][TCPerfNative]::PostMessage($main,0x0111,[IntPtr]125,[IntPtr]::Zero);$picker=Wait-Window 'TCThemePicker' ([uint32]$process.Id) 8000
    if($picker-eq[IntPtr]::Zero){throw 'Theme picker did not open for performance test'}
    $result.surfaces.themePicker=[ordered]@{class='TCThemePicker';rect=Window-Rect $picker;fluentMaterial=Fluent-Material $picker}
    $result.phases+=Collect-Phase $process 'theme-picker-acrylic-open' 10 2
    [void][TCPerfNative]::PostMessage($picker,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);Start-Sleep -Milliseconds 500

    [void][TCPerfNative]::PostMessage($main,0x0111,[IntPtr]160,[IntPtr]::Zero)
    $result.phases+=Collect-Phase $process 'manual-full-refresh' 20 4

    $apiBefore=$process.PrivateMemorySize64;$timer=[Diagnostics.Stopwatch]::StartNew();$requestFailures=0
    for($i=0;$i-lt250;$i++){
        try {
            $route=if(($i%2)-eq0){'usage'}else{'history?days=7&detail=sessions'}
            $null=Invoke-RestMethod "http://127.0.0.1:$Port/api/$route" -TimeoutSec 3
        } catch {$requestFailures++}
    }
    $timer.Stop();$process.Refresh()
    $result.api=[ordered]@{requests=250;failures=$requestFailures;elapsedMs=[Math]::Round($timer.Elapsed.TotalMilliseconds,1);requestsPerSecond=[Math]::Round(250/$timer.Elapsed.TotalSeconds,2);privateDeltaMiB=[Math]::Round(($process.PrivateMemorySize64-$apiBefore)/1MB,3)}
    $result.phases+=Collect-Phase $process 'api-burst-settle' 15 3

    if([TCPerfNative]::IsWindowVisible($detail)){Click-Client $main ([int]((Window-Rect $main).width/2)) 100}
    $soak=New-Object Collections.ArrayList;$lastCpu=$process.TotalProcessorTime.TotalMilliseconds;$lastAt=Get-Date
    for($second=1;$second-le$SoakSeconds;$second++){
        if(($second%5)-eq0){try{$null=Invoke-RestMethod "http://127.0.0.1:$Port/api/usage" -TimeoutSec 2}catch{}}
        Start-Sleep -Milliseconds $SampleIntervalMs
        if($process.HasExited){throw "TokenClock exited at sustained second $second"}
        $process.Refresh();$now=Get-Date;$elapsed=($now-$lastAt).TotalMilliseconds;$cpuNow=$process.TotalProcessorTime.TotalMilliseconds;$core=if($elapsed-gt0){($cpuNow-$lastCpu)/$elapsed*100}else{0}
        $gpu=if(($second%5)-eq0){Get-ProcessGpuPercent $process.Id}else{$null}
        $sample=[pscustomobject][ordered]@{phase='ten-minute-sustained';at=$now.ToString('o');coreCpuPercent=[Math]::Round($core,3);systemCpuPercent=[Math]::Round($core/$logical,4);workingSetMiB=[Math]::Round($process.WorkingSet64/1MB,3);privateMiB=[Math]::Round($process.PrivateMemorySize64/1MB,3);threads=$process.Threads.Count;handles=$process.HandleCount;gdiObjects=[TCPerfNative]::GetGuiResources($process.Handle,0);userObjects=[TCPerfNative]::GetGuiResources($process.Handle,1);processGpuPercent=$gpu;responding=$process.Responding;hung=[TCPerfNative]::IsHungAppWindow($main)}
        [void]$soak.Add($sample);[void]$rawSamples.Add($sample);$lastCpu=$cpuNow;$lastAt=$now
    }
    $gpuValues=@($soak|Where-Object{$null-ne$_.processGpuPercent}|ForEach-Object processGpuPercent)
    $soakSummary=[ordered]@{name='ten-minute-sustained';durationSeconds=$SoakSeconds;samples=$soak.Count;averageCoreCpuPercent=[Math]::Round(($soak|Measure-Object coreCpuPercent -Average).Average,3);peakCoreCpuPercent=[Math]::Round(($soak|Measure-Object coreCpuPercent -Maximum).Maximum,3);averageSystemCpuPercent=[Math]::Round(($soak|Measure-Object systemCpuPercent -Average).Average,4);startWorkingSetMiB=$soak[0].workingSetMiB;endWorkingSetMiB=$soak[-1].workingSetMiB;peakWorkingSetMiB=($soak|Measure-Object workingSetMiB -Maximum).Maximum;startPrivateMiB=$soak[0].privateMiB;endPrivateMiB=$soak[-1].privateMiB;peakPrivateMiB=($soak|Measure-Object privateMiB -Maximum).Maximum;startHandles=$soak[0].handles;endHandles=$soak[-1].handles;peakHandles=($soak|Measure-Object handles -Maximum).Maximum;startGdiObjects=$soak[0].gdiObjects;endGdiObjects=$soak[-1].gdiObjects;peakGdiObjects=($soak|Measure-Object gdiObjects -Maximum).Maximum;peakThreads=($soak|Measure-Object threads -Maximum).Maximum;peakProcessGpuPercent=if($gpuValues.Count){[Math]::Round(($gpuValues|Measure-Object -Maximum).Maximum,3)}else{$null};allResponding=(@($soak|Where-Object{-not$_.responding-or$_.hung}).Count-eq0)}
    $result.phases+=$soakSummary

    $idle=$result.phases|Where-Object name -eq 'stable-idle'|Select-Object -First 1
    $result.acceptance=[ordered]@{
        noCrashOrHang=$soakSummary.allResponding
        idleSystemCpuAtMostOnePercent=($idle.averageSystemCpuPercent-le1.0)
        sustainedSystemCpuAtMostOnePercent=($soakSummary.averageSystemCpuPercent-le1.0)
        workingSetGrowthAtMostTenMiB=(($soakSummary.endWorkingSetMiB-$soakSummary.startWorkingSetMiB)-le10)
        privateGrowthAtMostTenMiB=(($soakSummary.endPrivateMiB-$soakSummary.startPrivateMiB)-le10)
        handleGrowthAtMost64=(($soakSummary.endHandles-$soakSummary.startHandles)-le64)
        gdiGrowthAtMost32=(($soakSummary.endGdiObjects-$soakSummary.startGdiObjects)-le32)
        detailAcrylic=($result.surfaces.detail.fluentMaterial-eq2)
        settingsMica=($result.surfaces.settings.fluentMaterial-eq1)
        pickerAcrylic=($result.surfaces.themePicker.fluentMaterial-eq2)
        apiNoFailures=($requestFailures-eq0)
    }
    $result.status=if(@($result.acceptance.Values|Where-Object{$_-ne$true}).Count-eq0){'PASS'}else{'PARTIAL'}
} catch {
    $result.status='FAIL';$result.errors+=$_.Exception.ToString()
} finally {
    $result.completed=(Get-Date).ToString('o')
    $result.rawSampleCount=$rawSamples.Count
    $result|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Out 'performance-results.json') -Encoding UTF8
    $rawSamples|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $Out 'performance-samples.json') -Encoding UTF8
    if($process-and-not$process.HasExited){
        $main=[TCPerfNative]::FindByClassAndPid('TokenClock',[uint32]$process.Id)
        if($main-ne[IntPtr]::Zero){[void][TCPerfNative]::PostMessage($main,0x0111,[IntPtr]1,[IntPtr]::Zero);Start-Sleep -Milliseconds 700}
        if(-not$process.HasExited){$process|Stop-Process -Force}
    }
}

$result|ConvertTo-Json -Depth 12
