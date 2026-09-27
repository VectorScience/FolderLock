param(
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $root 'build'
$dist = Join-Path $root 'dist'
$packages = Join-Path $root 'packages'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) { throw '找不到 .NET Framework C# 编译器。' }
foreach ($directory in @($build, $dist, $packages)) {
    [void](New-Item -ItemType Directory -Path $directory -Force)
}

# Draw a compact icon and wrap its PNG bytes in the ICO container format.
$bitmap = New-Object System.Drawing.Bitmap(64, 64)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $blue = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(35, 91, 202))
    $dark = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(25, 62, 145), 7)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    try {
        $graphics.DrawArc($dark, 17, 7, 30, 35, 180, 180)
        $graphics.FillRectangle($blue, 10, 29, 44, 30)
        $graphics.FillEllipse($white, 29, 39, 6, 6)
        $graphics.FillRectangle($white, 31, 43, 2, 8)
    } finally { $blue.Dispose(); $dark.Dispose(); $white.Dispose() }
    $pngStream = New-Object System.IO.MemoryStream
    try {
        $bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $pngStream.ToArray()
    } finally { $pngStream.Dispose() }
} finally { $graphics.Dispose(); $bitmap.Dispose() }

$icon = Join-Path $build 'FolderLock.ico'
$iconStream = [System.IO.File]::Create($icon)
$writer = New-Object System.IO.BinaryWriter($iconStream)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
    $writer.Write([byte]64); $writer.Write([byte]64); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$png.Length); $writer.Write([uint32]22)
    $writer.Write($png)
} finally { $writer.Dispose() }

$script = Join-Path $root 'FolderLock.ps1'
$launcher = Join-Path $root 'Launcher.cs'
$executable = Join-Path $dist 'FolderLock.exe'
$arguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/out:$executable", "/win32icon:$icon",
    "/resource:$script,FolderLock.ps1", "/resource:$icon,FolderLock.ico",
    '/reference:System.Windows.Forms.dll', $launcher
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $executable)) {
    throw '编译 FolderLock.exe 失败。'
}

$archive = Join-Path $packages ("FolderLock-$Version-Windows.zip")
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
Compress-Archive -LiteralPath @($executable, (Join-Path $root 'README.md')) -DestinationPath $archive
Write-Host "EXE: $executable"
Write-Host "ZIP: $archive"
