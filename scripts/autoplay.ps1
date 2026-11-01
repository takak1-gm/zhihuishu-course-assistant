param(
  [Parameter(Mandatory)][string]$SkillRoot,
  [Parameter(Mandatory)][ValidateRange(1024,65535)][int]$Port,
  [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$CourseId,
  [Parameter(Mandatory)][string]$TargetId,
  [Parameter(Mandatory)][string]$LogPath,
  [ValidateRange(1,24)][int]$MaxHours = 12
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$courseMutex = [Threading.Mutex]::new($false, ("Local\ZhihuishuAutoplay-" + $Port + "-" + $TargetId))
try { $courseLockHeld = $courseMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $courseLockHeld = $true }
if (!$courseLockHeld) { $courseMutex.Dispose(); exit }
$cdp = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path $SkillRoot 'scripts\cdp.ps1') -Encoding UTF8 -Raw))
$log = $LogPath
function Write-CourseLog([string]$message) {
    Add-Content -LiteralPath $log -Encoding UTF8 -Value ("{0:o} {1}" -f [DateTimeOffset]::Now, $message)
}
$expression = @'
(async () => {
  const query = new URLSearchParams(location.search);
  if (query.get('courseId') !== '__COURSE_ID__') return JSON.stringify({status:'other-course'});
  const video = document.querySelector('video');
  if (video?.error) return JSON.stringify({status:'video-error',code:video.error.code});
  if (!video || video.readyState < 2) return JSON.stringify({status:'loading'});
  const current = document.querySelector('.file-item.active');
  const items = Array.from(document.querySelectorAll('.file-item')).filter(e => e.querySelector('.icon-video'));
  const index = items.indexOf(current);
  if (index < 0) return JSON.stringify({status:'no-current-item'});
  const fileId = query.get('fileId');
  if (window.__zhihuishuAutoplay?.fileId !== fileId) window.__zhihuishuAutoplay = {started:false,fileId};
  const state = window.__zhihuishuAutoplay;
  if (video.ended) {
    const next = items[index + 1];
    if (!next) return JSON.stringify({status:'complete'});
    const result = JSON.stringify({status:'next',name:next.querySelector('.file-name').innerText.trim()});
    setTimeout(() => next.click(), 250);
    return result;
  }
  if (!state.started) {
    state.started = true;
    if (video.paused) {
      try { await video.play(); }
      catch (error) { return JSON.stringify({status:'play-blocked',message:error.message}); }
    }
  }
  return JSON.stringify({status:video.paused?'paused':'playing',fileId:query.get('fileId'),name:current.querySelector('.file-name').innerText.trim(),time:Math.floor(video.currentTime),duration:Math.floor(video.duration)});
})()
'@
$expression = $expression.Replace('__COURSE_ID__', $CourseId)
Write-CourseLog "START pid=$PID port=$Port course=$CourseId target=$TargetId"
$lastStatus = ''
$consecutiveFailures = 0
$lastLogTime = [DateTimeOffset]::MinValue
$deadline = [DateTimeOffset]::Now.AddHours($MaxHours)
try {
    while ([DateTimeOffset]::Now -lt $deadline) {
      try {
        $pages = (Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
        $target = @($pages | Where-Object { $_.type -eq 'page' -and $_.id -eq $TargetId })
        if ($target.Count -ne 1) { Write-CourseLog 'STOP course tab closed or ambiguous'; break }
        $params = @{expression=$expression; returnByValue=$true; awaitPromise=$true; userGesture=$true} | ConvertTo-Json -Compress
        $raw = & $cdp -Port $Port -TargetId $TargetId -Expression '1' -CdpMethod 'Runtime.evaluate' -CdpParams $params
        $response = $raw | ConvertFrom-Json
        $state = $response.result.value | ConvertFrom-Json
        if (!$state) { throw "Unexpected CDP result: $raw" }
        $consecutiveFailures = 0
        $statusKey = "$($state.status) $($state.fileId) $($state.name)"
        if ($statusKey -ne $lastStatus -or ([DateTimeOffset]::Now - $lastLogTime).TotalSeconds -ge 60) {
            Write-CourseLog $response.result.value
            $lastStatus = $statusKey
            $lastLogTime = [DateTimeOffset]::Now
        }
        if ($state.status -in @('complete','video-error','play-blocked','other-course','no-current-item')) { break }
      } catch {
        $consecutiveFailures++
        Write-CourseLog "RETRY $consecutiveFailures/6 $($_.Exception.Message)"
        if ($consecutiveFailures -ge 6) { throw }
      }
        Start-Sleep -Seconds 5
    }
} catch { Write-CourseLog "ERROR $($_.Exception.Message)" }
Write-CourseLog 'STOP'
$courseMutex.ReleaseMutex()
$courseMutex.Dispose()
