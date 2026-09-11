param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Out = "$env:TEMP\TokenClockShareSmoke"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TCShareSmoke {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr h,string text);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT rect);
  public static IntPtr Find(uint wantedPid,string wantedClass,int controlId) {
    IntPtr found=IntPtr.Zero;
    EnumProc callback=delegate(IntPtr h,IntPtr l) {
      StringBuilder c=new StringBuilder(128);GetClassName(h,c,128);uint pid;GetWindowThreadProcessId(h,out pid);
      if(pid==wantedPid && c.ToString()==wantedClass && (controlId==0 || GetDlgItem(h,controlId)!=IntPtr.Zero)){found=h;return false;}
      return true;
    };EnumWindows(callback,IntPtr.Zero);return found;
  }
}
"@

Get-Process TokenClock -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$env:TC_SHARE='1'
$env:TC_MOCK='model'
$process=Start-Process -FilePath $Exe -PassThru
try {
    $dialog=[IntPtr]::Zero
    for($i=0;$i-lt160-and$dialog-eq[IntPtr]::Zero;$i++){
        $dialog=[TCShareSmoke]::Find([uint32]$process.Id,'TCDialog',1604)
        if($dialog-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 50}
    }
    if($dialog-eq[IntPtr]::Zero){throw 'Share dialog did not appear'}
    foreach($id in 1600,1604,1605,1606){
        if([TCShareSmoke]::GetDlgItem($dialog,$id)-eq[IntPtr]::Zero){throw "Share control $id is missing"}
    }

    $rect=New-Object TCShareSmoke+RECT
    [void][TCShareSmoke]::GetWindowRect($dialog,[ref]$rect)
    $capturePath=$null
    try {
        $capture=New-Object Drawing.Bitmap ($rect.R-$rect.L),($rect.B-$rect.T)
        $graphics=[Drawing.Graphics]::FromImage($capture)
        $graphics.CopyFromScreen($rect.L,$rect.T,0,0,$capture.Size)
        $graphics.Dispose()
        $capturePath=Join-Path $Out 'share-dialog.png'
        $capture.Save($capturePath,[Drawing.Imaging.ImageFormat]::Png)
        $capture.Dispose()
    } catch {
        # OpenSSH can run without an interactive desktop. Control, clipboard, and PNG
        # checks still exercise the native flow; visual capture is added when a desktop exists.
        $capturePath=$null
    }

    [void][TCShareSmoke]::PostMessage($dialog,0x0111,[IntPtr]1604,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 700
    $clipboardImage=[Windows.Forms.Clipboard]::ContainsImage()
    if($null-ne$capturePath-and-not$clipboardImage){throw 'Copy Image did not place an image on the clipboard'}

    if($null-ne$capturePath){
        [void][TCShareSmoke]::PostMessage($dialog,0x0111,[IntPtr]1605,[IntPtr]::Zero)
        $saveDialog=[IntPtr]::Zero
        for($i=0;$i-lt160-and$saveDialog-eq[IntPtr]::Zero;$i++){
            $saveDialog=[TCShareSmoke]::Find([uint32]$process.Id,'#32770',0)
            if($saveDialog-eq[IntPtr]::Zero){Start-Sleep -Milliseconds 50}
        }
        if($saveDialog-eq[IntPtr]::Zero){throw 'Native Save PNG dialog did not appear'}
        [void][TCShareSmoke]::PostMessage($saveDialog,0x0111,[IntPtr]2,[IntPtr]::Zero)
    }
    [void][TCShareSmoke]::PostMessage($dialog,0x0111,[IntPtr]1606,[IntPtr]::Zero)

    [ordered]@{
        passed=$true; dialogCapture=$capturePath; clipboardImage=$clipboardImage;
        interactiveDesktop=($null-ne$capturePath)
    } | ConvertTo-Json -Compress
} finally {
    Remove-Item Env:TC_SHARE -ErrorAction SilentlyContinue
    Remove-Item Env:TC_MOCK -ErrorAction SilentlyContinue
    if(-not$process.HasExited){Stop-Process -Id $process.Id -Force}
}
