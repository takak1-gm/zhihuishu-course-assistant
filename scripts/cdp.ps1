<#
.SYNOPSIS
  Minimal Chrome DevTools Protocol client over raw WebSocket.
  Evaluates a JS expression in a page target and prints the result.

.EXAMPLE
  .\cdp.ps1 -Port 9223 -TargetId PAGE_ID -Expression "document.title"
  Supply -UrlLike only when it resolves to exactly one page.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateRange(1024,65535)][int]$Port,
  [string]$TargetId,
  [string]$UrlLike,
  [Parameter(Mandatory = $true)][string]$Expression,
  [int]$TimeoutMs = 15000,
  [switch]$AwaitPromise,
  [string]$CdpMethod,
  [string]$CdpParams = '{}'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Send-Cdp {
  param($Ws, [string]$Json, [int]$TimeoutMs)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
  $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
  $task = $Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token)
  if (-not $task.Wait($TimeoutMs)) { throw "send timeout" }
}

function Receive-CdpMessage {
  param($Ws, [int]$TimeoutMs)
  $buf = New-Object byte[] 65536
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $buf)
  $stream = [System.IO.MemoryStream]::new()
  $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
  while ($true) {
    $task = $Ws.ReceiveAsync($seg, $cts.Token)
    if (-not $task.Wait($TimeoutMs)) { throw "receive timeout" }
    $res = $task.Result
    if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'CDP connection closed' }
    $stream.Write($buf, 0, $res.Count)
    if ($res.EndOfMessage) { break }
  }
  $message = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
  $stream.Dispose()
  return $message
}

# ---- resolve target ----
$targets = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
$pages = @($targets | Where-Object { $_.type -eq 'page' })
if ($UrlLike) {
  $pages = @($pages | Where-Object { $_.url -like "*$UrlLike*" -or $_.title -like "*$UrlLike*" })
}
if ($pages.Count -eq 0) { throw "no matching page target on port $Port" }
if ($TargetId) { $pages = @($pages | Where-Object { $_.id -eq $TargetId }) }
if ($pages.Count -ne 1) { throw "Expected one page; found $($pages.Count). Supply an exact TargetId from /json/list." }
$target = $pages[0]

# ---- connect ----
$ws = [System.Net.WebSockets.ClientWebSocket]::new()
$cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
$connect = $ws.ConnectAsync([uri]$target.webSocketDebuggerUrl, $cts.Token)
if (-not $connect.Wait($TimeoutMs)) { throw "connect timeout" }

try {
  if ($CdpMethod) {
    $payload = @{ id = 1; method = $CdpMethod; params = ($CdpParams | ConvertFrom-Json) } | ConvertTo-Json -Depth 12 -Compress
  }
  else {
    $params = @{ expression = $Expression; returnByValue = $true; awaitPromise = [bool]$AwaitPromise }
    $payload = @{ id = 1; method = 'Runtime.evaluate'; params = $params } | ConvertTo-Json -Depth 8 -Compress
  }
  Send-Cdp -Ws $ws -Json $payload -TimeoutMs $TimeoutMs

  $result = $null
  for ($i = 0; $i -lt 20; $i++) {
    $raw = Receive-CdpMessage -Ws $ws -TimeoutMs $TimeoutMs
    $msg = $raw | ConvertFrom-Json
    if ($msg.id -eq 1) { $result = $msg; break }
  }
  if (-not $result) { throw "no response for id=1" }

  if ($result.error) {
    Write-Output ("CDP-ERROR: " + ($result.error | ConvertTo-Json -Compress -Depth 6))
  }
  elseif ($result.result.exceptionDetails) {
    throw ("JS-EXCEPTION: " + $result.result.exceptionDetails.text + ' ' + $result.result.exceptionDetails.exception.description)
  }
  elseif ($CdpMethod) {
    Write-Output ($result.result | ConvertTo-Json -Depth 12 -Compress)
  }
  else {
    $v = $result.result.result.value
    if ($null -eq $v) { Write-Output "null" }
    elseif ($v -is [string] -or $v -is [ValueType]) { Write-Output $v }
    else { Write-Output ($v | ConvertTo-Json -Depth 30 -Compress) }
  }
}
finally {
  try { $ws.Dispose() } catch { }
}
