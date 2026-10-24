# Local stand-in for the RAM Doctor relay (protocol v1), built on System.Net.HttpListener so the REAL client
# can be tested end to end without internet. It records every request.
#
#   $m = Start-MockRelay            # $m.Url -> http://127.0.0.1:<port>
#   $m.State.Mode = 'ok'            # ok | 400 | 401 | 413 | 429 | 500 | flaky (500,500,then ok)
#   $m.State.RequireCode = $true    # answer 401 when the request carries no "code"
#   $m.State.Requests               # recorded requests (Method, Path, ContentType, UserAgent, Body)
#   Stop-MockRelay $m

function Start-MockRelay {
    [CmdletBinding()]
    param([int]$Port = 0)
    if (-not $Port) {
        $tl = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $tl.Start(); $Port = $tl.LocalEndpoint.Port; $tl.Stop()
    }
    $state = [hashtable]::Synchronized(@{ Mode = 'ok'; RequireCode = $false; Stop = $false; Counter = 0; Requests = (New-Object System.Collections.ArrayList) })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('state', $state)
    $rs.SessionStateProxy.SetVariable('port', $Port)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://127.0.0.1:$port/")
            $l.Start()
            try {
                while (-not $state.Stop) {
                    $t = $l.GetContextAsync()
                    while (-not $t.Wait(150)) { if ($state.Stop) { break } }
                    if (-not $t.IsCompleted) { break }
                    $ctx = $t.Result
                    $req = $ctx.Request
                    $body = ''
                    if ($req.HasEntityBody) {
                        $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                        $body = $sr.ReadToEnd(); $sr.Close()
                    }
                    [void]$state.Requests.Add([pscustomobject]@{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath; ContentType = $req.ContentType; UserAgent = $req.UserAgent; Body = $body })
                    $status = 200
                    $out = '{"ok":true}'
                    if ($req.Url.AbsolutePath -eq '/v1/reports' -and $req.HttpMethod -eq 'POST') {
                        $state.Counter = [int]$state.Counter + 1
                        $mode = [string]$state.Mode
                        if ($mode -eq 'flaky') { if ($state.Counter -le 2) { $mode = '500' } else { $mode = 'ok' } }
                        $j = $null; try { $j = $body | ConvertFrom-Json } catch { }
                        if ($state.RequireCode -and -not ($j -and $j.code)) { $mode = '401' }
                        switch ($mode) {
                            'ok' {
                                $uid = if ($j) { [string]$j.userId } else { '00000000' }
                                $folder = 'reports/demo-' + $uid + '/20260101-120000'
                                $out = '{"ok":true,"folder":"' + $folder + '","url":"https://github.com/example/private-reports/tree/main/' + $folder + '"}'
                            }
                            '400' { $status = 400; $out = '{"ok":false,"error":"invalid"}' }
                            '401' { $status = 401; $out = '{"ok":false,"error":"bad code"}' }
                            '413' { $status = 413; $out = '{"ok":false,"error":"too large"}' }
                            '429' { $status = 429; $out = '{"ok":false,"error":"rate limited"}' }
                            default { $status = 500; $out = '{"ok":false,"error":"server"}' }
                        }
                    }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($out)
                    $ctx.Response.StatusCode = $status
                    $ctx.Response.ContentType = 'application/json; charset=utf-8'
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $ctx.Response.Close()
                }
            } finally { $l.Stop(); $l.Close() }
        })
    $handle = $ps.BeginInvoke()
    # wait until the port accepts connections
    $ready = $false
    for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
        try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $c.Close(); $ready = $true } catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $ready) { throw 'mock relay did not start' }
    # the readiness probe above is itself a (body-less) connection: drop whatever it recorded
    Start-Sleep -Milliseconds 150
    $state.Requests.Clear(); $state.Counter = 0
    return [pscustomobject]@{ Url = "http://127.0.0.1:$Port"; Port = $Port; State = $state; PS = $ps; Runspace = $rs; Handle = $handle }
}

function Stop-MockRelay {
    param($Mock)
    if (-not $Mock) { return }
    $Mock.State.Stop = $true
    try { [void]$Mock.PS.EndInvoke($Mock.Handle) } catch { }
    try { $Mock.PS.Dispose() } catch { }
    try { $Mock.Runspace.Close() } catch { }
}
