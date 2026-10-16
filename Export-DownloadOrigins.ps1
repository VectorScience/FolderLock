param([Parameter(Mandatory=$true)][string]$Folder, [Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
# Optional recovery tool. It exports decrypted JSON records, not video contents.
if(-not ('FolderLock.VaultEngine' -as [type])) {
    $source=Join-Path $PSScriptRoot 'VaultEngine.cs'
    if(Test-Path -LiteralPath $source){$code=[IO.File]::ReadAllText($source)}
    else {
        $assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'FolderLock.exe')))
        $reader=[IO.StreamReader]::new($assembly.GetManifestResourceStream('VaultEngine.cs'))
        try {$code=$reader.ReadToEnd()} finally {$reader.Dispose()}
    }
    Add-Type -TypeDefinition $code -ReferencedAssemblies System.Web.Extensions,System.Core
}
$rclone=Join-Path $PSScriptRoot 'rclone.exe'
if(-not(Test-Path -LiteralPath $rclone)){$rclone=Join-Path $PSScriptRoot 'build\tools\rclone.exe'}
$engine=New-Object FolderLock.VaultEngine($rclone)
$secret=Read-Host '输入保险箱密码（导出的 JSON 含原始下载来源，请妥善保存）' -AsSecureString
$pointer=[IntPtr]::Zero
try {
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    $password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $engine.ExportDownloadOrigins($Folder,$password,$Destination)
    Write-Host ('下载来源记录已导出到：'+[IO.Path]::GetFullPath($Destination))
} finally {
    $password=$null
    if($pointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
    $secret.Dispose()
}
