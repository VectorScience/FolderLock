param([int]$Port,[string]$Directory)
$ErrorActionPreference='Stop'
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$listener.Start()
try {
    while($true) {
        $client=$listener.AcceptTcpClient()
        try {
            $stream=$client.GetStream()
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
            $request=$reader.ReadLine()
            while($reader.ReadLine()){}
            $name=[IO.Path]::GetFileName(([uri]('http://localhost'+($request.Split(' ')[1]))).AbsolutePath)
            $path=Join-Path $Directory $name
            if([IO.File]::Exists($path)) {
                $bytes=[IO.File]::ReadAllBytes($path)
                $header="HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
            } else {$bytes=[Text.Encoding]::ASCII.GetBytes('not found');$header="HTTP/1.1 404 Not Found`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"}
            $headers=[Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($headers,0,$headers.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
        } finally {$client.Dispose()}
    }
} finally {$listener.Stop()}
