param([string]$DownloaderRoot=(Join-Path (Split-Path $PSScriptRoot -Parent) 'OnlineVideoDownloader'),[string]$Ffmpeg='C:\Program Files\ffmpeg\bin\ffmpeg.exe')
# Compatibility entry: the staged import test now covers locked and unlocked destinations.
& (Join-Path $PSScriptRoot 'download-import-test.ps1') -DownloaderRoot $DownloaderRoot -Ffmpeg $Ffmpeg