$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FolderLock.ps1'))
$source = $source.Replace('Local\FolderLock2UI-','Local\FolderLock2UITest-')
$source = $source.Replace('Enable-ContextMenu;','$null = 0;')
$source = $source.Replace("`$script:historyFile = Join-Path `$env:LOCALAPPDATA 'FolderLock\vaults.json'", "`$script:historyFile = Join-Path `$PSScriptRoot '.test-no-history.json'")
$source = $source.Replace('[void]$form.ShowDialog()', @'
    if ($pathBox.AccessibleName -ne '粘贴文件夹完整路径') { throw 'Path input missing' }
    if ($encrypt.Text -ne '加密 / 继续加密' -or $unlock.Text -notmatch '可读写') { throw 'Primary actions missing' }
    if($drive.SelectedItem -ne '原路径'){throw 'Original path is not the default'}
    if(-not $form.Icon -or $form.Icon.Width -ne 32){throw 'Custom application icon missing'}
    $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-12000, -12000)
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    $image = New-Object Drawing.Bitmap($form.Width, $form.Height)
    try { $form.DrawToBitmap($image, [Drawing.Rectangle]::new(0, 0, $form.Width, $form.Height)); $image.Save((Join-Path $PSScriptRoot 'build\FolderLock-ui.png')) }
    finally { $image.Dispose(); $form.Hide() }
    'PASS: UI initialized, paste path and password actions present'
'@)
$source = $source.Replace("[void][System.Windows.Forms.MessageBox]::Show(`$message, 'FolderLock', 'OK', 'Error')", 'throw $message')
$scriptPath = Join-Path $PSScriptRoot '.test-launch-script.ps1'
try {
    [IO.File]::WriteAllText($scriptPath, $source, [Text.UTF8Encoding]::new($true))
    & $scriptPath
} finally { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
