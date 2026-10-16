$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$registryPath='Software\FolderLock\Tests\'+[guid]::NewGuid().ToString('N')
try {
    $launcher=Join-Path $PSScriptRoot 'packages\FolderLock-2.3.0-Windows\FolderLock.exe'
    if(-not(Test-Path -LiteralPath $launcher)){$launcher=Join-Path $PSScriptRoot 'dist\FolderLock.exe'}
    Register-FolderContextMenu $launcher $registryPath
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath)
    try {
        if($key.GetValue('') -cne '使用 FolderLock 加密此文件夹' -or $key.GetValue('MultiSelectModel') -cne 'Single'){throw 'Menu registration invalid'}
        $command=$key.OpenSubKey('command')
        try {
            $expected=[FolderLock.VaultEngine]::Quote([IO.Path]::GetFullPath($launcher))+' --encrypt "%1"'
            if($command.GetValue('') -cne $expected){throw 'Menu command quoting or action incorrect'}
        } finally {$command.Dispose()}
    } finally {$key.Dispose()}
    Register-FolderContextMenu (Join-Path $PSScriptRoot 'dist\FolderLock.exe') $registryPath
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath)
    try {
        $expectedIcon=[FolderLock.VaultEngine]::Quote((Join-Path $PSScriptRoot 'dist\FolderLock-brand-v1.ico'))+',0'
        if($key.GetValue('Icon') -cne $expectedIcon){throw 'Context menu still uses old icon'}
    } finally {$key.Dispose()}
    'PASS: isolated per-user menu registration and update preserve exact executable and quoted folder placeholder'
} finally {[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath,$false)}
