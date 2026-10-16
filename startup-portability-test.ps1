$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$base=Join-Path $PSScriptRoot ('.test-portable-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $base 'OVD'; $copyRoot=Join-Path $base 'other-pc\OVD'
$launcher=Join-Path $PSScriptRoot 'dist\FolderLock.exe'
$engine=New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
$mount=$null
$registryPath='Software\FolderLock\Tests\'+[guid]::NewGuid().ToString('N')
function Assert($ok,$message){if(-not $ok){throw $message}}
try {
    [void][IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText((Join-Path $root 'video.mp4'),'portable encrypted bytes')
    $engine.Convert($root,'portable-password',(New-Object FolderLock.Work))
    $mount=$engine.OpenOriginal($root,'portable-password',$launcher)
    $portal=[FolderLock.VaultEngine].Assembly.GetType('FolderLock.Portal')
    [IO.File]::WriteAllText((Join-Path $root 'recover.txt'),'uncommitted bytes')
    $mount.Abort();$mount=$null
    $template=$root+'.folderlock\.entry-template.dat'
    [IO.File]::Copy($template,($root+'.folderlock\open.lnk'))
    [IO.File]::SetAttributes(($root+'.folderlock\open.lnk'),[IO.FileAttributes]::Normal)
    [IO.File]::SetAttributes($template,[IO.FileAttributes]::Normal);[IO.File]::Delete($template)
    $portal=[FolderLock.VaultEngine].Assembly.GetType('FolderLock.Portal')
    $portal.GetMethod('RemoveView',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@($root.PSObject.BaseObject))
    # Model a power-loss remnant: a recorded mount junction whose volume is gone.
    $view=$root+'.folderlock\view';$gone=Join-Path $base 'missing-volume'
    [void][IO.Directory]::CreateDirectory($view)
    $portal.GetMethod('SetJunction',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@($view,$gone.PSObject.BaseObject))
    $sessionPath=$root+'.folderlock\session.json';$session=Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $session | Add-Member -NotePropertyName ViewTarget -NotePropertyValue $gone -Force
    [IO.File]::WriteAllText($sessionPath,($session | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    $cacheBefore=@(Get-ChildItem ($root+'.folderlock\write-cache') -File -Recurse | Get-FileHash | Select-Object -ExpandProperty Hash)
    Assert ([FolderLock.VaultEngine]::RestoreEntry($root,$launcher)) 'Startup did not restore entry'
    Assert (Test-Path -LiteralPath (Join-Path $root '解锁文件夹.lnk')) 'Missing boot lock shortcut'
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut((Join-Path $root '解锁文件夹.lnk'))
    try {Assert ($shortcut.IconLocation -eq ((Join-Path (Split-Path $launcher) 'FolderLock-brand-v1.ico')+',0')) 'Restored shortcut still uses old icon'}
    finally {[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    Assert (-not(Test-Path -LiteralPath (Join-Path $root 'video.mp4'))) 'Startup unlocked without password'
    Assert ([FolderLock.VaultEngine]::HasWriteCache($root)) 'Startup falsely cleared pending recovery'
    $cacheAfter=@(Get-ChildItem ($root+'.folderlock\write-cache') -File -Recurse | Get-FileHash | Select-Object -ExpandProperty Hash)
    Assert (($cacheBefore -join ',') -eq ($cacheAfter -join ',')) 'Startup modified write cache'
    Assert (-not(Test-Path -LiteralPath ($root+'.folderlock\open.lnk'))) 'Duplicate Open shortcut remains'
    $portal.GetMethod('RemoveView',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@($root.PSObject.BaseObject))
    [void][IO.Directory]::CreateDirectory($view)
    $legacyTarget='\Device\Volume{'+[guid]::NewGuid().ToString()+'}\'
    $portal.GetMethod('SetJunction',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,[object[]]@($view,$legacyTarget))
    $session.PSObject.Properties.Remove('ViewTarget')
    [IO.File]::WriteAllText($sessionPath,($session | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
    $history=Join-Path $base 'history.json';[IO.File]::WriteAllText($history,(ConvertTo-Json -InputObject @($root)))
    Assert ((Restore-EntryHistory $history $launcher (Join-Path $base 'restore.log')) -eq 1) 'Startup history recovery failed'
    Assert (Test-Path -LiteralPath (Join-Path $root '解锁文件夹.lnk')) 'Legacy stale mount entry was not repaired'
    Register-EntryStartup $launcher $registryPath
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath)
    try {Assert ($key.GetValue('FolderLockEntryRestore') -eq ([FolderLock.VaultEngine]::Quote($launcher)+' --restore-entries')) 'Startup command is incorrect'} finally {$key.Dispose()}
    $mount=$engine.OpenOriginal($root,'portable-password',$launcher)
    Assert ([IO.File]::ReadAllText((Join-Path $root 'recover.txt')) -eq 'uncommitted bytes') 'Recovered bytes lost'
    $mount.Lock((New-Object FolderLock.Work),30);$mount=$null
    [void][IO.Directory]::CreateDirectory((Split-Path $copyRoot))
    Copy-Item -LiteralPath ($root+'.folderlock') -Destination ($copyRoot+'.folderlock') -Recurse -Force
    $configPath=$copyRoot+'.folderlock\portal.json';$before=(Get-FileHash -LiteralPath $configPath).Hash
    $refused=$false;try {$unexpected=$engine.ImportOriginal(($copyRoot+'.folderlock'),'wrong-password',$launcher);$unexpected.Abort()}catch{$refused=$true}
    Assert ($refused -and (Get-FileHash -LiteralPath $configPath).Hash -eq $before) 'Wrong import password changed binding'
    [void][IO.Directory]::CreateDirectory($copyRoot);[IO.File]::WriteAllText((Join-Path $copyRoot 'unrelated.txt'),'preserve')
    $refused=$false;try {$unexpected=$engine.ImportOriginal(($copyRoot+'.folderlock'),'portable-password',$launcher);$unexpected.Abort()}catch{$refused=$true}
    Assert ($refused -and [IO.File]::ReadAllText((Join-Path $copyRoot 'unrelated.txt')) -eq 'preserve' -and (Get-FileHash -LiteralPath $configPath).Hash -eq $before) 'Import overwrote a conflicting folder or changed binding'
    [IO.File]::Delete((Join-Path $copyRoot 'unrelated.txt'));[IO.Directory]::Delete($copyRoot)
    $mount=$engine.ImportOriginal(($copyRoot+'.folderlock'),'portable-password',$launcher)
    Assert ([IO.File]::ReadAllText((Join-Path $copyRoot 'video.mp4')) -eq 'portable encrypted bytes') 'Copied vault did not unlock'
    Assert ([IO.File]::ReadAllText((Join-Path $copyRoot 'recover.txt')) -eq 'uncommitted bytes') 'Copied recovered file lost'
    $mount.Lock((New-Object FolderLock.Work),30);$mount=$null
    $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($config.Root -eq $copyRoot) 'Copy retains original-machine path'
    Assert (Test-Path -LiteralPath (Join-Path $root '解锁文件夹.lnk')) 'Import damaged original vault'
    'PASS: password-free boot entry repair preserves ciphertext/cache, no duplicate Open, original-password import at a different path, wrong-password import leaves source intact'
} finally {
    if($mount){$mount.Abort()}
    if($registryPath.StartsWith('Software\FolderLock\Tests\')){[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath,$false)}
    $full=[IO.Path]::GetFullPath($base)
    if(-not $full.StartsWith(($PSScriptRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.test-portable-*'){throw 'Unsafe cleanup'}
    foreach($publicPath in @($root,$copyRoot)) {
        if((Test-Path -LiteralPath $publicPath) -and ((Get-Item -LiteralPath $publicPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){[IO.Directory]::Delete($publicPath)}
        $view=$publicPath+'.folderlock\view'
        if(Test-Path -LiteralPath $view){$acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($false,$false);[IO.Directory]::SetAccessControl($view,$acl)}
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}
