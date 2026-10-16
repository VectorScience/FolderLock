param([string]$Ffmpeg)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$base=Join-Path $PSScriptRoot ('.test-original-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $base 'OVD'
$fresh=Join-Path $base 'Fresh'
$engine=New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
$mount=$null
function Assert($ok,$message) {if(-not $ok){throw $message}}
try {
    [void][IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText((Join-Path $root 'old.mp4'),'existing content')
    $engine.Convert($root,'original-path-password',(New-Object FolderLock.Work))
    $before=@(Get-ChildItem (Join-Path $root '.folderlock\data') -File -Recurse | Get-FileHash | Select-Object -ExpandProperty Hash)
    $refused=$false; try {$unexpected=$engine.OpenOriginal($root,'wrong-password',(Join-Path $PSScriptRoot 'dist\FolderLock.exe')); $unexpected.Abort()} catch {$refused=$true}
    Assert ($refused -and (Test-Path -LiteralPath (Join-Path $root '.folderlock\vault.json'))) 'Wrong password changed layout'
    $guard=$root+'.folderlock.guard'; [IO.File]::WriteAllText($guard,'unrelated existing file')
    try {
        $unexpected=$engine.OpenOriginal($root,'original-path-password',(Join-Path $PSScriptRoot 'dist\FolderLock.exe')); $unexpected.Lock((New-Object FolderLock.Work),30)
        Assert ([IO.File]::ReadAllText($guard) -eq 'unrelated existing file') 'Transition guard modified an unrelated file'
    } finally {[IO.File]::Delete($guard)}
    try {$mount=$engine.OpenOriginal($root,'original-path-password',(Join-Path $PSScriptRoot 'dist\FolderLock.exe'))} catch {throw $_.Exception.ToString()}
    Assert ($mount.Drive -eq $root) 'Original path not exposed'
    Assert ([IO.File]::ReadAllText((Join-Path $root 'old.mp4')) -eq 'existing content') 'Existing video not accessible at original path'
    [IO.File]::WriteAllText((Join-Path $root 'downloading.part'),'download bytes')
    [IO.File]::Move((Join-Path $root 'downloading.part'),(Join-Path $root 'new？.mp4'))
    $mount.Lock((New-Object FolderLock.Work),30); $mount=$null
    Assert (Test-Path -LiteralPath (Join-Path $root '解锁文件夹.lnk')) 'Lock entry missing'
    Assert (-not(Test-Path -LiteralPath (Join-Path $root 'old.mp4'))) 'Plaintext still visible while locked'
    foreach($storagePath in @(($root+'.folderlock'),($root+'.folderlock\data'))) {
        $refused=$false; try {[void][FolderLock.VaultEngine]::Normalize($storagePath)} catch {$refused=$true}
        Assert $refused 'Ciphertext storage or its child accepted as an ordinary input folder'
    }
    $blocked=$false; try {[IO.File]::WriteAllText((Join-Path $root 'must-not-be-plaintext.mp4'),'unsafe')} catch {$blocked=$true}
    Assert $blocked 'Locked path accepted plaintext downloads'
    $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut((Join-Path $root '解锁文件夹.lnk'))
    Assert ($shortcut.Arguments.Contains($root)) 'Shortcut does not target this directory'
    $mount=$engine.OpenOriginal($root,'original-path-password',(Join-Path $PSScriptRoot 'dist\FolderLock.exe'))
    Assert ([IO.File]::ReadAllText((Join-Path $root 'new？.mp4')) -eq 'download bytes') 'Download not durably encrypted'
    if($Ffmpeg) {
        & $Ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=red:s=64x64:r=10' -t 0.4 -c:v mpeg4 -y (Join-Path $root 'a.mp4')
        Assert ($LASTEXITCODE -eq 0) 'Original path ffmpeg write failed'
        & $Ffmpeg -hide_banner -loglevel error -i (Join-Path $root 'a.mp4') -f null -
        Assert ($LASTEXITCODE -eq 0) 'Original path ffmpeg read failed'
    }
    [IO.File]::WriteAllText((Join-Path $root 'recover.txt'),'recover original path')
    # Kill the backend before the UI can restore its shortcut. The permanent
    # original-path junction must prevent downloaders from recreating plaintext.
    $backend=$mount.GetType().GetField('process',[Reflection.BindingFlags]'Instance,NonPublic').GetValue($mount)
    $backend.Kill(); $backend.WaitForExit()
    $deadline=(Get-Date).AddSeconds(5)
    while((Test-Path -LiteralPath ($root+'.folderlock\view')) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
    $blocked=$false; try {[void][IO.Directory]::CreateDirectory($root); [IO.File]::WriteAllText((Join-Path $root 'crash-plaintext.mp4'),'unsafe')} catch {$blocked=$true}
    Assert $blocked 'Crashed mount allowed plaintext path recreation'
    $mount.Abort(); $mount=$null
    Assert ([FolderLock.VaultEngine]::HasWriteCache($root)) 'Crash recovery cache lost'
    $mount=$engine.OpenOriginal($root,'original-path-password',(Join-Path $PSScriptRoot 'dist\FolderLock.exe'))
    Assert ([IO.File]::ReadAllText((Join-Path $root 'recover.txt')) -eq 'recover original path') 'Crash recovery failed'
    $mount.Lock((New-Object FolderLock.Work),30); $mount=$null
    Assert (-not[FolderLock.VaultEngine]::HasWriteCache($root)) 'Safe lock retained plaintext cache'
    $after=@(Get-ChildItem ($root+'.folderlock\data') -File -Recurse | Get-FileHash | Select-Object -ExpandProperty Hash)
    Assert ($after -contains $before[0]) 'Upgrade re-encrypted existing video'
    [void][IO.Directory]::CreateDirectory($fresh); [IO.File]::WriteAllText((Join-Path $fresh 'fresh.txt'),'new vault')
    $job=$engine.BeginConvert($fresh,'original-path-password',(Join-Path $PSScriptRoot 'dist\FolderLock.exe'))
    $deadline=(Get-Date).AddSeconds(30)
    while(-not $job.Done -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
    Assert ($job.Done -and -not $job.Error) ('New-vault entry installation failed: '+$job.Error)
    Assert (Test-Path -LiteralPath (Join-Path $fresh '解锁文件夹.lnk')) 'New encryption did not install entry'
    'PASS: same-path upgrade without copying ciphertext, download/rename/encrypted reopen, shortcut, blocked locked writes, crash recovery' + $(if($Ffmpeg){', actual ffmpeg'})
} finally {
    if($mount){$mount.Abort()}
    $full=[IO.Path]::GetFullPath($base)
    if(-not $full.StartsWith(($PSScriptRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.test-original-*'){throw 'Unsafe cleanup'}
    foreach($publicPath in @($root,$fresh)) {
        if((Test-Path -LiteralPath $publicPath) -and ((Get-Item -LiteralPath $publicPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){[IO.Directory]::Delete($publicPath)}
        $view=$publicPath+'.folderlock\view'
        if(Test-Path -LiteralPath $view){$acl=New-Object Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($false,$false); [IO.Directory]::SetAccessControl($view,$acl)}
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}
