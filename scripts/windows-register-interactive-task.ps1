param(
    [Parameter(Mandatory = $true)][string]$TaskName,
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$ScriptArguments = '',
    [int]$ExecutionMinutes = 30
)

$ErrorActionPreference='Stop'
if(-not(Test-Path -LiteralPath $Script -PathType Leaf)){throw "Interactive task script not found: $Script"}
$pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
$arguments="-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Script`" $ScriptArguments"
$action=New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
# The task is started explicitly below. Keep the required one-shot trigger beyond the
# execution limit so it cannot collide with a long acceptance run and overwrite
# LastTaskResult with "an instance is already running" while that run is healthy.
$triggerDelayMinutes=[Math]::Max($ExecutionMinutes + 5, 10)
$trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes($triggerDelayMinutes))
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $ExecutionMinutes)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $TaskName
[ordered]@{taskName=$TaskName;execute=$pwsh;arguments=$arguments;state=(Get-ScheduledTask -TaskName $TaskName).State.ToString()}|ConvertTo-Json -Compress
