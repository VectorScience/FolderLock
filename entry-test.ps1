$ErrorActionPreference='Stop'
$base=Join-Path $PSScriptRoot ('.test-entry-'+[guid]::NewGuid().ToString('N'))
$mutex=$null
try {
    [void][IO.Directory]::CreateDirectory($base)
    $identity='FolderLock2EntryTest-'+[guid]::NewGuid().ToString('N')+'-'
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.cs'))
    $source=$source.Replace('Local\\FolderLock2UI-',('Local\\'+$identity)).Replace('Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)',('@"'+$base+'"'))
    $cs=Join-Path $base 'EntryLauncher.cs'; $exe=Join-Path $base 'EntryLauncher.exe'
    [IO.File]::WriteAllText($cs,$source,[Text.UTF8Encoding]::new($true))
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:winexe /reference:System.Windows.Forms.dll (('/out:')+$exe) $cs
    if($LASTEXITCODE){throw 'Entry launcher compilation failed'}
    $created=$false
    $mutex=[Threading.Mutex]::new($true,('Local\'+$identity+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value),[ref]$created)
    if(-not $created){throw 'Test mutex collision'}
    $type=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe)).GetType('Launcher')
    $method=$type.GetMethod('Main',[Reflection.BindingFlags]'Static,NonPublic')
    $target=Join-Path $base 'OVD 中文 & ()'
    $arguments=New-Object object[] 1; $arguments[0]=[string[]]@('--open',$target)
    if($method.Invoke($null,$arguments) -ne 0){throw 'Existing UI forwarding failed'}
    $requests=@(Get-ChildItem (Join-Path $base 'FolderLock\app-v2\open-requests') -Filter '*.request' -File)
    if($requests.Count -ne 1 -or [IO.File]::ReadAllText($requests[0].FullName) -cne $target){throw 'Shortcut request path changed or not forwarded'}
    $arguments[0]=[string[]]@('--restore-entries')
    if($method.Invoke($null,$arguments) -ne 0){throw 'Restore launcher failed while UI is active'}
    if(@(Get-ChildItem (Join-Path $base 'FolderLock\app-v2\open-requests') -Filter '*.request' -File).Count -ne 1){throw 'Silent startup generated an interactive request'}
    $arguments[0]=[string[]]@('--encrypt',$target)
    if($method.Invoke($null,$arguments) -ne 0){throw 'Encrypt forwarding failed'}
    $encryptRequests=@(Get-ChildItem (Join-Path $base 'FolderLock\app-v2\open-requests') -Filter '*.encrypt.request' -File)
    if($encryptRequests.Count -ne 1 -or [IO.File]::ReadAllText($encryptRequests[0].FullName) -cne $target){throw 'Encrypt action or path lost'}
    [IO.File]::WriteAllText((Join-Path $base 'FolderLock\app-v2\download-unlock-v1.pid'),[string]$PID)
    $unlockFile=Join-Path $base 'unlock-request.json'
    $arguments[0]=[string[]]@('--unlock-request',$unlockFile)
    if($method.Invoke($null,$arguments) -ne 0){throw 'Download unlock forwarding failed'}
    $unlockRequests=@(Get-ChildItem (Join-Path $base 'FolderLock\app-v2\open-requests') -Filter '*.unlock.request' -File)
    if($unlockRequests.Count -ne 1 -or [IO.File]::ReadAllText($unlockRequests[0].FullName) -cne $unlockFile){throw 'Download unlock request path lost'}
    'PASS: compiled launcher forwards open/encrypt/download unlock requests without starting a second app'
} finally {
    if($mutex){$mutex.ReleaseMutex();$mutex.Dispose()}
    $full=[IO.Path]::GetFullPath($base)
    if(-not $full.StartsWith(($PSScriptRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.test-entry-*'){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
