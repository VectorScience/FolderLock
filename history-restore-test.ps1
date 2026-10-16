$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$base=Join-Path $PSScriptRoot ('.test-history-'+[guid]::NewGuid().ToString('N'))
$roots=@((Join-Path $base 'OVD'),(Join-Path $base 'second vault'))
$oldLauncher=Join-Path $base 'old\FolderLock.exe'
$launcher=Join-Path $PSScriptRoot 'dist\FolderLock.exe'
$engine=New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
$shell=$null
try {
    [void][IO.Directory]::CreateDirectory((Split-Path $oldLauncher))
    [IO.File]::Copy($launcher,$oldLauncher)
    foreach($root in $roots) {
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::WriteAllText((Join-Path $root 'video.mp4'),'preserve encrypted video')
        $job=$engine.BeginConvert($root,'history-password',$oldLauncher)
        while(-not $job.Done){Start-Sleep -Milliseconds 50}
        if($job.Error){throw $job.Error}
    }
    [IO.File]::Delete($oldLauncher)
    $before=@(foreach($root in $roots){Get-ChildItem ($root+'.folderlock\data') -File -Recurse | Get-FileHash | Select-Object -ExpandProperty Hash})
    $history=Join-Path $base 'vaults.json';$log=Join-Path $base 'restore.log'
    [IO.File]::WriteAllText($history,(ConvertTo-Json -InputObject $roots))
    $count=Restore-EntryHistory $history $launcher $log
    if($count -ne 2){throw "Expected both shortcuts repaired, got $count. $(Get-Content $log -Raw)"}
    $shell=New-Object -ComObject WScript.Shell
    foreach($root in $roots) {
        $link=$shell.CreateShortcut((Join-Path $root '解锁文件夹.lnk'))
        try {
            if($link.TargetPath -ne $launcher -or -not [IO.File]::Exists($link.TargetPath) -or $link.Arguments -ne ('--open '+[FolderLock.VaultEngine]::Quote($root))){throw 'Shortcut target or arguments not repaired'}
        } finally {[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}
        if(Test-Path (Join-Path $root 'video.mp4')){throw 'Repair exposed plaintext'}
    }
    $after=@(foreach($root in $roots){Get-ChildItem ($root+'.folderlock\data') -File -Recurse | Get-FileHash | Select-Object -ExpandProperty Hash})
    if(($before -join ',') -ne ($after -join ',')){throw 'Repair changed ciphertext'}
    'PASS: two stale shortcuts repaired after launcher removal; ciphertext unchanged and vaults remain locked'
} finally {
    if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    $full=[IO.Path]::GetFullPath($base)
    if(-not $full.StartsWith(($PSScriptRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.test-history-*'){throw 'Unsafe cleanup'}
    foreach($root in $roots) {
        if((Test-Path -LiteralPath $root) -and ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){[IO.Directory]::Delete($root)}
        $view=$root+'.folderlock\view'
        if(Test-Path -LiteralPath $view){$acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($false,$false);[IO.Directory]::SetAccessControl($view,$acl)}
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}
