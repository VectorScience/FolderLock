param(
    [string]$Version = '2.4.2'
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

& (Join-Path $root 'Build-Icons.ps1') -OutputDirectory $build
$icon = Join-Path $build 'FolderLock.ico'
Copy-Item -LiteralPath $icon -Destination (Join-Path $dist 'FolderLock-brand-v1.ico') -Force

$script = Join-Path $root 'FolderLock.ps1'
$engine = Join-Path $root 'VaultEngine.cs'
$legacy = Join-Path $root 'Legacy-FolderLock.ps1'
$dependencies = Join-Path $root 'Prepare-Dependencies.ps1'
$rclone = Join-Path $root 'rclone.exe'
if (-not (Test-Path -LiteralPath $rclone)) { $rclone = Join-Path $build 'tools\rclone.exe' }
if (-not (Test-Path -LiteralPath $rclone)) { throw '请先运行 Prepare-Dependencies.ps1 下载校验 rclone。' }
Copy-Item -LiteralPath $rclone -Destination (Join-Path $dist 'rclone.exe') -Force
$license = Join-Path $root 'rclone-README.txt'
if (-not (Test-Path -LiteralPath $license)) { $license = Join-Path $build 'tools\rclone-v1.75.2-windows-amd64\README.txt' }
Copy-Item -LiteralPath $license -Destination (Join-Path $dist 'rclone-README.txt') -Force
$launcher = Join-Path $root 'Launcher.cs'
$executable = Join-Path $dist 'FolderLock.exe'
$arguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/out:$executable", "/win32icon:$icon",
    "/resource:$script,FolderLock.ps1", "/resource:$icon,FolderLock.ico",
    "/resource:$engine,VaultEngine.cs", "/resource:$legacy,Legacy-FolderLock.ps1", "/resource:$dependencies,Prepare-Dependencies.ps1",
    '/reference:System.Windows.Forms.dll', $launcher
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $executable)) {
    throw '编译 FolderLock.exe 失败。'
}

$archive = Join-Path $packages ("FolderLock-$Version-Windows.zip")
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
Compress-Archive -LiteralPath @($executable, (Join-Path $dist 'rclone.exe'), (Join-Path $dist 'rclone-README.txt'), (Join-Path $root 'README.md'), (Join-Path $dist 'FolderLock-brand-v1.ico'), (Join-Path $root 'Export-DownloadOrigins.ps1')) -DestinationPath $archive
Write-Host "EXE: $executable"
Write-Host "ZIP: $archive"
