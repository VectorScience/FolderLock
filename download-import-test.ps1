param([string]$DownloaderRoot=(Join-Path (Split-Path $PSScriptRoot -Parent) 'OnlineVideoDownloader'),[string]$Ffmpeg='C:\Program Files\ffmpeg\bin\ffmpeg.exe',[switch]$PasswordOutcomesOnly,[switch]$IncludeRange)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'FolderLock.ps1') -LibraryOnly
$base=Join-Path $PSScriptRoot ('.test-downloader-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $base 'OVD'
$fixtures=Join-Path $base 'http'
$settingsPath=Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'com.harry.ovd\settings.json'
$exe=Join-Path $DownloaderRoot 'src-tauri\target\release\ovd.exe'
$settingsBytes=$null;$app=$null;$server=$null;$mount=$null;$ws=$null;$success=$false
$retained=New-Object 'System.Collections.Generic.List[string]'
function Assert($value,$message){if(-not $value){throw $message}}
function Free-Port {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop();return $port
}
function Api([string]$method,[string]$route,$body=$null) {
    $separator=if($route.Contains('?')){'&'}else{'?'}
    $request=[Net.HttpWebRequest]::Create(('http://127.0.0.1:'+$apiPort+$route+$separator+'token='+$token))
    $request.Proxy=$null;$request.Method=$method;$request.Timeout=10000
    if($body -ne $null) {
        if($body -is [byte[]]){$bytes=$body;$request.ContentType='application/octet-stream'}
        else {$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 12 -Compress));$request.ContentType='application/json'}
        $request.ContentLength=$bytes.Length
        $stream=$request.GetRequestStream();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }
    try {
        $response=$request.GetResponse()
        try {$reader=[IO.StreamReader]::new($response.GetResponseStream());$text=$reader.ReadToEnd();if($text){return (ConvertFrom-Json $text)}}finally{$response.Dispose()}
    } catch {throw ('Local downloader API failed: '+$method+' '+$route)}
}
function Download([string]$title,[string]$source,[string]$mode='full') {
    $media=@{id=[guid]::NewGuid().ToString();url=$source;page_url='http://127.0.0.1/storage-test';title=$title;kind=$(if($source.EndsWith('.m3u8')){'hls'}else{'progressive'});tab_id=$null;mime=$null;referer=$null;origin=$null;user_agent=$null;cookie=$null;request_headers=@{};current_time=$null;duration=$null;playing=$false}
    $request=@{media=$media;mode=$mode;start_time=$null;end_time=$null}
    if($mode -eq 'range'){$request.start_time=0.3;$request.end_time=1.6}
    $reply=Api 'POST' '/v1/jobs' $request
    if($mode -eq 'follow') {
        $prefix='/v1/follow/'+$reply.job_id+'?url='
        $null=Api 'POST' ($prefix+[uri]::EscapeDataString($source)) ([IO.File]::ReadAllBytes((Join-Path $fixtures 'video.m3u8')))
        foreach($part in (Get-ChildItem -LiteralPath $fixtures -Filter 'seg*.ts' | Sort-Object Name)) {
            $url='http://127.0.0.1:'+$httpPort+'/'+$part.Name
            $null=Api 'POST' ($prefix+[uri]::EscapeDataString($url)) ([IO.File]::ReadAllBytes($part.FullName))
        }
        $deadline=(Get-Date).AddSeconds(10)
        do {
            $status=Api 'GET' '/v1/bootstrap'
            $progress=@($status.jobs | Where-Object id -eq $reply.job_id)[0]
            if($progress.segments_done -ge 3){break}
            Start-Sleep -Milliseconds 50
        }while((Get-Date) -lt $deadline)
        Assert ($progress.segments_done -ge 3) 'Follow mode did not capture fixture segments'
        $null=Api 'POST' ('/v1/jobs/'+$reply.job_id+'/cancel')
    }
    $limit=(Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Milliseconds 200
        $snapshot=Api 'GET' '/v1/bootstrap'
        $job=@($snapshot.jobs | Where-Object id -eq $reply.job_id)[0]
    } while($job.status -in @('queued','running','saving','awaiting_unlock','cancelling','paused') -and (Get-Date) -lt $limit)
    Assert ($job.status -notin @('queued','running','saving','awaiting_unlock','cancelling','paused')) 'Download timed out'
    return $job
}
function Wait-Locked {
    $until=(Get-Date).AddSeconds(45)
    do {
        if([IO.File]::Exists((Join-Path $root '解锁文件夹.lnk')) -and -not [FolderLock.VaultEngine]::HasWriteCache($root)){return}
        Start-Sleep -Milliseconds 100
    }while((Get-Date) -lt $until)
    throw 'FolderLock test UI did not safely lock'
}
$uiProcess=$null;$testUiPid=$null
$control=Join-Path $base 'ui-control.txt';$answer=Join-Path $base 'password-answer.txt';$observations=Join-Path $base 'prompts.log'
try {
    Assert (-not(Get-Process -Name ovd,OVD-fixed -ErrorAction SilentlyContinue)) 'Close OVD before the isolated test'
    [void][IO.Directory]::CreateDirectory($fixtures);[void][IO.Directory]::CreateDirectory($root)
    $bin=Join-Path $base 'launcher';[void][IO.Directory]::CreateDirectory($bin)
    $testLauncher=Join-Path $bin 'FolderLock.exe'
    $engine=New-Object FolderLock.VaultEngine((Join-Path $PSScriptRoot 'build\tools\rclone.exe'))
    $identity='FolderLockImportTest-'+[guid]::NewGuid().ToString('N')+'-'
    $ui=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FolderLock.ps1')).Replace("`r`n","`n")
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($ui,[ref]$tokens,[ref]$errors)
    $passwordFunction=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-Password'},$true)
    $replacement=@'
function Read-Password {
    $work=Split-Path $script:downloadUnlockRequest
    $completed=@(Get-ChildItem -LiteralPath $work -File | Where-Object {$_.Length -gt 0 -and $_.Extension -in @('.mp4','.ts')})
    if(-not $completed.Count){throw 'TEST: password requested before downloaded data exists'}
    [IO.File]::AppendAllText('__OBSERVATIONS__',('downloaded-before-write-prompt: '+$completed[0].FullName+"`n"))
    $answer=[IO.File]::ReadAllText('__ANSWER__')
    if($answer -eq 'cancel'){return $null}
    if($answer -eq 'wrong'){return 'wrong-fixture-password'}
    return 'downloader-roundtrip-password'
}
'@
    $replacement=$replacement.Replace('__OBSERVATIONS__',$observations).Replace('__ANSWER__',$answer)
    $ui=$ui.Remove($passwordFunction.Extent.StartOffset,$passwordFunction.Extent.EndOffset-$passwordFunction.Extent.StartOffset).Insert($passwordFunction.Extent.StartOffset,$replacement)
    $ui=$ui.Replace('Local\FolderLock2UI-',('Local\'+$identity))
    $ui=$ui.Replace('Enable-EntryRecovery;','$null=0;').Replace('Enable-ContextMenu;','$null=0;')
    $ui=$ui.Replace("`$script:historyFile = Join-Path `$env:LOCALAPPDATA 'FolderLock\vaults.json'",("`$script:historyFile = '"+(Join-Path $base 'history.json')+"'"))
    $ui=$ui.Replace("[void][System.Windows.Forms.MessageBox]::Show(`$message, 'FolderLock', 'OK', 'Error')",("[IO.File]::AppendAllText('"+(Join-Path $base 'ui-errors.log')+"',`$message)"))
    $tick=@'
        if([IO.File]::Exists('__CONTROL__')) {
            $command=[IO.File]::ReadAllText('__CONTROL__');[IO.File]::Delete('__CONTROL__')
            if($command -eq 'lock'){Lock-All}
            if($command -eq 'exit'){$form.Close()}
        }
'@
    $tick=$tick.Replace('__CONTROL__',$control)
    $ui=$ui.Replace("`$timer.Add_Tick({`n    try {",("`$timer.Add_Tick({`n    try {`n"+$tick))
    $uiFile=Join-Path $base 'Test-FolderLock.ps1';[IO.File]::WriteAllText($uiFile,$ui,[Text.UTF8Encoding]::new($true))
    $launcherSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher.cs'))
    $launcherSource=$launcherSource.Replace('Local\\FolderLock2UI-',('Local\\'+$identity)).Replace('Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)',('@"'+(Join-Path $base 'runtime')+'"'))
    $cs=Join-Path $base 'TestLauncher.cs';[IO.File]::WriteAllText($cs,$launcherSource,[Text.UTF8Encoding]::new($true))
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /reference:System.Windows.Forms.dll ('/out:'+$testLauncher) ('/resource:'+$uiFile+',FolderLock.ps1') ('/resource:'+(Join-Path $PSScriptRoot 'VaultEngine.cs')+',VaultEngine.cs') ('/resource:'+(Join-Path $PSScriptRoot 'build\FolderLock.ico')+',FolderLock.ico') ('/resource:'+(Join-Path $PSScriptRoot 'Legacy-FolderLock.ps1')+',Legacy-FolderLock.ps1') ('/resource:'+(Join-Path $PSScriptRoot 'Prepare-Dependencies.ps1')+',Prepare-Dependencies.ps1') $cs
    Assert ($LASTEXITCODE -eq 0) 'Test launcher compilation failed'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build\tools\rclone.exe') -Destination (Join-Path $bin 'rclone.exe')
    [IO.File]::WriteAllText((Join-Path $root 'seed.txt'),'keep')
    $engine.Convert($root,'downloader-roundtrip-password',(New-Object FolderLock.Work))
    $mount=$engine.OpenOriginal($root,'downloader-roundtrip-password',$testLauncher)
    $mount.Lock((New-Object FolderLock.Work),30);$mount=$null
    $video=Join-Path $fixtures 'source.mp4'
    & $Ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=128x96:rate=25' -f lavfi -i 'sine=frequency=700:sample_rate=48000' -t 3 -c:v libx264 -preset ultrafast -g 25 -c:a aac -y $video
    Assert ($LASTEXITCODE -eq 0) 'Fixture generation failed'
    & $Ffmpeg -hide_banner -loglevel error -i $video -c copy -f hls -hls_time 1 -hls_list_size 0 -hls_segment_filename (Join-Path $fixtures 'seg%03d.ts') -y (Join-Path $fixtures 'video.m3u8')
    Assert ($LASTEXITCODE -eq 0) 'HLS fixture generation failed'
    $httpPort=Free-Port;$apiPort=Free-Port;$token=[guid]::NewGuid().ToString()
    $server=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'downloader-test-server.ps1')+'"'),'-Port',$httpPort,'-Directory',('"'+$fixtures+'"')) -WindowStyle Hidden -PassThru
    $settingsBytes=[IO.File]::ReadAllBytes($settingsPath)
    $settings=[Text.Encoding]::UTF8.GetString($settingsBytes) | ConvertFrom-Json
    $settings.download_dir=$root;$settings.bridge_port=$apiPort;$settings.token=$token
    [IO.File]::WriteAllText($settingsPath,(ConvertTo-Json $settings),[Text.UTF8Encoding]::new($false))
    $priorNoProxy=$env:NO_PROXY
    try {$env:NO_PROXY='127.0.0.1,localhost';$app=Start-Process -FilePath $exe -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $base 'downloader.log') -RedirectStandardError (Join-Path $base 'downloader-error.log')}
    finally {$env:NO_PROXY=$priorNoProxy}
    $ready=$false;$until=(Get-Date).AddSeconds(30)
    do {try{$null=Api 'GET' '/v1/bootstrap';$ready=$true}catch{Start-Sleep -Milliseconds 250}}while(-not $ready -and (Get-Date) -lt $until)
    Assert $ready 'Test downloader did not start'
    $ws=[Net.WebSockets.ClientWebSocket]::new();$ws.Options.Proxy=$null
    $ws.ConnectAsync([uri]('ws://127.0.0.1:'+$apiPort+'/v1/ws?token='+$token),[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    $cases=if($PasswordOutcomesOnly){@()}else{@(@('HLS-write-unlock','video.m3u8','full'),@('MP4-write-unlock','source.mp4','full'),@('Follow-write-unlock','video.m3u8','follow'))}
    if($IncludeRange){$cases+=,@('Range-write-unlock','video.m3u8','range')}
    foreach($case in $cases) {
        [IO.File]::WriteAllText($answer,'correct')
        $job=Download $case[0] ('http://127.0.0.1:'+$httpPort+'/'+$case[1]) $case[2]
        Assert ($job.status -eq 'done') ('Download/import failed: '+$job.error)
        $hash=(Get-FileHash -LiteralPath $job.output_path -Algorithm SHA256).Hash
        [IO.File]::WriteAllText($control,'lock');Wait-Locked
        $mount=$engine.OpenOriginal($root,'downloader-roundtrip-password',$testLauncher)
        Assert ((Get-FileHash -LiteralPath $job.output_path -Algorithm SHA256).Hash -eq $hash) 'Video changed after encryption and reopen'
        & $Ffmpeg -hide_banner -loglevel error -i $job.output_path -f null -
        Assert ($LASTEXITCODE -eq 0) 'Imported video cannot decode after reopen'
        $mount.Lock((New-Object FolderLock.Work),30);$mount=$null
        Write-Output ('PASS original write -> FolderLock unlock -> original save -> safe lock/reopen: '+$case[0])
    }
    foreach($mode in @('cancel','wrong')) {
        [IO.File]::WriteAllText($answer,$mode)
        $job=Download ('HLS-'+$mode) ('http://127.0.0.1:'+$httpPort+'/video.m3u8')
        Assert ($job.status -eq 'error' -and $job.error -match '已保留') 'Cancelled/wrong password write did not retain downloaded data'
        $location=[regex]::Match($job.error,'已保留下载分片：(.+?)。')
        Assert $location.Success 'Recovery location missing from task error'
        $work=$location.Groups[1].Value;$retained.Add($work)
        $completed=@(Get-ChildItem -LiteralPath $work -File | Where-Object {$_.Length -gt 0 -and $_.Extension -in @('.mp4','.ts')})
        Assert ($completed.Count -gt 0) 'Downloaded media lost after unlock refusal'
        & $Ffmpeg -hide_banner -loglevel error -i $completed[0].FullName -f null -
        Assert ($LASTEXITCODE -eq 0) 'Retained completed video cannot decode'
        Wait-Locked
        Write-Output ('PASS '+$mode+' password outcome: downloaded media retained, target stays locked')
    }
    $expectedPrompts=$cases.Count+2
    Assert (@([IO.File]::ReadAllLines($observations)).Count -eq $expectedPrompts) 'Missing prompt timing evidence'
    [IO.File]::WriteAllText($control,'exit')
    $pidFile=Join-Path $base 'runtime\FolderLock\app-v2\download-unlock-v1.pid'
    if(Test-Path -LiteralPath $pidFile){$testUiPid=[int][IO.File]::ReadAllText($pidFile)}
    $until=(Get-Date).AddSeconds(15)
    while((Test-Path -LiteralPath $pidFile) -and (Get-Date) -lt $until){Start-Sleep -Milliseconds 100}
    Assert (-not(Test-Path -LiteralPath $pidFile)) 'Test UI did not exit'
    $success=$true
    'PASS: original save prompts to unlock; cancelled/wrong password retains media; original saved files survive safe lock/reopen with identical SHA-256'
} finally {
    if($ws){$ws.Dispose()}
    if($app -and -not $app.HasExited){Stop-Process -Id $app.Id -Force}
    if($settingsBytes){[IO.File]::WriteAllBytes($settingsPath,$settingsBytes)}
    if($server -and -not $server.HasExited){Stop-Process -Id $server.Id -Force}
    if($mount){$mount.Abort()}
    if($success) {
        $full=[IO.Path]::GetFullPath($base)
        if(-not $full.StartsWith(($PSScriptRoot.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike '.test-downloader-*'){throw 'Unsafe cleanup'}
        if((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){[IO.Directory]::Delete($root)}
        $view=$root+'.folderlock\view';$acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($false,$false);[IO.Directory]::SetAccessControl($view,$acl)
        Remove-Item -LiteralPath $full -Recurse -Force
        foreach($work in @($retained | Select-Object -Unique)) {
            $cache=[IO.Path]::GetFullPath($work)
            $temp=([IO.Path]::GetDirectoryName($cache) -eq ([IO.Path]::GetTempPath().TrimEnd('\')) -and [IO.Path]::GetFileName($cache) -match '^ovd-[0-9a-f-]{36}$')
            $persistent=([IO.Path]::GetDirectoryName($cache) -eq (Join-Path (Split-Path $settingsPath -Parent) 'download-cache') -and [IO.Path]::GetFileName($cache) -match '^[a-f0-9]{64}$')
            if(-not($temp -or $persistent)){throw 'Unsafe test cache cleanup'}
            $receipt=[IO.File]::ReadAllText((Join-Path $cache 'recovery.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
            if($receipt.target_directory -ne $root){throw 'Cache belongs to a different destination'}
            Remove-Item -LiteralPath $cache -Recurse -Force
        }
    }
}
