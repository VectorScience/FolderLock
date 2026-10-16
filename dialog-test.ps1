$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$script:stage = 0
$script:ValidationErrors = @()
function Show-Error([string]$message) { $script:ValidationErrors += $message }
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    if ($script:stage -ge 2) { return }
    $dialog = [System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq '测试密码输入' } | Select-Object -First 1
    if (-not $dialog) { return }
    $fields = @($dialog.Controls | Where-Object { $_ -is [System.Windows.Forms.TextBox] } | Sort-Object Top)
    $button = $dialog.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq '确定' } | Select-Object -First 1
    if ($script:stage -eq 0) {
        $fields[0].Text = 'password123'
        $button.PerformClick()
        $script:stage = 1
    } else {
        $fields[1].Text = 'password123'
        $script:stage = 2
        $button.PerformClick()
    }
})
$timer.Start()
try {
    $result = Read-Password '测试密码输入' $true
    if ($script:stage -ne 2 -or $script:ValidationErrors.Count -ne 1) { throw 'Dialog accepted an unconfirmed password' }
    if ($result -ne 'password123') { throw 'Password dialog did not return the confirmed value' }
    'PASS'
} finally { $timer.Stop(); $timer.Dispose() }
