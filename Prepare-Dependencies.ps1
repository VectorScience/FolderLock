param([switch]$InstallWinFsp, [string]$RclonePath)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$tools = Join-Path $root 'build\tools'
[void][System.IO.Directory]::CreateDirectory($tools)
try {
    $target = $(if ($RclonePath) { $RclonePath } else { Join-Path $root 'rclone.exe' })
    if (-not (Test-Path -LiteralPath $target)) {
        $name = 'rclone-v1.75.2-windows-amd64.zip'
        $zip = Join-Path $tools $name
        Invoke-WebRequest -UseBasicParsing -Uri "https://downloads.rclone.org/v1.75.2/$name" -OutFile $zip
        $checks = (Invoke-WebRequest -UseBasicParsing -Uri 'https://downloads.rclone.org/v1.75.2/SHA256SUMS').Content
        $line = @($checks -split "`n" | Where-Object { $_.TrimEnd() -match (' ' + [regex]::Escape($name) + '$') })
        if ($line.Count -ne 1) { throw '官方校验清单中未找到唯一的 rclone 安装包。' }
        $expected = ($line[0] -split '\s+')[0]
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ine $expected) { throw 'rclone SHA256 校验失败。' }
        Expand-Archive -LiteralPath $zip -DestinationPath $tools -Force
        Copy-Item -LiteralPath (Join-Path $tools 'rclone-v1.75.2-windows-amd64\rclone.exe') -Destination $target
        Copy-Item -LiteralPath (Join-Path $tools 'rclone-v1.75.2-windows-amd64\README.txt') -Destination (Join-Path $root 'rclone-README.txt')
    }
    if ($InstallWinFsp) {
        $installer = Join-Path $tools 'winfsp-2.1.25156.msi'
        if (-not (Test-Path -LiteralPath $installer)) {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi' -OutFile $installer
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=NAVIMATICS LLC') { throw 'WinFsp 安装包签名校验失败。' }
        $process = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $installer + '"'), '/passive', '/norestart') -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -notin @(0, 3010)) { throw "WinFsp 安装失败，退出码：$($process.ExitCode)" }
    }
    if ($InstallWinFsp) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show('组件准备完成。请返回 FolderLock 重试；如系统提示重启，请先重启。', 'FolderLock')
    }
} catch {
    if ($InstallWinFsp) { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'FolderLock 组件准备失败') }
    throw
}
