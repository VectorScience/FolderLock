param([switch]$ColdEncrypt)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$base=Join-Path $PSScriptRoot ('.test-openflow-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $base 'OVD'
$copyRoot=Join-Path $base 'copied\OVD'
$scriptPath=Join-Path $PSScriptRoot ('.test-openflow-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    [void][IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText((Join-Path $root 'before.txt'),'existing')
    $engine=New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
    if(-not $ColdEncrypt){$engine.Convert($root,'ui-flow-password',(New-Object FolderLock.Work))}
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FolderLock.ps1'))
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    $passwordFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-Password'},$true)
    $source=$source.Remove($passwordFunction.Extent.StartOffset,$passwordFunction.Extent.EndOffset-$passwordFunction.Extent.StartOffset).Insert($passwordFunction.Extent.StartOffset,"function Read-Password {`$script:passwordPrompts++; return 'ui-flow-password'}")
    $source=$source.Replace('Local\FolderLock2UI-',('Local\FolderLock2FlowTest-'+[guid]::NewGuid().ToString('N')+'-'))
    $source=$source.Replace('Enable-EntryRecovery;','$null = 0;')
    $source=$source.Replace('Enable-ContextMenu;','$null = 0;')
    $source=$source.Replace("`$script:historyFile = Join-Path `$env:LOCALAPPDATA 'FolderLock\vaults.json'",("`$script:historyFile = '"+(Join-Path $base 'history.json')+"'"))
    $source=$source.Replace("`$script:requestDirectory=Join-Path `$PSScriptRoot 'open-requests'",("`$script:requestDirectory='"+(Join-Path $base 'requests')+"'"))
    $source=$source.Replace("Start-Process explorer.exe -ArgumentList (`$script:mounts[`$script:pendingRoot].Drive + '\')",'$null = 0')
    $source=$source.Replace("Start-Process explorer.exe -ArgumentList (`$script:mounts[`$root].Drive + '\')",'$null = 0')
    $source=$source.Replace("[void][System.Windows.Forms.MessageBox]::Show(`$message, 'FolderLock', 'OK', 'Error')",'throw $message')
    $source=$source.Replace('[void]$form.ShowDialog()',@'
    function Pump-Until([scriptblock]$condition) {
        $deadline=(Get-Date).AddSeconds(30)
        while(-not (& $condition) -and (Get-Date) -lt $deadline){[Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25}
        if(-not (& $condition)){throw ('UI operation timed out: '+$status.Text)}
    }
    $form.StartPosition='Manual'; $form.Location=[Drawing.Point]::new(-12000,-12000)
    $form.Show()
    if($EncryptPath) {
        Pump-Until {Test-Path -LiteralPath ($EncryptPath+'.folderlock\vault.json')}
        Pump-Until {-not $script:job}
        $OpenPath=$EncryptPath
        Queue-Open $OpenPath
    }
    Pump-Until {$script:mounts.ContainsKey($OpenPath)}
    if($script:mounts[$OpenPath].Drive -ne $OpenPath -or $drive.SelectedItem -ne '原路径'){throw 'Shortcut opened a drive letter instead of original path'}
    if([IO.File]::ReadAllText((Join-Path $OpenPath 'before.txt')) -ne 'existing'){throw 'UI unlock did not expose contents'}
    [IO.File]::WriteAllText((Join-Path $OpenPath 'from-ui.txt'),'saved from UI flow')
    Lock-All; Pump-Until {-not $script:lockWork}
    $copiedRoot=Join-Path (Split-Path $OpenPath) 'copied\OVD'
    [void][IO.Directory]::CreateDirectory((Split-Path $copiedRoot))
    Copy-Item -LiteralPath ($OpenPath+'.folderlock') -Destination ($copiedRoot+'.folderlock') -Recurse -Force
    $pathBox.Text=$copiedRoot+'.folderlock';$import.PerformClick()
    Pump-Until {$script:mounts.ContainsKey($copiedRoot)}
    if([IO.File]::ReadAllText((Join-Path $copiedRoot 'from-ui.txt')) -ne 'saved from UI flow'){throw 'Import UI did not open copied content'}
    Lock-All;Pump-Until {-not $script:lockWork}
    if($script:mounts.Count -ne 0 -or -not(Test-Path -LiteralPath (Join-Path $OpenPath '解锁文件夹.lnk'))){throw 'UI safe lock did not restore entry'}
    Queue-Open $OpenPath
    Pump-Until {$script:mounts.ContainsKey($OpenPath)}
    if($script:passwordPrompts -ne (3+[int][bool]$EncryptPath)){throw 'Import/shortcut queue did not prompt existing UI again'}
    if([IO.File]::ReadAllText((Join-Path $OpenPath 'from-ui.txt')) -ne 'saved from UI flow'){throw 'Saved UI file lost on shortcut reopen'}
    Lock-All; Pump-Until {-not $script:lockWork}
    $newRoot=Join-Path (Split-Path $OpenPath) 'new 中文 & ()'
    [void][IO.Directory]::CreateDirectory($newRoot)
    [IO.File]::WriteAllText((Join-Path $newRoot 'new.txt'),'context menu data')
    Queue-Open $newRoot -Encrypt
    Pump-Until {Test-Path -LiteralPath ($newRoot+'.folderlock\vault.json')}
    Pump-Until {-not $script:job}
    if([FolderLock.VaultEngine]::Read($newRoot).State -ne 'ready'){throw 'Context menu did not encrypt new directory'}
    if($script:passwordPrompts -ne (4+[int][bool]$EncryptPath)){throw 'Encrypt request did not prompt for a password'}
    Queue-Open $newRoot
    Pump-Until {$script:mounts.ContainsKey($newRoot)}
    if([IO.File]::ReadAllText((Join-Path $newRoot 'new.txt')) -cne 'context menu data'){throw 'Context encrypted file failed roundtrip'}
    Lock-All; Pump-Until {-not $script:lockWork}
    $form.Hide()
    'PASS: shortcut startup prompts password, uses original path, saves/locks, forwards another shortcut request and reopens encrypted content'
'@)
    [IO.File]::WriteAllText($scriptPath,$source,[Text.UTF8Encoding]::new($true))
    $startArgs=@{LauncherPath=(Join-Path $PSScriptRoot 'dist\FolderLock.exe');RclonePath=(Join-Path $PSScriptRoot 'build\tools\rclone.exe')}
    if($ColdEncrypt){$startArgs.EncryptPath=$root}else{$startArgs.OpenPath=$root}
    & $scriptPath @startArgs
} finally {
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    $full=[IO.Path]::GetFullPath($base)
    if(-not $full.StartsWith(($PSScriptRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.test-openflow-*'){throw 'Unsafe cleanup'}
    foreach($publicPath in @($root,$copyRoot,(Join-Path $base 'new 中文 & ()'))) {
        if((Test-Path -LiteralPath $publicPath) -and ((Get-Item -LiteralPath $publicPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){[IO.Directory]::Delete($publicPath)}
        $view=$publicPath+'.folderlock\view'
        if(Test-Path -LiteralPath $view){$acl=New-Object Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($false,$false); [IO.Directory]::SetAccessControl($view,$acl)}
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}
