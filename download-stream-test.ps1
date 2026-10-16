$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$base=Join-Path $PSScriptRoot ('.test-download-stream-'+[guid]::NewGuid().ToString('N'))
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
try {
    $root=Join-Path $base 'videos';[void][IO.Directory]::CreateDirectory($root)
    $file=Join-Path $root 'sample.webm';$bytes=New-Object byte[] 12345;[Random]::new(71).NextBytes($bytes);[IO.File]::WriteAllBytes($file,$bytes)
    $zone="[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://example.invalid/video.webm`r`n"
    Set-Content -LiteralPath $file -Stream Zone.Identifier -Value $zone -NoNewline -Encoding UTF8
    $zoneBytes=[byte[]](Get-Content -LiteralPath $file -Stream Zone.Identifier -Encoding Byte -ReadCount 0)
    $engine=New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
    $password='download-stream-test-password'
    $engine.Convert($root,$password,(New-Object FolderLock.Work))
    Assert ([FolderLock.VaultEngine]::Read($root).State -eq 'ready') 'Downloaded video was not encrypted'
    Assert (-not(Test-Path -LiteralPath $file)) 'Converted plaintext remains'
    $info=[FolderLock.VaultEngine]::Read($root)
    $envCrypt=New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach($name in @('TEST','META')) {
        $prefix='RCLONE_CONFIG_'+$name+'_'
        $envCrypt[$prefix+'TYPE']='crypt'
        $envCrypt[$prefix+'REMOTE']=Join-Path $root $(if($name -eq 'TEST'){'.folderlock\data'}else{'.folderlock\keycheck'})
        $envCrypt[$prefix+'PASSWORD']=$engine.Command(@('obscure','-'),$null,$password)
        $envCrypt[$prefix+'PASSWORD2']=$engine.Command(@('obscure','-'),$null,$info.Salt)
        $envCrypt[$prefix+'FILENAME_ENCODING']=$(if($name -eq 'TEST'){$info.FilenameEncoding}else{'base32'})
    }
    $export=Join-Path $base 'export'
    [void]$engine.Command(@('copy','test:',$export),$envCrypt,$null)
    Assert ((Get-FileHash -LiteralPath (Join-Path $export 'sample.webm')).Hash -eq ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-',''))) 'Video bytes changed'
    $records=@($engine.Command(@('lsf','meta:download-origins'),$envCrypt,$null) -split "`n" | Where-Object {$_})
    Assert ($records.Count -eq 1) 'Encrypted origin record missing'
    $record=$engine.Command(@('cat',('meta:download-origins/'+$records[0])),$envCrypt,$null) | ConvertFrom-Json
    Assert ($record.Path -ceq 'sample.webm') 'Origin record points to wrong file'
    Assert ([Convert]::ToBase64String([Convert]::FromBase64String($record.Data)) -ceq [Convert]::ToBase64String($zoneBytes)) 'Origin stream bytes lost'
    $originExport=Join-Path $base 'origin-export'
    $engine.ExportDownloadOrigins($root,$password,$originExport)
    $saved=@(Get-ChildItem -LiteralPath $originExport -File)
    Assert ($saved.Count -eq 1) 'Origin recovery export missing'
    $savedRecord=Get-Content -LiteralPath $saved[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($savedRecord.Data -ceq $record.Data) 'Exported source mark differs'
    $badExport=Join-Path $base 'wrong-password-export'
    $rejected=$false;try{$engine.ExportDownloadOrigins($root,'wrong-password',$badExport)}catch{$rejected=$true}
    Assert ($rejected -and -not(Test-Path -LiteralPath $badExport)) 'Wrong password exported private metadata'
    $mount=$engine.OpenOriginal($root,$password,(Join-Path $PSScriptRoot 'dist\FolderLock.exe'))
    try {
        Assert ((Get-FileHash -LiteralPath $file).Hash -eq $record.SHA256) 'Mounted downloaded video differs'
        [IO.File]::Move($file,(Join-Path $root 'renamed.webm'))
        $mount.Lock((New-Object FolderLock.Work),30)
    } finally {if(-not $mount.Closed){$mount.Abort()}}
    $afterMount=Join-Path $base 'origins-after-mount'
    $engine.ExportDownloadOrigins($root,$password,$afterMount)
    $afterRecord=Get-Content -LiteralPath (Get-ChildItem -LiteralPath $afterMount -File | Select-Object -First 1).FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($afterRecord.Data -ceq $record.Data) 'Origin archive lost after original-path mount/rename/lock'
    $unknown=Join-Path $base 'unknown';[void][IO.Directory]::CreateDirectory($unknown)
    $unknownFile=Join-Path $unknown 'custom.webm';[IO.File]::WriteAllText($unknownFile,'keep')
    Set-Content -LiteralPath $unknownFile -Stream extra -Value 'application metadata' -NoNewline
    $rejected=$false;try{$engine.Convert($unknown,$password,(New-Object FolderLock.Work))}catch{$rejected=$true}
    Assert $rejected 'Unknown stream silently accepted'
    Assert ((Get-Content -LiteralPath $unknownFile -Stream extra -Raw) -ceq 'application metadata') 'Unknown stream altered'
    # A source mark on executable content is not silently removed as a media exception.
    $programs=Join-Path $base 'programs';[void][IO.Directory]::CreateDirectory($programs)
    $program=Join-Path $programs 'sample.exe';[IO.File]::WriteAllText($program,'keep executable mark')
    Set-Content -LiteralPath $program -Stream Zone.Identifier -Value $zone -NoNewline
    $rejected=$false;try{$engine.Convert($programs,$password,(New-Object FolderLock.Work))}catch{$rejected=$true}
    Assert ($rejected -and (Test-Path -LiteralPath $program)) 'Executable origin mark bypassed'
    # Fault injection still uses real rclone encryption. Only origin verification is damaged.
    $smoke=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'smoke-test.ps1'))
    $begin=$smoke.IndexOf("`$shimSource = @'")+"`$shimSource = @'".Length
    $end=$smoke.IndexOf("'@",$begin)
    $shim=$smoke.Substring($begin,$end-$begin)
    $shim=$shim.Replace('args[1].StartsWith("fldata:")','args[1].StartsWith("flmeta:download-origins/")')
    $shim=$shim.Replace('Environment.GetEnvironmentVariable("RCLONE_CONFIG_FLDATA_REMOTE")','Environment.GetEnvironmentVariable("RCLONE_CONFIG_FLMETA_REMOTE")')
    $shim=$shim.Replace('Directory.GetFiles(root, "*", SearchOption.AllDirectories).First()','Directory.GetFiles(root, "*", SearchOption.AllDirectories).First(candidate => new FileInfo(candidate).Length > 100)')
    $cs=Join-Path $base 'OriginFault.cs';$exe=Join-Path $base 'OriginFault.exe'
    [IO.File]::WriteAllText($cs,$shim)
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe (('/out:')+$exe) $cs
    Assert ($LASTEXITCODE -eq 0) 'Fault wrapper compilation failed'
    $previousRclone=$env:FOLDERLOCK_TEST_RCLONE
    $env:FOLDERLOCK_TEST_RCLONE=Join-Path $PSScriptRoot 'build\tools\rclone.exe'
    try {
        $faultRoot=Join-Path $base 'fault';[void][IO.Directory]::CreateDirectory($faultRoot)
        $faultFile=Join-Path $faultRoot 'sample.webm';[IO.File]::WriteAllBytes($faultFile,$bytes)
        Set-Content -LiteralPath $faultFile -Stream Zone.Identifier -Value $zone -NoNewline -Encoding UTF8
        $faultEngine=New-Object FolderLock.VaultEngine($exe)
        $failure=$null;try{$faultEngine.Convert($faultRoot,$password,(New-Object FolderLock.Work))}catch{$failure=$_.Exception.ToString()}
        Assert ($failure -and $failure.Contains('密文回读验证失败')) 'Metadata fault was not detected'
        Assert ((Get-FileHash -LiteralPath $faultFile).Hash -eq $record.SHA256) 'Origin verification failure deleted video'
        Assert ([Convert]::ToBase64String([byte[]](Get-Content -LiteralPath $faultFile -Stream Zone.Identifier -Encoding Byte -ReadCount 0)) -ceq [Convert]::ToBase64String($zoneBytes)) 'Origin verification failure lost stream'
        Assert ([FolderLock.VaultEngine]::Read($faultRoot).State -eq 'converting') 'Origin backup failure shown as complete'
        $engine.Convert($faultRoot,$password,(New-Object FolderLock.Work))
        Assert ([FolderLock.VaultEngine]::Read($faultRoot).State -eq 'ready') 'Retry after origin fault failed'
    } finally {$env:FOLDERLOCK_TEST_RCLONE=$previousRclone}
    'PASS: downloaded media encrypts byte-exactly, source mark is encrypted and recoverable, unknown streams remain intact'
} finally {
    $full=[IO.Path]::GetFullPath($base)
    if(-not $full.StartsWith(($PSScriptRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.test-download-stream-*'){throw 'Unsafe cleanup'}
    if((Test-Path -LiteralPath $root) -and ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){[IO.Directory]::Delete($root)}
    $view=$root+'.folderlock\view'
    if(Test-Path -LiteralPath $view){$acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($false,$false);[IO.Directory]::SetAccessControl($view,$acl)}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
