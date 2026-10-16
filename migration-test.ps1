$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$root = Join-Path $PSScriptRoot ('.test-migrate-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$interrupted=$root+'-resume'
$engine = New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
$password = 'migration-test-password'
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $root '.folderlock'))
    $info = @{ Version=1; Id=[guid]::NewGuid().ToString('N'); Salt='migration-public-salt'; State='converting' }
    [IO.File]::WriteAllText((Join-Path $root '.folderlock\vault.json'),(ConvertTo-Json $info))
    $envMap=New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $secret=$engine.Command(@('obscure','-'),$null,$password); $salt=$engine.Command(@('obscure','-'),$null,$info.Salt)
    foreach($remote in @('FLDATA','FLMETA')) {
        $prefix='RCLONE_CONFIG_'+$remote+'_'; $envMap[$prefix+'TYPE']='crypt'; $envMap[$prefix+'REMOTE']=Join-Path $root ('.folderlock\'+$(if($remote -eq 'FLDATA'){'data'}else{'keycheck'}))
        $envMap[$prefix+'PASSWORD']=$secret; $envMap[$prefix+'PASSWORD2']=$salt
    }
    [void]$engine.Command(@('rcat','flmeta:check'),$envMap,('FolderLock:'+$info.Id))
    [IO.File]::WriteAllText((Join-Path $root 'already.txt'),'already encrypted unchanged')
    [void]$engine.Command(@('copyto',(Join-Path $root 'already.txt'),'fldata:sub/already.txt'),$envMap,$null)
    [IO.File]::Delete((Join-Path $root 'already.txt'))
    [void]$engine.Command(@('mkdir','fldata:empty'),$envMap,$null)
    $oldCipher=Get-ChildItem (Join-Path $root '.folderlock\data') -Recurse -File | Select-Object -First 1
    $oldHash=(Get-FileHash -LiteralPath $oldCipher.FullName -Algorithm SHA256).Hash
    $longName=('a'*170)+'.txt'; [IO.File]::WriteAllText((Join-Path $root $longName),'unconverted long source')
    $engine.Convert($root,$password,(New-Object FolderLock.Work))
    $updated=[FolderLock.VaultEngine]::Read($root)
    if($updated.State -ne 'ready' -or $updated.FilenameEncoding -ne 'base32768') {throw 'Legacy vault did not upgrade'}
    $envMap['RCLONE_CONFIG_FLDATA_FILENAME_ENCODING']='base32768'
    if($engine.Command(@('cat','fldata:sub/already.txt'),$envMap,$null) -ne 'already encrypted unchanged') {throw 'Legacy encrypted data lost'}
    if($engine.Command(@('cat',('fldata:'+$longName)),$envMap,$null) -ne 'unconverted long source') {throw 'Legacy long source not recovered'}
    $encoded=$engine.Command(@('backend','encode','fldata:','sub/already.txt'),$envMap,$null)
    $newHash=(Get-FileHash -LiteralPath (Join-Path $root ('.folderlock\data\'+$encoded.Replace('/','\'))) -Algorithm SHA256).Hash
    if($newHash -ne $oldHash) {throw 'Migration changed ciphertext content'}
    if(Test-Path (Join-Path $root '.folderlock\name-migration.json')) {throw 'Migration journal not completed'}
    # Simulate interruption after a name was renamed but before journal.Next was saved.
    [void][IO.Directory]::CreateDirectory((Join-Path $interrupted '.folderlock'))
    $info.Id=[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $interrupted '.folderlock\vault.json'),(ConvertTo-Json $info))
    $envMap['RCLONE_CONFIG_FLDATA_REMOTE']=Join-Path $interrupted '.folderlock\data'
    $envMap['RCLONE_CONFIG_FLMETA_REMOTE']=Join-Path $interrupted '.folderlock\keycheck'
    $envMap['RCLONE_CONFIG_FLDATA_FILENAME_ENCODING']='base32'
    [void]$engine.Command(@('rcat','flmeta:check'),$envMap,('FolderLock:'+$info.Id))
    $steps=@()
    foreach($name in @('a.txt','b.txt')) {
        [void]$engine.Command(@('rcat',('fldata:'+$name)),$envMap,('saved '+$name))
        $old=$engine.Command(@('backend','encode','fldata:',$name),$envMap,$null)
        $envMap['RCLONE_CONFIG_FLDATA_FILENAME_ENCODING']='base32768'
        $new=$engine.Command(@('backend','encode','fldata:',$name),$envMap,$null)
        $envMap['RCLONE_CONFIG_FLDATA_FILENAME_ENCODING']='base32'
        $steps+=@{Source=$old;Destination=$new;Directory=$false}
    }
    [IO.File]::Move((Join-Path $interrupted ('.folderlock\data\'+$steps[0].Source)),(Join-Path $interrupted ('.folderlock\data\'+$steps[0].Destination)))
    [IO.File]::WriteAllText((Join-Path $interrupted '.folderlock\name-migration.json'),(ConvertTo-Json @{Next=0;Steps=$steps} -Depth 5))
    $engine.Convert($interrupted,$password,(New-Object FolderLock.Work))
    $envMap['RCLONE_CONFIG_FLDATA_FILENAME_ENCODING']='base32768'
    foreach($name in @('a.txt','b.txt')) {if($engine.Command(@('cat',('fldata:'+$name)),$envMap,$null) -ne ('saved '+$name)) {throw 'Interrupted name migration lost contents'}}
    'PASS: legacy base32 vault resumes long filename conversion; ciphertext unchanged'
} finally {
    foreach($path in @($root,$interrupted)) {
        $resolved=[IO.Path]::GetFullPath($path)
        if(-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike '.test-migrate-*') {throw 'Unsafe cleanup'}
        if(Test-Path -LiteralPath $resolved) {Remove-Item -LiteralPath $resolved -Recurse -Force}
    }
}
