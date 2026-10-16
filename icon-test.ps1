$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ShellIconDecoder {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr LoadImage(IntPtr instance,string name,uint type,int width,int height,uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
}
'@
$icon=Join-Path $PSScriptRoot 'build\FolderLock.ico'
$bytes=[IO.File]::ReadAllBytes($icon)
$expected=@(16,20,24,32,40,48,64,96,128,256)
if([BitConverter]::ToUInt16($bytes,2) -ne 1 -or [BitConverter]::ToUInt16($bytes,4) -ne $expected.Count){throw 'ICO directory invalid'}
for($i=0;$i -lt $expected.Count;$i++) {
    $offset=6+16*$i;$size=$expected[$i]
    $dimension=[int]$bytes[$offset];if($dimension -eq 0){$dimension=256}
    $length=[BitConverter]::ToUInt32($bytes,$offset+8);$start=[BitConverter]::ToUInt32($bytes,$offset+12)
    if($dimension -ne $size -or $start+$length -gt $bytes.Length){throw 'ICO frame missing or out of bounds'}
    $handle=[ShellIconDecoder]::LoadImage([IntPtr]::Zero,$icon,1,$size,$size,16)
    if($handle -eq [IntPtr]::Zero){throw 'Windows could not load icon frame'}
    $frame=[Drawing.Icon]::FromHandle($handle)
    try {
        if($frame.Width -ne $size -or $frame.Height -ne $size){throw 'Windows icon decoder selected wrong frame'}
        $bitmap=$frame.ToBitmap()
        try {
            $coloured=0;$mint=0
            for($y=0;$y -lt $size;$y++){for($x=0;$x -lt $size;$x++){$c=$bitmap.GetPixel($x,$y);if($c.A -gt 200){$coloured++;if($c.R -gt 125 -and $c.G -gt 200 -and $c.B -gt 150){$mint++}}}}
            if($coloured -lt $size*$size*0.25 -or $mint -eq 0 -or $bitmap.GetPixel(0,0).A -ne 0){throw 'Icon artwork or alpha missing'}
        } finally {$bitmap.Dispose()}
    } finally {$frame.Dispose();[void][ShellIconDecoder]::DestroyIcon($handle)}
}
$exe=Join-Path $PSScriptRoot 'dist\FolderLock.exe'
$assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe));$stream=$assembly.GetManifestResourceStream('FolderLock.ico')
try {
    $sha=[Security.Cryptography.SHA256]::Create()
    if([BitConverter]::ToString($sha.ComputeHash($stream)) -cne [BitConverter]::ToString($sha.ComputeHash($bytes))){throw 'Embedded app icon is stale'}
} finally {$stream.Dispose()}
$shell=[Drawing.Icon]::ExtractAssociatedIcon($exe)
try {if($null -eq $shell){throw 'Executable shell icon missing'}} finally {if($shell){$shell.Dispose()}}
if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'dist\FolderLock-brand-v1.ico')).Hash -ne (Get-FileHash -LiteralPath $icon).Hash){throw 'External menu icon differs from app icon'}
'PASS: Windows decodes all ten transparent icon sizes; executable, app resource and menu asset are consistent'
