param([ValidateSet('History','LongNames')][string]$Case = 'LongNames')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$root = Join-Path $PSScriptRoot ('.test-regression-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    if ($Case -eq 'History') {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'FolderLock.ps1'), [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-History' }, $true)
        Invoke-Expression $definition.Extent.Text
        $script:historyFile = Join-Path $root 'history.json'; $script:paths = @()
        Add-History 'D:\Example1'; Add-History 'D:\Example2'
        $saved = Get-Content $script:historyFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.Count -ne 2) { throw 'History replacement lost an entry' }
    } else {
        $vault = Join-Path $root 'vault'; [void][IO.Directory]::CreateDirectory($vault)
        $file = Join-Path $vault (('a' * 170) + '.txt')
        [IO.File]::WriteAllText($file, 'long name content must survive')
        $engine = New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
        $engine.Convert($vault, 'regression-password', (New-Object FolderLock.Work))
        if (Test-Path -LiteralPath $file) { throw 'Long filename was not converted' }
        $engine.Authenticate($vault, 'regression-password')
    }
    "PASS: $Case"
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike '.test-regression-*') { throw 'Unsafe cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
