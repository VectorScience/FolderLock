$ErrorActionPreference = 'Stop'
$source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FolderLock.ps1'))
$source = $source.Replace("`$script:DataDir = Join-Path `$env:LOCALAPPDATA 'FolderLock'", "`$script:DataDir = Join-Path `$PSScriptRoot '.test-launch'")
$source = $source.Replace('if (-not (Ensure-GlobalConfig))', "Initialize-GlobalConfig 'password123'; if (-not (Ensure-GlobalConfig))")
$source = $source.Replace('[void]$form.ShowDialog()', "'READY'")
$source = $source.Replace("[void][System.Windows.Forms.MessageBox]::Show(`$message, 'FolderLock', 'OK', 'Error')", 'Write-Error $message')
$scriptPath = Join-Path $PSScriptRoot '.test-launch-script.ps1'
try {
    [System.IO.File]::WriteAllText($scriptPath, $source, [System.Text.UTF8Encoding]::new($true))
    & $scriptPath
}
finally {
    $target = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.test-launch'))
    $root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
}
