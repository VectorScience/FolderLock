param([switch]$MountTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$testRoot = Join-Path $PSScriptRoot ('.test-crypto-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$engine = New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
$password = '测试 P@ssword & $() " 123'
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Expect-Failure([scriptblock]$action, [string]$message) {
    $failed = $false; try { & $action } catch { $failed = $true }
    Assert $failed $message
}
function Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
try {
    $vault = Join-Path $testRoot '目录 中文 & $()'
    [void][IO.Directory]::CreateDirectory((Join-Path $vault '子目录\empty'))
    $expected = @{}
    $expectedTime = [datetime]::SpecifyKind([datetime]'2001-02-03 04:05:06',[DateTimeKind]::Utc)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    foreach ($size in @(0, 1, 65535, 65536, 65537, 2097153)) {
        $name = '子目录\file-' + $size + '.bin'; $bytes = New-Object byte[] $size; $rng.GetBytes($bytes)
        $path = Join-Path $vault $name; [IO.File]::WriteAllBytes($path, $bytes); $expected[$name] = Hash $path
        [IO.File]::SetLastWriteTimeUtc($path,$expectedTime)
    }
    $rng.Dispose()
    # A completed conversion must physically remove every source, preserve all bytes and empty dirs.
    $work = New-Object FolderLock.Work
    $engine.Convert($vault, $password, $work)
    Assert ([FolderLock.VaultEngine]::Read($vault).State -eq 'ready') 'Vault not ready'
    foreach ($name in $expected.Keys) { Assert (-not (Test-Path -LiteralPath (Join-Path $vault $name))) 'Plaintext source survived success' }
    Assert (@(Get-ChildItem -LiteralPath $vault -Force).Count -eq 1) 'Plaintext directory names survived success'
    $engine.Authenticate($vault, $password)
    Expect-Failure { $engine.Authenticate($vault, 'wrong-password') } 'Wrong password accepted'
    # Export through actual rclone crypt, using independent CLI configuration.
    $info = [FolderLock.VaultEngine]::Read($vault)
    $cryptEnv = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $cryptEnv['RCLONE_CONFIG_TEST_TYPE'] = 'crypt'
    $cryptEnv['RCLONE_CONFIG_TEST_REMOTE'] = Join-Path $vault '.folderlock\data'
    $cryptEnv['RCLONE_CONFIG_TEST_PASSWORD'] = $engine.Command(@('obscure','-'), $null, $password)
    $cryptEnv['RCLONE_CONFIG_TEST_PASSWORD2'] = $engine.Command(@('obscure','-'), $null, $info.Salt)
    $cryptEnv['RCLONE_CONFIG_TEST_FILENAME_ENCODING'] = $info.FilenameEncoding
    $export = Join-Path $testRoot 'export'
    [void]$engine.Command(@('copy','test:', $export, '--create-empty-src-dirs'), $cryptEnv, $null)
    foreach ($name in $expected.Keys) { Assert ((Hash (Join-Path $export $name)) -eq $expected[$name]) "Roundtrip mismatch: $name" }
    foreach ($name in $expected.Keys) { Assert ([IO.File]::GetLastWriteTimeUtc((Join-Path $export $name)) -eq $expectedTime) "Modification time lost: $name" }
    Assert (Test-Path -LiteralPath (Join-Path $export '子目录\empty')) 'Empty directory lost'
    $metadata = Get-Content (Join-Path $vault '.folderlock\vault.json') -Raw
    Assert (-not $metadata.Contains($password)) 'Password persisted'
    # Pause before conversion leaves plaintext and permits restart with the same password.
    $resume = Join-Path $testRoot 'resume'; [void][IO.Directory]::CreateDirectory($resume)
    [IO.File]::WriteAllText((Join-Path $resume 'keep.txt'), 'keep exactly')
    $paused = New-Object FolderLock.Work; $paused.CancelRequested = $true
    $engine.Convert($resume, $password, $paused)
    Assert (Test-Path (Join-Path $resume 'keep.txt')) 'Pause deleted source'
    Assert ([FolderLock.VaultEngine]::Read($resume).State -eq 'converting') 'Paused state incorrect'
    Expect-Failure { $engine.Convert($resume, 'wrong-password', (New-Object FolderLock.Work)) } 'Resume with wrong password accepted'
    Assert ([IO.File]::ReadAllText((Join-Path $resume 'keep.txt')) -eq 'keep exactly') 'Wrong-password attempt changed source'
    $engine.Convert($resume, $password, (New-Object FolderLock.Work))
    Assert ([FolderLock.VaultEngine]::Read($resume).State -eq 'ready') 'Resume failed'
    # An open writer must be detected before a vault is created or any source removed.
    $busy = Join-Path $testRoot 'busy'; [void][IO.Directory]::CreateDirectory($busy)
    $busyFile = Join-Path $busy 'busy.txt'; [IO.File]::WriteAllText($busyFile, 'busy original')
    $handle = [IO.File]::Open($busyFile, 'Open', 'ReadWrite', 'Read')
    try { Expect-Failure { $engine.Convert($busy, $password, (New-Object FolderLock.Work)) } 'Open writer accepted' }
    finally { $handle.Dispose() }
    Assert ([IO.File]::ReadAllText($busyFile) -eq 'busy original') 'Busy original damaged'
    Assert (-not (Test-Path (Join-Path $busy '.folderlock'))) 'Preflight modified busy folder'
    # ADS must never be silently discarded by replacing only the default stream.
    Set-Content -LiteralPath $busyFile -Stream extra -Value 'important alternate stream' -NoNewline
    Expect-Failure { $engine.Convert($busy, $password, (New-Object FolderLock.Work)) } 'ADS accepted'
    Assert ((Get-Content -LiteralPath $busyFile -Stream extra -Raw) -eq 'important alternate stream') 'ADS lost'
    # Inject actual on-disk corruption between encryption and verification. The wrapper
    # still executes the real rclone for crypto; only the disk fault is artificial.
    $shimSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
class Fault {
    static string Q(string s) {
        var b = new StringBuilder("\""); int n = 0;
        foreach (char c in s) { if (c == '\\') { n++; continue; } b.Append('\\', c == '"' ? n * 2 + 1 : n); b.Append(c); n = 0; }
        b.Append('\\', n * 2); return b.Append('"').ToString();
    }
    static int Main(string[] args) {
        if (args.Length > 1 && args[0] == "cat" && args[1].StartsWith("fldata:")) {
            string root = Environment.GetEnvironmentVariable("RCLONE_CONFIG_FLDATA_REMOTE");
            string f = Directory.GetFiles(root, "*", SearchOption.AllDirectories).First();
            using (var stream = File.Open(f, FileMode.Open, FileAccess.Write, FileShare.None)) stream.WriteByte(0);
        }
        bool input = args[0] == "obscure" || args[0] == "rcat";
        var psi = new ProcessStartInfo(Environment.GetEnvironmentVariable("FOLDERLOCK_TEST_RCLONE"), String.Join(" ", args.Select(Q))) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = input,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        using (var p = Process.Start(psi)) {
            var output = p.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
            var error = p.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
            if (input) { Console.OpenStandardInput().CopyTo(p.StandardInput.BaseStream); p.StandardInput.Close(); }
            p.WaitForExit(); output.Wait(); error.Wait(); return p.ExitCode;
        }
    }
}
'@
    $shimCs = Join-Path $testRoot 'Fault.cs'; $shimExe = Join-Path $testRoot 'Fault.exe'
    [IO.File]::WriteAllText($shimCs, $shimSource)
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe "/out:$shimExe" $shimCs
    Assert ($LASTEXITCODE -eq 0) 'Fault injector did not compile'
    $env:FOLDERLOCK_TEST_RCLONE = $RclonePath
    $faultEngine = New-Object FolderLock.VaultEngine($shimExe)
    $faultRoot = Join-Path $testRoot 'fault'; [void][IO.Directory]::CreateDirectory($faultRoot)
    $original = Join-Path $faultRoot 'source.txt'; [IO.File]::WriteAllText($original, 'must survive failed verification')
    $originalHash = Hash $original
    $faultError = $null
    try { $faultEngine.Convert($faultRoot, $password, (New-Object FolderLock.Work)) } catch { $faultError = $_.Exception.ToString() }
    Assert ($null -ne $faultError -and $faultError.Contains('密文回读验证失败')) ('Expected verification failure, got: ' + $faultError)
    Assert ((Hash $original) -eq $originalHash) 'Verification failure deleted or modified source'
    Assert ([FolderLock.VaultEngine]::Read($faultRoot).State -eq 'converting') 'Failed conversion shown as ready'
    $engine.Convert($faultRoot, $password, (New-Object FolderLock.Work))
    Assert (-not (Test-Path $original)) 'Retry after verification failure did not finish'
    # Alter ciphertext, then ask the independent reader to verify; authentication must fail.
    $cipherFile = Get-ChildItem (Join-Path $vault '.folderlock\data') -File -Recurse | Where-Object Length -gt 1000 | Select-Object -First 1
    $f = [IO.File]::Open($cipherFile.FullName, 'Open', 'ReadWrite', 'None')
    try { $f.Position = 50; $value = $f.ReadByte(); $f.Position = 50; $f.WriteByte($value -bxor 1) } finally { $f.Dispose() }
    Expect-Failure { [void]$engine.Command(@('copy','test:', (Join-Path $testRoot 'corrupt-export')), $cryptEnv, $null) } 'Tampered ciphertext accepted'
    if ($MountTest) {
        $mount = $engine.Open($resume, $password, 'Y:')
        try {
            $until = (Get-Date).AddSeconds(20)
            while (-not (Test-Path 'Y:\keep.txt') -and (Get-Date) -lt $until -and $mount.Alive) { Start-Sleep -Milliseconds 100 }
            Assert $mount.Alive ('Mount exited: ' + $mount.Failure)
            Assert ([IO.File]::ReadAllText('Y:\keep.txt') -eq 'keep exactly') 'Mounted read mismatch'
            [IO.File]::WriteAllText('Y:\new.txt', 'saved encrypted')
            $mount.Lock((New-Object FolderLock.Work),30)
        } finally { if (-not $mount.Closed) { $mount.Abort() } }
        Assert (-not (Test-Path 'Y:\keep.txt')) 'Lock failed to remove mount'
    }
    'PASS: byte-exact roundtrip, empty directories, wrong password, pause/resume, busy files, ADS, tampering, source preserved after verification failure' + $(if ($MountTest) { ', actual mount/read/lock' })
} finally {
    [Environment]::SetEnvironmentVariable('FOLDERLOCK_TEST_RCLONE', $null, 'Process')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $workspace = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($resolved)).StartsWith('.test-crypto-')) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
