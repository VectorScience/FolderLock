$ErrorActionPreference = 'Stop'
$source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Legacy-FolderLock.ps1'))
$prefix = $source.Substring(0, $source.IndexOf("`nif (`$OpenId) {"))
Invoke-Expression $prefix
$script:DataDir = Join-Path $PSScriptRoot '.test-data'
$script:DataFile = Join-Path $script:DataDir 'folders.json'
$target = Join-Path $PSScriptRoot '.test-private'
[void](New-Item -ItemType Directory -Path $target -Force)
[System.IO.File]::WriteAllText((Join-Path $target 'hello.txt'), 'hello')
$before = (Get-Acl -LiteralPath $target).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
try {
    Initialize-GlobalConfig 'password123'
    $entry = Add-Entry $target
    if (-not (Get-Entries)[0].locked) { throw 'Entry was not locked' }
    if ((Get-Entries)[0].PSObject.Properties['hash']) { throw 'Password hash was stored per folder' }
    $blocked = $false
    try { [void](Get-Content -LiteralPath (Join-Path $target 'hello.txt') -ErrorAction Stop) }
    catch [System.UnauthorizedAccessException] { $blocked = $true }
    if (-not $blocked) { throw 'File remained readable while locked' }
    if (Test-Password 'incorrect' (Get-Config)) { throw 'Wrong password accepted' }
    if (-not (Test-Password 'password123' (Get-Config))) { throw 'Right password rejected' }
    Save-Options $true $true $true 0
    if ((Get-Config).minutes -ne 0) { throw 'Unlimited setting was not saved' }
    Unlock-Entry $entry.id 'password123'
    Invoke-State {
        param($items)
        $items[0].unlockedAt = '2000-01-01T00:00:00Z'
        @{ Save = $true; Entries = $items }
    } | Out-Null
    Check-AutoLock
    if ((Get-Entries)[0].locked) { throw 'Unlimited duration unexpectedly locked the folder' }
    Save-Options $true $true $true 1
    Check-AutoLock
    if (-not (Get-Entries)[0].locked) { throw 'Finite duration did not lock the folder' }
    Unlock-Entry $entry.id 'password123'
    if ((Get-Content -LiteralPath (Join-Path $target 'hello.txt') -Raw) -ne 'hello') { throw 'File was not readable after unlock' }
    $after = (Get-Acl -LiteralPath $target).GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
    if ($before -ne $after) { throw 'DACL did not round-trip' }
    Remove-Entry $entry.id
    if ((Get-Entries).Count -ne 0) { throw 'Entry was not removed' }
    Remove-Item -LiteralPath $script:DataFile -Force
    $legacyRecord = New-PasswordRecord 'oldpassword123'
    $legacy = [pscustomobject]@{
        id = 'legacy'; path = $target; sid = $script:MySid; sddl = $before
        salt = $legacyRecord.salt; hash = $legacyRecord.hash; iterations = $legacyRecord.iterations
        locked = $false; unlockedAt = $null; shortcut = $null
        lockOnClose = $true; lockOnSession = $false; lockOnSleep = $true; minutes = 15
    }
    $legacyJson = ConvertTo-Json -InputObject @{ version = 1; entries = @($legacy) } -Depth 8
    [System.IO.File]::WriteAllText($script:DataFile, $legacyJson, [System.Text.UTF8Encoding]::new($false))
    Initialize-GlobalConfig 'newpassword123' @{ legacy = 'oldpassword123' }
    if (-not (Test-Password 'newpassword123' (Get-Config))) { throw 'Migration did not set global password' }
    if ((Get-Entries)[0].PSObject.Properties['hash']) { throw 'Migration retained per-folder hash' }
    if ((Get-Config).minutes -ne 15 -or (Get-Config).lockOnSession) { throw 'Migration lost legacy options' }
    'PASS'
} finally {
    if ($entry) {
        $existing = @(Get-Entries | Where-Object id -eq $entry.id)[0]
        if ($existing -and $existing.locked) { Restore-OriginalAcl $existing }
    }
    $root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    foreach ($cleanupPath in @($target, $script:DataDir)) {
        $resolved = [System.IO.Path]::GetFullPath($cleanupPath)
        if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
