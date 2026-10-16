param([string]$Ffmpeg)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$root = Join-Path $PSScriptRoot ('.test-write-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$engine = New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
$mount = $null
try {
    [void][IO.Directory]::CreateDirectory($root)
    [IO.File]::WriteAllText((Join-Path $root 'original.txt'), 'original')
    [IO.File]::WriteAllText((Join-Path $root 'existing.txt'), 'existing rename')
    $engine.Convert($root, 'writable-test-password', (New-Object FolderLock.Work))
    $mount = $engine.Open($root, 'writable-test-password', 'Y:')
    if ([IO.File]::ReadAllText('Y:\original.txt') -ne 'original') { throw 'Initial mounted read failed' }
    [IO.File]::Move('Y:\existing.txt','Y:\existing-renamed.txt')
    [IO.File]::WriteAllText('Y:\original.txt', 'modified and saved')
    $file = [IO.File]::Open('Y:\random.bin', 'Create', 'ReadWrite', 'Read')
    try { $file.SetLength(8192); $file.Position=4096; $file.Write([byte[]]@(1,2,3,4),0,4); $file.Position=1; $file.WriteByte(99) } finally { $file.Dispose() }
    [IO.Directory]::CreateDirectory('Y:\child') | Out-Null
    [IO.File]::WriteAllText('Y:\child\temporary.txt', 'rename content'); [IO.File]::Move('Y:\child\temporary.txt','Y:\child\renamed.txt')
    if ([IO.File]::ReadAllText('Y:\child\renamed.txt') -ne 'rename content') { throw 'Rename immediately lost contents' }
    [IO.File]::WriteAllText('Y:\delete.txt','to delete'); [IO.File]::Delete('Y:\delete.txt')
    $longName=('long-'+('文'*75)+('a'*70)+'.txt')
    [IO.File]::WriteAllText(('Y:\'+$longName),'long Unicode cached write')
    [IO.File]::WriteAllText('Y:\replacement.tmp','atomic save'); [IO.File]::Replace('Y:\replacement.tmp','Y:\original.txt',[System.Management.Automation.Language.NullString]::Value)
    [IO.Directory]::Move('Y:\child','Y:\renamed-folder')
    # Open write handle must prevent locking; it must remain usable after refusal.
    $held = [IO.File]::Open('Y:\held.txt', 'Create', 'Write', 'Read')
    try {
        $held.WriteByte(123); $blocked=$false
        try { $mount.Lock((New-Object FolderLock.Work),1) } catch { $blocked=$true }
        if (-not $blocked -or -not $mount.Attached) { throw 'Lock did not preserve active writer' }
        $held.WriteByte(124)
    } finally { $held.Dispose() }
    if ($Ffmpeg) {
        & $Ffmpeg -hide_banner -loglevel error -f lavfi -i 'color=c=red:s=64x64:r=10' -t 0.4 -c:v mpeg4 -y 'Y:\a.mp4'
        if ($LASTEXITCODE) { throw 'ffmpeg generate failed' }
        [IO.File]::Copy('Y:\a.mp4','Y:\b.mp4')
        [IO.File]::WriteAllText('Y:\join.txt', "file 'a.mp4'`nfile 'b.mp4'`n", [Text.UTF8Encoding]::new($false))
        & $Ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i 'Y:\join.txt' -c copy -y 'Y:\joined.mp4'
        if ($LASTEXITCODE) { throw 'ffmpeg concat failed' }
        & $Ffmpeg -hide_banner -loglevel error -i 'Y:\joined.mp4' -f null -
        if ($LASTEXITCODE) { throw 'ffmpeg output decode failed' }
    }
    $work = New-Object FolderLock.Work; $mount.Lock($work,30); $mount=$null
    if (Test-Path 'Y:\original.txt') { throw 'Drive still readable after lock' }
    if ([FolderLock.VaultEngine]::HasWriteCache($root)) { throw 'Plaintext cache retained after successful lock' }
    $mount = $engine.Open($root, 'writable-test-password', 'Y:')
    if ([IO.File]::ReadAllText('Y:\original.txt') -ne 'atomic save') { throw 'Saved edit not encrypted durably' }
    if ([IO.File]::ReadAllText('Y:\existing-renamed.txt') -ne 'existing rename' -or (Test-Path 'Y:\existing.txt')) { throw 'Existing file rename not persisted' }
    $bytes = [IO.File]::ReadAllBytes('Y:\random.bin')
    if ($bytes.Length -ne 8192 -or $bytes[1] -ne 99 -or $bytes[4096] -ne 1 -or $bytes[4099] -ne 4) { throw 'Random write not preserved' }
    if (-not (Test-Path 'Y:\renamed-folder\renamed.txt')) { throw ('Rename not preserved; actual files: ' + ([IO.Directory]::GetFiles('Y:\','*',[IO.SearchOption]::AllDirectories) -join ', ')) }
    if ([IO.File]::ReadAllText('Y:\renamed-folder\renamed.txt') -ne 'rename content' -or (Test-Path 'Y:\delete.txt')) { throw 'Rename/delete not preserved' }
    if ([IO.File]::ReadAllBytes('Y:\held.txt').Length -ne 2) { throw 'Held writer data lost' }
    if ([IO.File]::ReadAllText(('Y:\'+$longName)) -ne 'long Unicode cached write') { throw 'Long cached filename lost' }
    if ($Ffmpeg) { & $Ffmpeg -hide_banner -loglevel error -i 'Y:\joined.mp4' -f null -; if ($LASTEXITCODE) { throw 'Encrypted ffmpeg output did not reopen' } }
    $mount.Lock((New-Object FolderLock.Work),30); $mount=$null
    # Terminate before the write-back delay: recovery data must survive, and a
    # missing metadata file must block mount rather than let rclone discard it.
    $mount=$engine.Open($root,'writable-test-password','Y:')
    $recoveryName='恢复？：／.txt'
    [IO.File]::WriteAllText(('Y:\'+$recoveryName),'uncommitted recovery content')
    $mount.Abort(); $mount=$null
    if (-not [FolderLock.VaultEngine]::HasWriteCache($root)) { throw 'Abnormal exit falsely marked locked' }
    $meta=Get-ChildItem (Join-Path $root '.folderlock\write-cache\vfsMeta') -File -Recurse | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).Dirty } | Select-Object -First 1
    if (-not $meta) { throw 'Recovery metadata missing' }
    [IO.File]::Move($meta.FullName,($meta.FullName+'.saved'))
    try {
        $refused=$false; try { $unexpected=$engine.Open($root,'writable-test-password','Y:'); $unexpected.Abort() } catch {$refused=$true}
        if (-not $refused) {throw 'Orphaned cache accepted; it might be deleted by rclone'}
        $data=Get-ChildItem (Join-Path $root '.folderlock\write-cache\vfs') -File -Recurse | Where-Object Name -eq $meta.Name | Select-Object -First 1
        if (-not $data -or [IO.File]::ReadAllText($data.FullName) -ne 'uncommitted recovery content') {throw 'Orphan cache was deleted'}
    } finally { [IO.File]::Move(($meta.FullName+'.saved'),$meta.FullName) }
    $mount=$engine.Open($root,'writable-test-password','Y:')
    $until=(Get-Date).AddSeconds(20)
    while(-not (Test-Path -LiteralPath ('Y:\'+$recoveryName)) -and (Get-Date) -lt $until -and $mount.Alive) {Start-Sleep -Milliseconds 100}
    if ([IO.File]::ReadAllText(('Y:\'+$recoveryName)) -ne 'uncommitted recovery content') {throw 'Crash recovery failed'}
    $mount.Lock((New-Object FolderLock.Work),30); $mount=$null
    if ([FolderLock.VaultEngine]::HasWriteCache($root)) {throw 'Recovered cache not cleared after safe lock'}
    'PASS: writable mount, random seek/save, atomic replace, rename/delete, long Unicode names, active writer lock refusal, cache cleanup, encrypted reopen, crash recovery and orphan-cache protection' + $(if ($Ffmpeg) { ', actual ffmpeg concat' })
} finally {
    if ($mount) { $mount.Abort() }
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike '.test-write-*') { throw 'Unsafe cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
