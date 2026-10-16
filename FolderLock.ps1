param([switch]$LibraryOnly, [string]$RclonePath, [string]$OpenPath, [string]$LauncherPath, [switch]$RestoreEntries, [string]$EncryptPath, [string]$UnlockRequestPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
if (-not ('FolderLock.VaultEngine' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'VaultEngine.cs') -ReferencedAssemblies System.Web.Extensions,System.Core }
if (-not $RclonePath) {
    foreach ($candidate in @((Join-Path $PSScriptRoot 'rclone.exe'), (Join-Path $PSScriptRoot 'build\tools\rclone.exe'))) {
        if (Test-Path -LiteralPath $candidate) { $RclonePath = $candidate; break }
    }
}
function Show-Error([string]$message) { [void][System.Windows.Forms.MessageBox]::Show($message, 'FolderLock', 'OK', 'Error') }
function Read-Password([string]$title, [bool]$confirm = $false) {
    $dialog = New-Object System.Windows.Forms.Form
    if($form -and $form.Icon){$dialog.Icon=$form.Icon}
    $dialog.Text = $title; $dialog.ClientSize = New-Object System.Drawing.Size(390, $(if ($confirm) { 190 } else { 125 }))
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'; $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $label = New-Object System.Windows.Forms.Label
    $label.Text = '密码（至少 8 个字符）'; $label.SetBounds(16, 12, 350, 22); $dialog.Controls.Add($label)
    $first = New-Object System.Windows.Forms.TextBox
    $first.UseSystemPasswordChar = $true; $first.SetBounds(16, 36, 355, 26); $dialog.Controls.Add($first)
    $again = New-Object System.Windows.Forms.TextBox
    if ($confirm) {
        $label2 = New-Object System.Windows.Forms.Label
        $label2.Text = '再次输入密码'; $label2.SetBounds(16, 69, 350, 22); $dialog.Controls.Add($label2)
        $again.UseSystemPasswordChar = $true; $again.SetBounds(16, 93, 355, 26); $dialog.Controls.Add($again)
    }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'; $ok.SetBounds(195, $(if ($confirm) { 144 } else { 82 }), 85, 30); $dialog.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.DialogResult = 'Cancel'; $cancel.SetBounds(286, $ok.Top, 85, 30); $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok; $dialog.CancelButton = $cancel
    $ok.Add_Click(({
        if ($first.Text.Length -lt 8) { Show-Error '密码至少需要 8 个字符。'; return }
        if ($confirm -and $first.Text -cne $again.Text) { Show-Error '两次输入的密码不一致。'; return }
        $dialog.DialogResult = 'OK'; $dialog.Close()
    }).GetNewClosure())
    try { if ($dialog.ShowDialog() -eq 'OK') { return $first.Text }; return $null }
    finally { $first.Clear(); $again.Clear(); $dialog.Dispose() }
}
function Test-WinFsp { return (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\WinFsp') -or (Test-Path 'HKLM:\SOFTWARE\WinFsp') }
function Register-FolderContextMenu([string]$launcher, [string]$registryPath='Software\Classes\Directory\shell\FolderLock.Encrypt') {
    if(-not $launcher -or -not(Test-Path -LiteralPath $launcher)){throw '找不到 FolderLock.exe，请完整解压后运行。'}
    $quoted=[FolderLock.VaultEngine]::Quote([IO.Path]::GetFullPath($launcher))
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
    try {
        $key.SetValue('', '使用 FolderLock 加密此文件夹')
        $brandIcon=Join-Path (Split-Path $launcher) 'FolderLock-brand-v1.ico'
        $key.SetValue('Icon', $(if(Test-Path -LiteralPath $brandIcon){[FolderLock.VaultEngine]::Quote($brandIcon)+',0'}else{$quoted+',0'}))
        $key.SetValue('MultiSelectModel', 'Single')
        $command=$key.CreateSubKey('command')
        try {$command.SetValue('', $quoted+' --encrypt "%1"')} finally {$command.Dispose()}
    } finally {$key.Dispose()}
}
function Register-EntryStartup([string]$launcher, [string]$registryPath='Software\Microsoft\Windows\CurrentVersion\Run') {
    if(-not $launcher -or -not(Test-Path -LiteralPath $launcher)){throw '无法登记开机入口恢复：找不到 FolderLock.exe。'}
    $command=[FolderLock.VaultEngine]::Quote([IO.Path]::GetFullPath($launcher))+' --restore-entries'
    if($command.Length -gt 260){throw '程序路径太长，无法登记开机恢复。请把程序放到较短的固定目录。'}
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
    try {$key.SetValue('FolderLockEntryRestore',$command,[Microsoft.Win32.RegistryValueKind]::String)} finally {$key.Dispose()}
}
function Restore-EntryHistory([string]$history, [string]$launcher, [string]$logFile) {
    if(-not(Test-Path -LiteralPath $history)){return 0}
    $failures=New-Object 'System.Collections.Generic.List[string]'; $restored=0
    try {
        # Windows PowerShell 5.1 emits the JSON array as a single pipeline object.
        # Assign first so @() enumerates its paths instead of wrapping a nested array.
        $loaded=Get-Content -LiteralPath $history -Raw -Encoding UTF8 | ConvertFrom-Json
        $paths=@($loaded)
        foreach($path in $paths) {
            try {if([FolderLock.VaultEngine]::RestoreEntry([string]$path,$launcher)){$restored++}}
            catch {$failures.Add(([string]$path+': '+$_.Exception.Message))}
        }
    } catch {$failures.Add($_.Exception.Message)}
    if($logFile) {
        [void][IO.Directory]::CreateDirectory((Split-Path $logFile))
        [IO.File]::WriteAllLines($logFile,@($failures),[Text.UTF8Encoding]::new($false))
    }
    return $restored
}
function Read-DownloadUnlockRequest([string]$file) {
    $file=[IO.Path]::GetFullPath($file)
    if($file.StartsWith('\\') -or ([IO.FileInfo]$file).Length -gt 16384){throw '下载解锁请求文件无效。'}
    $request=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if($request.version -ne 1 -or $request.status -ne 'pending' -or [long]$request.expires_at -lt $now -or [long]$request.expires_at -gt ($now+600)){throw '下载解锁请求已取消或过期。'}
    $request.root=[FolderLock.VaultEngine]::Normalize([string]$request.root)
    if(-not(Test-Path -LiteralPath ($request.root+'.folderlock\portal.json'))){throw '下载目标不是已登记的原路径保险箱。'}
    return $request
}
function Complete-DownloadUnlock([string]$state,[string]$message='') {
    if(-not $script:downloadUnlockRequest){return}
    $file=$script:downloadUnlockRequest
    $script:downloadUnlockRequest=$null
    $request=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if($request.status -ne 'pending'){return}
    $request.status=$state
    $request | Add-Member -NotePropertyName message -NotePropertyValue $message -Force
    $temporary=$file+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($request | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temporary,$file,[System.Management.Automation.Language.NullString]::Value)
    } finally {if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
if ($LibraryOnly) { return }
if(-not $LauncherPath) {
    foreach($candidate in @((Join-Path $PSScriptRoot 'FolderLock.exe'),(Join-Path $PSScriptRoot 'dist\FolderLock.exe'))) {
        if(Test-Path -LiteralPath $candidate){$LauncherPath=$candidate; break}
    }
}
if($RestoreEntries) {
    Restore-EntryHistory (Join-Path $env:LOCALAPPDATA 'FolderLock\vaults.json') $LauncherPath (Join-Path $env:LOCALAPPDATA 'FolderLock\entry-restore.log') | Out-Null
    return
}
$script:requestDirectory=Join-Path $PSScriptRoot 'open-requests'
function Queue-Open([string]$path, [switch]$Encrypt, [switch]$DownloadUnlock) {
    [void][IO.Directory]::CreateDirectory($script:requestDirectory)
    $request=Join-Path $script:requestDirectory ([guid]::NewGuid().ToString('N')+$(if($Encrypt){'.encrypt.request'}elseif($DownloadUnlock){'.unlock.request'}else{'.request'}))
    [IO.File]::WriteAllText(($request+'.new'),$path,[Text.UTF8Encoding]::new($false)); [IO.File]::Move(($request+'.new'),$request)
}
$created=$false
$script:uiMutex=[Threading.Mutex]::new($true,('Local\FolderLock2UI-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value),[ref]$created)
if(-not $created) {if($UnlockRequestPath){Queue-Open $UnlockRequestPath -DownloadUnlock}elseif($EncryptPath){Queue-Open $EncryptPath -Encrypt}else{Queue-Open $OpenPath}; $script:uiMutex.Dispose(); return}
$script:downloadUnlockRequest=$null
$script:downloadUnlockProtocol=Join-Path $PSScriptRoot 'download-unlock-v1.pid'
[IO.File]::WriteAllText($script:downloadUnlockProtocol,[string]$PID)
$script:mounts = @{}; $script:job = $null; $script:pending = $null; $script:engine = $null
$script:lockWork = $null; $script:closeRequested = $false
$script:openWork = $null
$script:historyFile = Join-Path $env:LOCALAPPDATA 'FolderLock\vaults.json'
$script:paths = @()
if (Test-Path -LiteralPath $script:historyFile) {
    try { $loaded = Get-Content -LiteralPath $script:historyFile -Raw -Encoding UTF8 | ConvertFrom-Json; $script:paths = @($loaded) }
    catch { Show-Error '最近目录记录无法读取。可以直接粘贴保险箱路径打开，密文不受影响。' }
}
function Add-History([string]$path) {
    $script:paths = @(@($script:paths) + $path | Select-Object -Unique)
    [void][System.IO.Directory]::CreateDirectory((Split-Path $script:historyFile))
    $temp = $script:historyFile + '.new'
    [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject @($script:paths)), [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $script:historyFile) { [System.IO.File]::Replace($temp, $script:historyFile, [System.Management.Automation.Language.NullString]::Value) }
    else { [System.IO.File]::Move($temp, $script:historyFile) }
}
function Enable-EntryRecovery {
    try {Register-EntryStartup $LauncherPath}
    catch {Show-Error ('文件仍可正常解锁，但开机入口恢复未启用：'+$_.Exception.Message)}
}
function Enable-ContextMenu {
    try {Register-FolderContextMenu $LauncherPath}
    catch {$status.Text='右键菜单未登记，可点击“安装 / 更新右键菜单”重试：'+$_.Exception.Message}
}
function Get-Engine {
    if (-not $RclonePath -or -not (Test-Path -LiteralPath $RclonePath)) { throw '缺少 rclone.exe。请完整解压 2.4 ZIP 包，或运行 Prepare-Dependencies.ps1。' }
    if (-not $script:engine) { $script:engine = New-Object FolderLock.VaultEngine($RclonePath) }; return $script:engine
}
function Assert-NotLegacy([string]$path) {
    $file = Join-Path $env:LOCALAPPDATA 'FolderLock\folders.json'
    if (-not (Test-Path -LiteralPath $file)) { return }
    $old = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $old.entries) {
        $other = [System.IO.Path]::GetFullPath($entry.path).TrimEnd('\')
        if ($path -ieq $other -or $path.StartsWith($other + '\', [StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '此目录仍由旧版 ACL 管理。请点击“旧版 ACL 恢复”，解锁并移除管理后再加密。'
        }
    }
}
$form = New-Object System.Windows.Forms.Form
$iconFile=Join-Path $PSScriptRoot 'FolderLock.ico'
if(-not(Test-Path -LiteralPath $iconFile)){$iconFile=Join-Path $PSScriptRoot 'build\FolderLock.ico'}
if(Test-Path -LiteralPath $iconFile){$form.Icon=[Drawing.Icon]::new($iconFile,32,32)}
$form.Text = 'FolderLock 2.4.2 · 文件夹加密'; $form.ClientSize = New-Object System.Drawing.Size(870, 570)
$form.MinimumSize = $form.Size; $form.StartPosition = 'CenterScreen'; $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$label = New-Object System.Windows.Forms.Label
$label.Text = '文件夹路径'; $label.SetBounds(20, 18, 130, 24); $form.Controls.Add($label)
$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.SetBounds(20, 46, 700, 28); $pathBox.AccessibleName = '粘贴文件夹完整路径'; $form.Controls.Add($pathBox)
function Button([string]$text, [int]$x, [int]$y, [int]$width, [scriptblock]$action) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.SetBounds($x, $y, $width, 34); $b.Add_Click($action); $form.Controls.Add($b); return $b
}
$browse = Button '浏览…' 734 43 116 {
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    try { if ($picker.ShowDialog() -eq 'OK') { $pathBox.Text = $picker.SelectedPath } } finally { $picker.Dispose() }
}
$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.SetBounds(20, 94, 830, 222)
[void]$list.Columns.Add('访问目录（密文存于同盘相邻存储目录）', 600); [void]$list.Columns.Add('状态', 205); $form.Controls.Add($list)
$list.Add_SelectedIndexChanged({ if ($list.SelectedItems.Count) { $pathBox.Text = $list.SelectedItems[0].Text } })
function Refresh-List {
    $list.Items.Clear()
    foreach ($path in $script:paths) {
        $row = New-Object System.Windows.Forms.ListViewItem([string]$path); $state = '未完成 / 需继续'
        try {
            if ([FolderLock.VaultEngine]::Read($path).State -eq 'ready') { $state = '已加密（未挂载）' }
            if ([FolderLock.VaultEngine]::HasPlaintext($path)) { $state = '含明文 / 未完成' }
            if ([FolderLock.VaultEngine]::HasWriteCache($path)) { $state = '写缓存待恢复 / 未锁定' }
            if ($script:mounts.ContainsKey($path)) { $state = '读写访问 ' + $script:mounts[$path].Drive }
            if ($script:job -and $script:jobPath -eq $path) { $state = '正在转换' }
        } catch { $state = '配置不存在 / 无法读取' }
        [void]$row.SubItems.Add($state); [void]$list.Items.Add($row)
    }
}
function Current-Path { return [FolderLock.VaultEngine]::Normalize($pathBox.Text) }
$encrypt = Button '加密 / 继续加密' 20 334 155 {
    $script:prompting=$true
    try {
        $root = Current-Path; Assert-NotLegacy $root
        if ($script:mounts.ContainsKey($root)) { throw '请先锁定此目录。' }
        $engine = Get-Engine
        if (-not (Test-WinFsp)) { throw '请先点击“准备挂载组件”安装 WinFsp，再进行加密。' }
        $exists = Test-Path -LiteralPath (Join-Path ([FolderLock.VaultEngine]::StoragePath($root)) 'vault.json')
        $password = Read-Password $(if ($exists) { '输入原密码，继续加密' } else { '设置此目录的加密密码' }) (-not $exists)
        if ($null -eq $password) { return }
        Add-History $root; $script:jobPath = $root; $script:job = $engine.BeginConvert($root, $password, $LauncherPath); $password = $null
        Set-Busy $true; Refresh-List
    } catch { Show-Error $_.Exception.Message } finally {$script:prompting=$false}
}
$driveLabel = New-Object System.Windows.Forms.Label
$driveLabel.Text = '位置'; $driveLabel.SetBounds(188, 342, 40, 24); $form.Controls.Add($driveLabel)
$drive = New-Object System.Windows.Forms.ComboBox
$drive.DropDownStyle = 'DropDownList'; $drive.SetBounds(230, 337, 66, 28)
[void]$drive.Items.Add('原路径')
foreach ($letter in 90..68) { [void]$drive.Items.Add(([char]$letter).ToString() + ':') }; $drive.SelectedIndex = 0; $form.Controls.Add($drive)
$unlock = Button '解锁并打开（可读写）' 310 334 190 {
    $script:prompting=$true
    try {
        $root = Current-Path
        if ($script:mounts.ContainsKey($root)) {
            if($script:downloadUnlockRequest){Complete-DownloadUnlock 'ready'}else{Start-Process explorer.exe -ArgumentList ($script:mounts[$root].Drive + '\')}
            return
        }
        if (-not (Test-WinFsp)) { throw '未安装 WinFsp，请点击“准备挂载组件”。' }
        $password = Read-Password $(if($script:downloadUnlockRequest){'下载器请求保存：请输入此目录密码'}else{'输入此目录的加密密码'})
        if ($null -eq $password) { Complete-DownloadUnlock 'cancelled' '已取消解锁，下载数据保留。'; return }
        if($script:downloadUnlockRequest){[void](Read-DownloadUnlockRequest $script:downloadUnlockRequest)}
        if($drive.SelectedItem -eq '原路径') {$script:openWork=(Get-Engine).BeginOpenOriginal($root,$password,$LauncherPath)}
        else {$script:openWork = (Get-Engine).BeginOpen($root, $password, [string]$drive.SelectedItem)}
        $script:pendingRoot = $root; $script:pendingAt = Get-Date; $password = $null
        $status.Text = '正在挂载…'; Set-Busy $true
    } catch { Complete-DownloadUnlock 'error' $_.Exception.Message; Show-Error $_.Exception.Message } finally {$script:prompting=$false}
}
function Start-DownloadUnlock([string]$file) {
    $request=Read-DownloadUnlockRequest $file
    $script:downloadUnlockRequest=[IO.Path]::GetFullPath($file)
    $pathBox.Text=$request.root;$drive.SelectedIndex=0
    $form.WindowState='Normal';$form.Show();[void]$form.Activate()
    $unlock.PerformClick()
}
function Lock-All {
    if ($script:lockWork -or $script:mounts.Count -eq 0) { return }
    $script:lockWork = [FolderLock.Mount]::BeginLockAll([FolderLock.Mount[]]@($script:mounts.Values))
    Set-Busy $true; $status.Text = '等待文件关闭并将修改加密保存，完成前请勿强制退出。'
}
$lock = Button '安全锁定全部' 514 334 115 { Lock-All }
$cancel = Button '暂停 / 取消' 643 334 115 {
    if ($script:job) { $script:job.CancelRequested = $true; $status.Text = '正在安全停止；当前明文会保留，稍后可继续。' }
    if ($script:lockWork) { $script:lockWork.CancelRequested = $true; $script:closeRequested = $false }
}; $cancel.Enabled = $false
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.SetBounds(20, 383, 830, 12); $form.Controls.Add($progress)
$status = New-Object System.Windows.Forms.Label
$status.Text = '粘贴路径后点击“加密”。首次转换需额外容纳最大的单个文件。'; $status.SetBounds(20, 408, 830, 45); $form.Controls.Add($status)
$hint = New-Object System.Windows.Forms.Label
$hint.Text = "默认在原目录读写，下载器无需改路径；锁定后双击目录内的解锁快捷方式。`r`n下载/合并完成后安全锁定；锁定期间写入会失败。异常退出后重新解锁恢复写缓存。"
$hint.SetBounds(20, 460, 830, 48); $form.Controls.Add($hint)
$setup = Button '准备挂载组件' 20 516 155 {
    $setupPath = Join-Path $PSScriptRoot 'Prepare-Dependencies.ps1'
    Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $setupPath + '" -InstallWinFsp -RclonePath "' + $RclonePath + '"') -WindowStyle Hidden
    $status.Text = '依赖准备程序已启动；安装 WinFsp 时会出现 Windows 安装确认。'
}
$legacy = Button '旧版 ACL 恢复' 190 516 155 {
    $legacyPath = Join-Path $PSScriptRoot 'Legacy-FolderLock.ps1'
    Start-Process powershell.exe -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $legacyPath + '"') -WindowStyle Hidden
}
$import = Button '导入已有密文…' 360 516 160 {
    $script:prompting=$true
    try {
        if(-not(Test-WinFsp)){throw '请先准备挂载组件，安装 WinFsp。'}
        $storage=$pathBox.Text.Trim().Trim('"')
        if(-not(Test-Path -LiteralPath (Join-Path $storage 'vault.json') -ErrorAction SilentlyContinue)) {
            $picker=New-Object System.Windows.Forms.FolderBrowserDialog
            $picker.Description='选择完整的 Private.folderlock 密文存储目录'
            try {if($picker.ShowDialog() -ne 'OK'){return};$storage=$picker.SelectedPath} finally {$picker.Dispose()}
        }
        $root=[FolderLock.VaultEngine]::ImportRoot($storage)
        if($script:mounts.ContainsKey($root)){throw '此目录已经解锁，请先安全锁定。'}
        $password=Read-Password '输入此密文目录的原密码'
        if($null -eq $password){return}
        $script:openWork=(Get-Engine).BeginImportOriginal($storage,$password,$LauncherPath);$password=$null
        $script:pendingRoot=$root;$script:pendingAt=Get-Date;$pathBox.Text=$root;$drive.SelectedIndex=0
        $status.Text='正在验证密码并重建本机入口…';Set-Busy $true
    } catch {Show-Error $_.Exception.Message} finally {$script:prompting=$false}
}
$contextMenu = Button '安装 / 更新右键菜单' 540 516 310 { Enable-ContextMenu; }
function Set-Busy([bool]$busy) {
    $busy = $busy -or $null -ne $script:job -or $null -ne $script:lockWork -or $null -ne $script:pending -or $null -ne $script:openWork
    foreach ($control in @($encrypt, $unlock, $browse, $pathBox, $drive, $setup, $legacy, $import, $list)) { $control.Enabled = -not $busy }
    $cancel.Enabled = $busy -and ($null -ne $script:job -or $null -ne $script:lockWork); $progress.Style = $(if ($busy) { 'Marquee' } else { 'Blocks' })
}
$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 250
$timer.Add_Tick({
    try {
        if ($script:job) {
            $status.Text = $script:job.Message
            if ($script:job.Done) {
                $errorText = $script:job.Error; $paused = $script:job.CancelRequested; $script:job = $null; Set-Busy $false; Refresh-List
                if ($errorText) { $status.Text = '未完成：仍可能有明文，请处理错误后继续加密。'; Show-Error $errorText }
                elseif ($paused) { $status.Text = '已暂停，仍有明文。使用原密码“继续加密”即可恢复。' }
                else { Enable-EntryRecovery; $status.Text = '加密完成并已逐文件验证。登录 Windows 时会自动修复锁入口。' }
            }
        }
        if ($script:openWork) {
            $status.Text = $script:openWork.Message
            if ($script:openWork.Done) {
                $openError = $script:openWork.Error; $script:pending = $script:openWork.OpenedMount; $script:openWork = $null; $script:pendingAt = Get-Date
                if ($openError) { Set-Busy $false; Refresh-List; $status.Text = '解锁未完成；原目录及恢复缓存已保留。'; throw $openError }
            }
        }
        if ($script:pending) {
            if (-not $script:pending.Alive) { $failure = $script:pending.Failure; $script:pending.Abort(); $script:pending = $null; Set-Busy $false; throw $failure }
            if (Test-Path ($script:pending.Drive + '\')) {
                $script:mounts[$script:pendingRoot] = $script:pending; $script:pending = $null
                Add-History $script:pendingRoot; Enable-EntryRecovery; Set-Busy $false; Refresh-List
                if($script:downloadUnlockRequest){Complete-DownloadUnlock 'ready'}else{Start-Process explorer.exe -ArgumentList ($script:mounts[$script:pendingRoot].Drive + '\')}
                $status.Text = '已解锁，可读写；使用“安全锁定”提交修改并清理写缓存。'
            } elseif (((Get-Date) - $script:pendingAt).TotalSeconds -gt 30) {
                $script:pending.Abort(); $script:pending = $null; Set-Busy $false; throw '挂载超时，请检查 WinFsp 和盘符。'
            }
        }
        if ($script:lockWork) {
            $status.Text = $script:lockWork.Message
            if ($script:lockWork.Done) {
                $lockError = $script:lockWork.Error; $script:lockWork = $null
                foreach ($root in @($script:mounts.Keys)) {
                    if ($script:mounts[$root].Closed) { $script:mounts.Remove($root) }
                    elseif (-not $script:mounts[$root].Attached) { $script:mounts[$root].Abort(); $script:mounts.Remove($root) }
                }
                Set-Busy $false; Refresh-List
                if ($lockError) { $script:closeRequested = $false; $status.Text = '尚未安全锁定；缓存已保留，请处理后重试。'; Show-Error $lockError }
                else { $status.Text = '已锁定：修改已加密保存，临时写缓存已清理。'; if ($script:closeRequested) { $form.Close() } }
            }
        } else {
            foreach ($root in @($script:mounts.Keys)) {
                if (-not $script:mounts[$root].Alive) { $script:mounts[$root].Abort(); $script:mounts.Remove($root); Refresh-List; $status.Text = '挂载异常退出：写缓存可能尚未提交，请重新解锁恢复。' }
            }
        }
        if(-not $script:prompting -and -not $script:job -and -not $script:openWork -and -not $script:pending -and -not $script:lockWork -and (Test-Path -LiteralPath $script:requestDirectory)) {
            $request=Get-ChildItem -LiteralPath $script:requestDirectory -Filter '*.request' -File | Sort-Object LastWriteTimeUtc | Select-Object -First 1
            if($request) {
                $target=[IO.File]::ReadAllText($request.FullName,[Text.Encoding]::UTF8); [IO.File]::Delete($request.FullName)
                $form.WindowState='Normal'; $form.Show(); [void]$form.Activate()
                if($target){if($request.Name.EndsWith('.unlock.request')){Start-DownloadUnlock $target}else{$pathBox.Text=$target; $drive.SelectedIndex=0; if($request.Name.EndsWith('.encrypt.request')){$encrypt.PerformClick()}else{$unlock.PerformClick()}}}
            }
        }
        foreach ($event in @(Get-Event -SourceIdentifier FolderLock2.Session -ErrorAction SilentlyContinue)) {
            if ($event.SourceEventArgs.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) { Lock-All }
            Remove-Event -EventIdentifier $event.EventIdentifier
        }
    } catch { Complete-DownloadUnlock 'error' $_.Exception.Message; Show-Error $_.Exception.Message }
})
$form.Add_FormClosing({ param($sender, $eventArgs)
    if ($script:job) { $script:job.CancelRequested = $true; $eventArgs.Cancel = $true; $status.Text = '正在安全暂停转换。完成后可关闭。' }
    if ($script:pending) { $eventArgs.Cancel = $true; $status.Text = '请等待挂载完成，再安全锁定退出。' }
    if ($script:openWork) { $eventArgs.Cancel = $true; $status.Text = '正在验证或恢复缓存，请完成后再安全退出。' }
    if ($script:mounts.Count -gt 0 -or $script:lockWork) { $eventArgs.Cancel = $true; $script:closeRequested = $true; Lock-All }
})
if ($OpenPath) { $pathBox.Text = $OpenPath }
if ($EncryptPath) { $pathBox.Text = $EncryptPath }
$form.Add_Shown({if($UnlockRequestPath){try{Start-DownloadUnlock $UnlockRequestPath}catch{Show-Error $_.Exception.Message}}elseif($EncryptPath){$encrypt.PerformClick()}elseif($OpenPath){$drive.SelectedIndex=0; $unlock.PerformClick()}})
try {
    Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -SourceIdentifier FolderLock2.Session | Out-Null
    if($script:paths.Count) {
        Restore-EntryHistory $script:historyFile $LauncherPath (Join-Path (Split-Path $script:historyFile) 'entry-restore.log') | Out-Null
        Enable-EntryRecovery
    }
    Enable-ContextMenu;
    Refresh-List; $timer.Start(); [void]$form.ShowDialog()
} finally {
    Complete-DownloadUnlock 'cancelled' 'FolderLock 已关闭；下载数据保留。'
    if([IO.File]::Exists($script:downloadUnlockProtocol) -and [IO.File]::ReadAllText($script:downloadUnlockProtocol) -eq [string]$PID){[IO.File]::Delete($script:downloadUnlockProtocol)}
    $timer.Stop(); $timer.Dispose(); Unregister-Event -SourceIdentifier FolderLock2.Session -ErrorAction SilentlyContinue
    if ($script:pending) { $script:pending.Abort() }
    foreach ($mount in @($script:mounts.Values)) { $mount.Abort() }
    $form.Dispose()
    $script:uiMutex.ReleaseMutex(); $script:uiMutex.Dispose()
}
