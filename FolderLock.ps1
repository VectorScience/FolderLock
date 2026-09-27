param(
    [string]$OpenId
)

# FolderLock is an ACL-based privacy tool. It does not encrypt file contents.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Stop'
$script:DataDir = Join-Path $env:LOCALAPPDATA 'FolderLock'
$script:DataFile = Join-Path $script:DataDir 'folders.json'
$script:MySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:Mutex = New-Object System.Threading.Mutex($false, ('Local\FolderLock-' + $script:MySid.Replace('-', '_')))
$script:Managed = @{}
$script:LastWindowCheck = Get-Date

function Show-Error([string]$message) {
    [void][System.Windows.Forms.MessageBox]::Show($message, 'FolderLock', 'OK', 'Error')
}

function Invoke-State([scriptblock]$action) {
    $acquired = $false
    try {
        try { $acquired = $script:Mutex.WaitOne(10000) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '另一个 FolderLock 操作正在进行，请稍后重试。' }
        if (-not (Test-Path -LiteralPath $script:DataDir)) {
            [void](New-Item -ItemType Directory -Path $script:DataDir -Force)
        }
        $entries = @()
        $config = $null
        if (Test-Path -LiteralPath $script:DataFile) {
            $raw = Get-Content -LiteralPath $script:DataFile -Raw -Encoding UTF8
            if ($raw.Trim()) {
                $document = ConvertFrom-Json -InputObject $raw
                $entries = @($document.entries)
                $config = $document.config
            }
        }
        $result = & $action $entries $config
        if ($null -ne $result -and $result.Save) {
            if ($result.ContainsKey('Config')) { $config = $result.Config }
            $json = ConvertTo-Json -InputObject @{ version = 2; config = $config; entries = @($result.Entries) } -Depth 8
            $temp = Join-Path $script:DataDir ([guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $temp -Destination $script:DataFile -Force
            } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        }
        return $result
    } finally { if ($acquired) { $script:Mutex.ReleaseMutex() } }
}

function Get-Entries { return @( (Invoke-State { param($items) @{ Save = $false; Entries = $items } }).Entries ) }
function Get-Config { return (Invoke-State { param($items, $config) @{ Save = $false; Entries = $items; Config = $config } }).Config }

function New-PasswordRecord([string]$password) {
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password, $salt, 310000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $hash = $kdf.GetBytes(32) } finally { $kdf.Dispose() }
    return @{ salt = [Convert]::ToBase64String($salt); hash = [Convert]::ToBase64String($hash); iterations = 310000 }
}

function Test-Password([string]$password, $entry) {
    $salt = [Convert]::FromBase64String($entry.salt)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password, $salt, [int]$entry.iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $actual = $kdf.GetBytes(32) } finally { $kdf.Dispose() }
    $expected = [Convert]::FromBase64String($entry.hash)
    if ($actual.Length -ne $expected.Length) { return $false }
    $difference = 0
    for ($i = 0; $i -lt $actual.Length; $i++) { $difference = $difference -bor ($actual[$i] -bxor $expected[$i]) }
    return ($difference -eq 0)
}

function Initialize-GlobalConfig([string]$newPassword, [hashtable]$oldPasswords = @{}) {
    Invoke-State {
        param($items, $config)
        if ($config) { throw '统一密码已经设置。' }
        foreach ($entry in $items) {
            if (-not $oldPasswords.ContainsKey($entry.id) -or -not (Test-Password $oldPasswords[$entry.id] $entry)) {
                throw "旧密码验证失败：$($entry.path)"
            }
        }
        $record = New-PasswordRecord $newPassword
        $first = @($items)[0]
        $settings = [pscustomobject]@{
            salt = $record.salt; hash = $record.hash; iterations = $record.iterations
            lockOnClose = $(if ($first) { [bool]$first.lockOnClose } else { $true })
            lockOnSession = $(if ($first) { [bool]$first.lockOnSession } else { $true })
            lockOnSleep = $(if ($first) { [bool]$first.lockOnSleep } else { $true })
            minutes = $(if ($first) { [int]$first.minutes } else { 0 })
        }
        foreach ($entry in $items) {
            foreach ($name in @('salt', 'hash', 'iterations', 'lockOnClose', 'lockOnSession', 'lockOnSleep', 'minutes')) {
                $entry.PSObject.Properties.Remove($name)
            }
        }
        @{ Save = $true; Entries = $items; Config = $settings }
    } | Out-Null
}

function Ensure-GlobalConfig {
    if (Get-Config) { return $true }
    $items = Get-Entries
    $oldPasswords = @{}
    if ($items.Count) {
        [void][System.Windows.Forms.MessageBox]::Show('检测到旧版按文件夹设置的密码。请依次输入每个旧密码，然后设置统一密码。', 'FolderLock')
        foreach ($entry in $items) {
            while ($true) {
                $old = Read-Password "旧密码：$($entry.path)"
                if ($null -eq $old) { return $false }
                if (Test-Password $old $entry) { $oldPasswords[$entry.id] = $old; break }
                Show-Error '密码错误，请重试。'
            }
        }
    }
    $newPassword = Read-Password '首次设置统一密码' $true
    if ($null -eq $newPassword) { return $false }
    Initialize-GlobalConfig $newPassword $oldPasswords
    return $true
}

function Read-Password([string]$title, [bool]$confirm = $false) {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $title
    $dialog.Size = New-Object System.Drawing.Size(380, $(if ($confirm) { 190 } else { 145 }))
    $dialog.StartPosition = 'CenterScreen'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $label = New-Object System.Windows.Forms.Label
    $label.Text = '密码'
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.AutoSize = $true
    $dialog.Controls.Add($label)
    $first = New-Object System.Windows.Forms.TextBox
    $first.Location = New-Object System.Drawing.Point(16, 37)
    $first.Width = 330
    $first.UseSystemPasswordChar = $true
    $dialog.Controls.Add($first)
    if ($confirm) {
        $again = New-Object System.Windows.Forms.TextBox
        $again.Location = New-Object System.Drawing.Point(16, 79)
        $again.Width = 330
        $again.UseSystemPasswordChar = $true
        $dialog.Controls.Add($again)
        $againLabel = New-Object System.Windows.Forms.Label
        $againLabel.Text = '再次输入'
        $againLabel.Location = New-Object System.Drawing.Point(16, 62)
        $againLabel.AutoSize = $true
        $dialog.Controls.Add($againLabel)
    }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'
    $ok.Location = New-Object System.Drawing.Point(190, $(if ($confirm) { 112 } else { 73 }))
    $dialog.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(271, $(if ($confirm) { 112 } else { 73 }))
    $dialog.Controls.Add($cancel)
    $ok.Add_Click(({
        if ($confirm -and $first.Text -ne $again.Text) {
            Show-Error '两次输入的密码不一致。'
            $again.Focus()
            return
        }
        if ($confirm -and $first.Text.Length -lt 8) {
            Show-Error '密码至少需要 8 个字符。'
            $first.Focus()
            return
        }
        $dialog.DialogResult = 'OK'
        $dialog.Close()
    }).GetNewClosure())
    if ($confirm) {
        $first.Add_KeyDown(({
            param($sender, $eventArgs)
            if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                $eventArgs.SuppressKeyPress = $true
                $again.Focus()
            }
        }).GetNewClosure())
        $again.Add_Enter(({ $dialog.AcceptButton = $ok }).GetNewClosure())
        $again.Add_Leave(({ $dialog.AcceptButton = $null }).GetNewClosure())
        $dialog.AcceptButton = $null
    } else {
        $dialog.AcceptButton = $ok
    }
    $dialog.CancelButton = $cancel
    $dialog.Add_Shown(({ $first.Focus() }).GetNewClosure())
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return $null }
        return $first.Text
    } finally { $dialog.Dispose() }
}

function Assert-SafePath([string]$path, $entries) {
    $path = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw '文件夹不存在。' }
    if ($path.StartsWith('\\')) { throw '暂不支持网络文件夹。' }
    if ($path -eq [System.IO.Path]::GetPathRoot($path).TrimEnd('\')) { throw '不能锁定磁盘根目录。' }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw '暂不支持符号链接或联接点。' }
    $blocked = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $PSScriptRoot) | Where-Object { $_ }
    foreach ($base in $blocked) {
        $base = [System.IO.Path]::GetFullPath($base).TrimEnd('\')
        if ($path.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or $base.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '不能锁定系统、用户配置或程序所在的文件夹及其上级目录。'
        }
    }
    foreach ($entry in $entries) {
        if ($path.Equals($entry.path, [StringComparison]::OrdinalIgnoreCase) -or
            $path.StartsWith($entry.path + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $entry.path.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '此文件夹与已管理的文件夹重叠。'
        }
    }
    return $path
}

function Set-LockedAcl($entry) {
    if (-not (Test-Path -LiteralPath $entry.path -PathType Container)) { throw '文件夹已移动或不存在，无法锁定。' }
    $acl = Get-Acl -LiteralPath $entry.path
    $rights = [System.Security.AccessControl.FileSystemRights]::ReadData -bor
        [System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::ExecuteFile
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $identity = New-Object System.Security.Principal.SecurityIdentifier($entry.sid)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $rights, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Deny)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $entry.path -AclObject $acl
}

function Restore-OriginalAcl($entry) {
    if (-not (Test-Path -LiteralPath $entry.path -PathType Container)) { throw '文件夹已移动或不存在，无法恢复权限。' }
    $acl = Get-Acl -LiteralPath $entry.path
    $acl.SetSecurityDescriptorSddlForm($entry.sddl, [System.Security.AccessControl.AccessControlSections]::Access)
    Set-Acl -LiteralPath $entry.path -AclObject $acl
}

function Lock-Entry([string]$id) {
    Invoke-State {
        param($items)
        $entry = @($items | Where-Object id -eq $id)[0]
        if (-not $entry) { throw '未找到该文件夹。' }
        if (-not $entry.locked) {
            Set-LockedAcl $entry
            $entry.locked = $true
            $entry.unlockedAt = $null
        }
        @{ Save = $true; Entries = $items }
    } | Out-Null
    $script:Managed.Remove($id)
}

function Unlock-Entry([string]$id, [string]$password) {
    Invoke-State {
        param($items, $config)
        $entry = @($items | Where-Object id -eq $id)[0]
        if (-not $entry) { throw '未找到该文件夹。' }
        if (-not $config -or -not (Test-Password $password $config)) { throw '密码错误。' }
        if ($entry.locked) { Restore-OriginalAcl $entry }
        $entry.locked = $false
        $entry.unlockedAt = (Get-Date).ToUniversalTime().ToString('o')
        @{ Save = $true; Entries = $items }
    } | Out-Null
}

function Add-Entry([string]$path) {
    $result = Invoke-State {
        param($items, $config)
        if (-not $config) { throw '请先设置统一密码。' }
        $safePath = Assert-SafePath $path $items
        $acl = Get-Acl -LiteralPath $safePath
        $entry = [pscustomobject]@{
            id = [guid]::NewGuid().ToString('N'); path = $safePath; sid = $script:MySid
            sddl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
            locked = $false; unlockedAt = $null; shortcut = $null
        }
        $newItems = @($items) + @($entry)
        @{ Save = $true; Entries = $newItems; Entry = $entry }
    }
    try { Lock-Entry $result.Entry.id }
    catch { throw "已保存文件夹，但锁定失败：$($_.Exception.Message)" }
    return $result.Entry
}

function Remove-Entry([string]$id) {
    Invoke-State {
        param($items)
        $entry = @($items | Where-Object id -eq $id)[0]
        if (-not $entry) { throw '未找到该文件夹。' }
        if ($entry.locked) { throw '请先解锁，再移除。' }
        $remaining = @($items | Where-Object id -ne $id)
        @{ Save = $true; Entries = $remaining }
    } | Out-Null
}

function Save-Options([bool]$close, [bool]$session, [bool]$sleep, [int]$minutes) {
    Invoke-State {
        param($items, $config)
        if (-not $config) { throw '请先设置统一密码。' }
        $config.lockOnClose = $close; $config.lockOnSession = $session
        $config.lockOnSleep = $sleep; $config.minutes = $minutes
        @{ Save = $true; Entries = $items; Config = $config }
    } | Out-Null
}

function Set-OpenShortcut($entry, [string]$shortcutPath) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -OpenId ' + $entry.id
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = '输入密码后打开此文件夹'
    $iconPath = Join-Path $PSScriptRoot 'FolderLock.ico'
    if (Test-Path -LiteralPath $iconPath) { $shortcut.IconLocation = $iconPath + ',0' }
    $shortcut.Save()
}

function New-OpenShortcut($entry) {
    $parent = Split-Path -Parent $entry.path
    $name = Split-Path -Leaf $entry.path
    $shortcutPath = Join-Path $parent ($name + ' - 解锁并打开.lnk')
    if (Test-Path -LiteralPath $shortcutPath) { throw '快捷方式已存在，请先处理同名文件。' }
    Set-OpenShortcut $entry $shortcutPath
    Invoke-State {
        param($items)
        $item = @($items | Where-Object id -eq $entry.id)[0]
        $item.shortcut = $shortcutPath
        @{ Save = $true; Entries = $items }
    } | Out-Null
    return $shortcutPath
}

function Repair-Shortcuts {
    foreach ($entry in (Get-Entries)) {
        if ($entry.shortcut -and (Test-Path -LiteralPath $entry.shortcut)) {
            try { Set-OpenShortcut $entry $entry.shortcut }
            catch { Show-Error "更新快捷方式失败：$($entry.shortcut)`n$($_.Exception.Message)" }
        }
    }
}

function Get-ExplorerPaths {
    $paths = @()
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($window in $shell.Windows()) {
            try {
                $folder = $window.Document.Folder.Self.Path
                if ($folder) { $paths += [string]$folder }
            } catch {}
        }
    } catch {}
    return $paths
}

function Test-WindowInFolder([string]$path, $windows) {
    foreach ($windowPath in $windows) {
        if ($windowPath.Equals($path, [StringComparison]::OrdinalIgnoreCase) -or
            $windowPath.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Open-Entry([string]$id) {
    $entry = @(Get-Entries | Where-Object id -eq $id)[0]
    if (-not $entry) { throw '未找到该文件夹。' }
    $password = Read-Password "解锁 $($entry.path)"
    if ($null -eq $password) { return }
    Unlock-Entry $id $password
    try { Start-Process explorer.exe -ArgumentList ('"' + $entry.path + '"') }
    catch { Show-Error "已解锁，但打开 Explorer 失败：$($_.Exception.Message)" }
    $script:Managed[$id] = @{ Opened = Get-Date; Seen = $false }
}

function Check-AutoLock {
    $entries = Get-Entries
    $config = Get-Config
    if (-not $config) { return }
    $windows = Get-ExplorerPaths
    foreach ($entry in $entries) {
        if ($entry.locked) { $script:Managed.Remove($entry.id); continue }
        $opened = [datetime]::MinValue
        if ($entry.unlockedAt) { $opened = [datetime]::Parse($entry.unlockedAt).ToLocalTime() }
        $minutes = [int]$config.minutes
        $expired = ($minutes -gt 0 -and ((Get-Date) - $opened).TotalMinutes -ge $minutes)
        $watch = $script:Managed[$entry.id]
        $closed = $false
        if ($watch -and $config.lockOnClose) {
            $visible = Test-WindowInFolder $entry.path $windows
            if ($visible) { $watch.Seen = $true }
            if ($watch.Seen -and -not $visible) { $closed = $true }
        }
        if ($expired -or $closed) {
            try { Lock-Entry $entry.id }
            catch { Show-Error "自动锁定失败：$($entry.path)`n$($_.Exception.Message)" }
        }
    }
}

function Lock-OnEvent([string]$kind) {
    $config = Get-Config
    if (-not $config) { return }
    foreach ($entry in (Get-Entries)) {
        if ($entry.locked) { continue }
        if (($kind -eq 'session' -and $config.lockOnSession) -or ($kind -eq 'sleep' -and $config.lockOnSleep)) {
            try { Lock-Entry $entry.id }
            catch { Show-Error "系统事件触发锁定失败：$($entry.path)`n$($_.Exception.Message)" }
        }
    }
}

function Start-SystemWatch {
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -SourceIdentifier 'FolderLock.Session' | Out-Null
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName PowerModeChanged -SourceIdentifier 'FolderLock.Power' | Out-Null
}

function Read-SystemEvents {
    foreach ($event in @(Get-Event -SourceIdentifier 'FolderLock.Session' -ErrorAction SilentlyContinue)) {
        if ($event.SourceEventArgs.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) { Lock-OnEvent 'session' }
        Remove-Event -EventIdentifier $event.EventIdentifier
    }
    foreach ($event in @(Get-Event -SourceIdentifier 'FolderLock.Power' -ErrorAction SilentlyContinue)) {
        if ($event.SourceEventArgs.Mode -eq [Microsoft.Win32.PowerModes]::Suspend) { Lock-OnEvent 'sleep' }
        Remove-Event -EventIdentifier $event.EventIdentifier
    }
}

function Stop-SystemWatch {
    Unregister-Event -SourceIdentifier 'FolderLock.Session' -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'FolderLock.Power' -ErrorAction SilentlyContinue
}

if ($OpenId) {
    try {
        Open-Entry $OpenId
        if (-not $script:Managed.ContainsKey($OpenId)) { exit 0 }
        Start-SystemWatch
        $context = New-Object System.Windows.Forms.ApplicationContext
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 5000
        $timer.Add_Tick({
            try {
                Read-SystemEvents
                Check-AutoLock
                $entry = @(Get-Entries | Where-Object id -eq $OpenId)[0]
                if (-not $entry -or $entry.locked) { $timer.Stop(); $context.ExitThread() }
            } catch { Show-Error $_.Exception.Message }
        })
        $timer.Start()
        [System.Windows.Forms.Application]::Run($context)
    } catch { Show-Error $_.Exception.Message }
    finally { Stop-SystemWatch }
    exit
}

try {
    foreach ($entry in (Get-Entries)) {
        if (-not $entry.locked) { Lock-Entry $entry.id }
    }
    if (-not (Ensure-GlobalConfig)) { $script:Mutex.Dispose(); return }
    Repair-Shortcuts
} catch {
    Show-Error $_.Exception.Message
    $script:Mutex.Dispose()
    return
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'FolderLock · 文件夹访问锁'
$form.Size = New-Object System.Drawing.Size(850, 540)
$form.MinimumSize = New-Object System.Drawing.Size(750, 500)
$form.StartPosition = 'CenterScreen'
$iconPath = Join-Path $PSScriptRoot 'FolderLock.ico'
if (Test-Path -LiteralPath $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }
$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false
$list.Location = New-Object System.Drawing.Point(16, 16)
$list.Size = New-Object System.Drawing.Size(800, 300)
$list.Anchor = 'Top,Left,Right,Bottom'
[void]$list.Columns.Add('文件夹', 590)
[void]$list.Columns.Add('状态', 130)
$form.Controls.Add($list)
$list.AllowDrop = $true

function Add-Button([string]$label, [int]$x, [int]$y, [scriptblock]$click) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $label
    $button.Location = New-Object System.Drawing.Point($x, $y)
    $button.Size = New-Object System.Drawing.Size(128, 32)
    $button.Anchor = 'Bottom,Left'
    $button.Add_Click($click)
    $form.Controls.Add($button)
    return $button
}

function Selected-Id { if ($list.SelectedItems.Count) { return [string]$list.SelectedItems[0].Tag }; return $null }
function Refresh-List {
    $selected = Selected-Id
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($entry in (Get-Entries)) {
            $row = New-Object System.Windows.Forms.ListViewItem($entry.path)
            [void]$row.SubItems.Add($(if ($entry.locked) { '已锁定' } else { '已解锁' }))
            $row.Tag = $entry.id
            [void]$list.Items.Add($row)
            if ($entry.id -eq $selected) { $row.Selected = $true }
        }
    } finally { $list.EndUpdate() }
}

$add = Add-Button '添加文件夹' 16 332 {
    try {
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = '选择要管理的文件夹'
        if ($picker.ShowDialog() -ne 'OK') { return }
        $entry = Add-Entry $picker.SelectedPath
        try { $shortcut = New-OpenShortcut $entry }
        catch { Show-Error "文件夹已锁定，但创建快捷方式失败：$($_.Exception.Message)" }
        Refresh-List
    } catch { Show-Error $_.Exception.Message }
}
$list.Add_DragEnter({
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$list.Add_DragDrop({
    param($sender, $eventArgs)
    foreach ($path in @($eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))) {
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw '只能拖入文件夹。' }
            $entry = Add-Entry $path
            try { [void](New-OpenShortcut $entry) }
            catch { Show-Error "文件夹已锁定，但创建快捷方式失败：$($_.Exception.Message)" }
        } catch { Show-Error "$path`n$($_.Exception.Message)" }
    }
    Refresh-List
})
$open = Add-Button '解锁并打开' 153 332 {
    try { $id = Selected-Id; if ($id) { Open-Entry $id; Refresh-List } }
    catch { Show-Error $_.Exception.Message }
}
$lock = Add-Button '立即锁定' 290 332 {
    try { $id = Selected-Id; if ($id) { Lock-Entry $id; Refresh-List } }
    catch { Show-Error $_.Exception.Message }
}
$remove = Add-Button '移除管理' 427 332 {
    try {
        $id = Selected-Id
        if (-not $id) { return }
        $entry = @(Get-Entries | Where-Object id -eq $id)[0]
        Remove-Entry $id
        if ($entry.shortcut -and (Test-Path -LiteralPath $entry.shortcut)) { Remove-Item -LiteralPath $entry.shortcut -Force }
        Refresh-List
    } catch { Show-Error $_.Exception.Message }
}

$closeBox = New-Object System.Windows.Forms.CheckBox
$closeBox.Text = 'Explorer 窗口关闭后锁定'; $closeBox.AutoSize = $true
$closeBox.Location = New-Object System.Drawing.Point(16, 391); $closeBox.Anchor = 'Bottom,Left'
$form.Controls.Add($closeBox)
$sessionBox = New-Object System.Windows.Forms.CheckBox
$sessionBox.Text = 'Windows 锁屏后锁定'; $sessionBox.AutoSize = $true
$sessionBox.Location = New-Object System.Drawing.Point(230, 391); $sessionBox.Anchor = 'Bottom,Left'
$form.Controls.Add($sessionBox)
$sleepBox = New-Object System.Windows.Forms.CheckBox
$sleepBox.Text = '睡眠前锁定'; $sleepBox.AutoSize = $true
$sleepBox.Location = New-Object System.Drawing.Point(420, 391); $sleepBox.Anchor = 'Bottom,Left'
$form.Controls.Add($sleepBox)
$minutesLabel = New-Object System.Windows.Forms.Label
$minutesLabel.Text = '最长解锁时间（分钟）'; $minutesLabel.AutoSize = $true
$minutesLabel.Location = New-Object System.Drawing.Point(16, 425); $minutesLabel.Anchor = 'Bottom,Left'
$form.Controls.Add($minutesLabel)
$unlimitedBox = New-Object System.Windows.Forms.CheckBox
$unlimitedBox.Text = '无限制'; $unlimitedBox.AutoSize = $true
$unlimitedBox.Location = New-Object System.Drawing.Point(246, 423); $unlimitedBox.Anchor = 'Bottom,Left'
$form.Controls.Add($unlimitedBox)
$minutesBox = New-Object System.Windows.Forms.NumericUpDown
$minutesBox.Minimum = 1; $minutesBox.Maximum = 1440; $minutesBox.Value = 10
$minutesBox.Location = New-Object System.Drawing.Point(174, 422); $minutesBox.Width = 60; $minutesBox.Anchor = 'Bottom,Left'
$form.Controls.Add($minutesBox)
$unlimitedBox.Add_CheckedChanged({ $minutesBox.Enabled = -not $unlimitedBox.Checked })
$save = Add-Button '保存全局设置' 340 417 {
    try {
        $minutes = $(if ($unlimitedBox.Checked) { 0 } else { [int]$minutesBox.Value })
        Save-Options $closeBox.Checked $sessionBox.Checked $sleepBox.Checked $minutes
    } catch { Show-Error $_.Exception.Message }
}
$config = Get-Config
$closeBox.Checked = [bool]$config.lockOnClose
$sessionBox.Checked = [bool]$config.lockOnSession
$sleepBox.Checked = [bool]$config.lockOnSleep
$unlimitedBox.Checked = ([int]$config.minutes -eq 0)
$minutesBox.Value = [Math]::Max(1, [Math]::Min(1440, [int]$config.minutes))
$minutesBox.Enabled = -not $unlimitedBox.Checked
$hint = New-Object System.Windows.Forms.Label
$hint.Text = '将文件夹拖入上方列表，或点击“添加文件夹”。自动锁定设置对所有文件夹生效。'
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(16, 464); $hint.Anchor = 'Bottom,Left'
$form.Controls.Add($hint)

try {
    Refresh-List
    Start-SystemWatch
    $tick = New-Object System.Windows.Forms.Timer
    $tick.Interval = 5000
    $tick.Add_Tick({
        try {
            Read-SystemEvents
            Check-AutoLock
            Refresh-List
        } catch { Show-Error $_.Exception.Message }
    })
    $tick.Start()
    [void]$form.ShowDialog()
} catch { Show-Error $_.Exception.Message }
finally {
    if ($tick) { $tick.Stop(); $tick.Dispose() }
    Stop-SystemWatch
    foreach ($entry in (Get-Entries)) {
        if (-not $entry.locked) { try { Lock-Entry $entry.id } catch { Show-Error "退出时锁定失败：$($entry.path)`n$($_.Exception.Message)" } }
    }
    $form.Dispose()
    $script:Mutex.Dispose()
}
