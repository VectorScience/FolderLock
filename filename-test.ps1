param([string]$Only, [switch]$MountTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$root = Join-Path $PSScriptRoot ('.test-names-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$engine = New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
$mount=$null
try {
    [void][IO.Directory]::CreateDirectory($root)
    $names = @('00-first.mp4', '01-标题：全角？.mp4', '02-全角／斜线＼引号＂.mp4', '03-星号＊竖线｜小于＜大于＞.mp4', ('04-引用' + [char]0x201B + '符号.mp4'))
    $names += @('05-结尾．', '06-结尾␠', '07-符号␟␡.txt', ('08-引用'+[char]0x201B+'AB.txt'), ('09-引用'+[char]0x201B+'？.txt'))
    if ($Only) { $names=@('00-first.mp4',$Only) }
    foreach($name in $names) { [IO.File]::WriteAllText((Join-Path $root $name),('content of '+$name),[Text.UTF8Encoding]::new($false)) }
    $engine.Convert($root,'filename-test-password',(New-Object FolderLock.Work))
    $info=[FolderLock.VaultEngine]::Read($root)
    if($info.State -ne 'ready') { throw 'Conversion incomplete' }
    $envMap=New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $envMap['RCLONE_CONFIG_CHECK_TYPE']='crypt'; $envMap['RCLONE_CONFIG_CHECK_REMOTE']=Join-Path $root '.folderlock\data'
    $envMap['RCLONE_CONFIG_CHECK_FILENAME_ENCODING']=$info.FilenameEncoding
    $envMap['RCLONE_CONFIG_CHECK_PASSWORD']=$engine.Command(@('obscure','-'),$null,'filename-test-password')
    $envMap['RCLONE_CONFIG_CHECK_PASSWORD2']=$engine.Command(@('obscure','-'),$null,$info.Salt)
    foreach($name in $names) {
        if(Test-Path -LiteralPath (Join-Path $root $name)) {throw ('Source survived completed conversion: '+$name)}
        if($engine.Command(@('cat',('check:'+$name)),$envMap,$null) -cne ('content of '+$name)) {throw ('Name/content did not roundtrip: '+$name)}
    }
    if ($MountTest) {
        $mount=$engine.Open($root,'filename-test-password','Y:')
        foreach($name in $names) {
            if([IO.File]::ReadAllText(('Y:\'+$name),[Text.Encoding]::UTF8) -cne ('content of '+$name)) {throw ('Mounted filename did not roundtrip: '+$name)}
            [IO.File]::WriteAllText(('Y:\'+$name),('edited '+$name),[Text.UTF8Encoding]::new($false))
        }
        $lockWork=New-Object FolderLock.Work
        try {$mount.Lock($lockWork,30)} catch {throw ($lockWork.Message+': '+$_.Exception.Message)}
        $mount=$null
        $mount=$engine.Open($root,'filename-test-password','Y:')
        foreach($name in $names) {
            if([IO.File]::ReadAllText(('Y:\'+$name),[Text.Encoding]::UTF8) -cne ('edited '+$name)) {throw ('Edited filename did not roundtrip: '+$name)}
        }
        $mount.Lock((New-Object FolderLock.Work),30); $mount=$null
    }
    'PASS: first file followed by fullwidth punctuation and quotation-like filenames'
} finally {
    if($mount) {$mount.Abort()}
    $resolved=[IO.Path]::GetFullPath($root)
    if(-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike '.test-names-*') {throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
