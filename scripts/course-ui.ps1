param([Parameter(Mandatory)][string]$SkillRoot, [Parameter(Mandatory)][int]$Port)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$courseCdp = [scriptblock]::Create([IO.File]::ReadAllText((Join-Path $SkillRoot 'scripts\cdp.ps1')))
function Invoke-CoursePage([string]$TargetId, [string]$js) {
    $value = & $courseCdp -Port $Port -TargetId $TargetId -Expression $js -AwaitPromise -TimeoutMs 30000
    if ($value -like 'JS-EXCEPTION*' -or $value -like 'CDP-ERROR*') { throw $value }
    return $value
}
function Click-CourseRect([string]$TargetId, $rect) {
    if ((Invoke-CoursePage $TargetId 'document.visibilityState') -ne 'visible') { throw 'Bring the course browser window to the foreground, then observe again before retrying.' }
    if ($rect.width -le 0 -or $rect.height -le 0) { throw 'Control is not visible' }
    foreach ($mouseType in @('mouseMoved','mousePressed','mouseReleased')) {
        $mouse = @{type=$mouseType;x=($rect.x+$rect.width/2);y=($rect.y+$rect.height/2);button='left';clickCount=1} | ConvertTo-Json -Compress
        $null = & $courseCdp -Port $Port -TargetId $TargetId -CdpMethod 'Input.dispatchMouseEvent' -CdpParams $mouse -Expression '1'
    }
}
function Open-CourseAssignment([string]$TargetId, [string]$name) {
    $null = & $courseCdp -Port $Port -TargetId $TargetId -CdpMethod 'Page.bringToFront' -Expression '1'
    $quotedName = ConvertTo-Json -InputObject $name -Compress
    $rect = (Invoke-CoursePage $TargetId "(()=>{const t=Array.from(document.querySelectorAll('.title-wrapper')).find(e=>e.querySelector('.tit')?.innerText===$quotedName);const b=t?.querySelector('.btn.do');if(!b)throw Error('Start button unavailable');b.scrollIntoView({block:'center',behavior:'instant'});return JSON.stringify(b.getBoundingClientRect().toJSON())})()") | ConvertFrom-Json
    Start-Sleep -Milliseconds 300
    $rect = (Invoke-CoursePage $TargetId "JSON.stringify(Array.from(document.querySelectorAll('.title-wrapper')).find(e=>e.querySelector('.tit')?.innerText===$quotedName).querySelector('.btn.do').getBoundingClientRect().toJSON())") | ConvertFrom-Json
    Click-CourseRect $TargetId $rect
}
function Select-CourseQuestion([string]$TargetId, [int]$number) {
    $null = & $courseCdp -Port $Port -TargetId $TargetId -CdpMethod 'Page.bringToFront' -Expression '1'
    $isCurrent = "document.body.innerText.split(String.fromCharCode(10)).some(line=>line.trim().startsWith('$number.【'))"
    if ((Invoke-CoursePage $TargetId $isCurrent) -eq 'True') { return }
    $index = $number - 1
    $rect = (Invoke-CoursePage $TargetId "(()=>{const e=document.querySelectorAll('li[questionid]')[$index];return JSON.stringify(e.getBoundingClientRect().toJSON())})()") | ConvertFrom-Json
    Click-CourseRect $TargetId $rect
    foreach ($attempt in 1..40) {
        if ((Invoke-CoursePage $TargetId $isCurrent) -eq 'True') { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Question navigation timeout: $number"
}
function Get-CourseQuestions([string]$TargetId) {
    $null = & $courseCdp -Port $Port -TargetId $TargetId -CdpMethod 'Page.bringToFront' -Expression '1'
    $count = [int](Invoke-CoursePage $TargetId 'document.querySelectorAll("li[questionid]").length')
    if ($count -eq 0) { throw 'No questions rendered' }
    $questions = @()
    foreach ($number in 1..$count) {
        Select-CourseQuestion $TargetId $number
        $question = Invoke-CoursePage $TargetId 'JSON.stringify({text:document.body.innerText,options:Array.from(document.querySelectorAll("label.el-radio,label.el-checkbox")).map(e=>({text:e.innerText,type:e.querySelector("input")?.type,checked:e.querySelector("input")?.checked}))})'
        $questions += ($question | ConvertFrom-Json)
    }
    return $questions
}
function Set-CourseAnswers([string]$TargetId, [string[]]$answers) {
    $count = [int](Invoke-CoursePage $TargetId 'document.querySelectorAll("li[questionid]").length')
    if ($count -ne $answers.Count) { throw 'Answer count mismatch' }
    foreach ($number in 1..$count) {
        Select-CourseQuestion $TargetId $number
        $answer = $answers[$number-1]
        if ($answer -notmatch '^[A-Z]+$') { throw "Invalid answer at question $number" }
        $optionCount = [int](Invoke-CoursePage $TargetId 'document.querySelectorAll("label.el-radio,label.el-checkbox").length')
        $wanted = @($answer.ToCharArray() | ForEach-Object { [int]$_ - [int][char]'A' })
        if (!$optionCount -or ($wanted | Where-Object { $_ -ge $optionCount })) { throw "Unsupported question or option at question $number" }
        $radio = (Invoke-CoursePage $TargetId '!!document.querySelector("label.el-radio")') -eq 'True'
        if ($radio -and $wanted.Count -ne 1) { throw 'Radio question requires one answer' }
        foreach ($index in 0..($optionCount-1)) {
            $desired = ($wanted -contains $index)
            if ($radio -and !$desired) { continue }
            $desiredJs = if ($desired) { 'true' } else { 'false' }
            $rect = (Invoke-CoursePage $TargetId "(()=>{const e=document.querySelectorAll('label.el-radio,label.el-checkbox')[$index];if(e.querySelector('input').checked===$desiredJs)return null;return JSON.stringify(e.getBoundingClientRect().toJSON())})()") | ConvertFrom-Json
            if ($rect) { Click-CourseRect $TargetId $rect }
        }
        $selected = @(Invoke-CoursePage $TargetId 'JSON.stringify(Array.from(document.querySelectorAll("label.el-radio,label.el-checkbox")).map((e,i)=>e.querySelector("input").checked?i:null).filter(i=>i!==null))' | ConvertFrom-Json)
        if (($selected -join ',') -ne (($wanted | Sort-Object -Unique) -join ',')) { throw "Selection verification failed at question $number" }
        Invoke-CoursePage $TargetId 'JSON.stringify({selected:Array.from(document.querySelectorAll("label.el-radio,label.el-checkbox")).filter(e=>e.querySelector("input").checked).map(e=>e.innerText)})'
    }
    Select-CourseQuestion $TargetId 1
}
function Submit-CourseHomework([string]$TargetId, [switch]$Authorized) {
    if (!$Authorized) { throw 'Submission requires the current user to authorize submission; use -Authorized only after that authorization.' }
    $rect = (Invoke-CoursePage $TargetId '(()=>{const e=document.querySelector(".Submithomeworkbtn");e.scrollIntoView({block:"center",behavior:"instant"});return JSON.stringify(e.getBoundingClientRect().toJSON())})()') | ConvertFrom-Json
    Click-CourseRect $TargetId $rect
    $dialog = ''
    foreach ($attempt in 1..40) {
        $dialog = Invoke-CoursePage $TargetId 'Array.from(document.querySelectorAll(".el-dialog__wrapper")).filter(e=>e.getBoundingClientRect().height>0).map(e=>e.innerText).join(" | ")'
        if ($dialog -and $dialog -ne 'null') { break }
        Start-Sleep -Milliseconds 500
    }
    if (!$dialog.Contains('是否确认提交作业')) { throw "Submission dialog: $dialog" }
    Start-Sleep -Milliseconds 600
    $rect = (Invoke-CoursePage $TargetId 'JSON.stringify(Array.from(document.querySelectorAll(".el-dialog__wrapper")).filter(e=>e.getBoundingClientRect().height>0).flatMap(e=>Array.from(e.querySelectorAll("button"))).find(e=>e.innerText.trim()==="提交").getBoundingClientRect().toJSON())') | ConvertFrom-Json
    Click-CourseRect $TargetId $rect
    foreach ($attempt in 1..60) {
        $status = Invoke-CoursePage $TargetId 'JSON.stringify({url:location.href,text:document.body.innerText})' | ConvertFrom-Json
        if ($status.url.Contains('doHomeWorknew') -and ($status.text.Contains('已批阅') -or $status.text.Contains('待批阅'))) { return $status.text }
        Start-Sleep -Milliseconds 500
    }
    throw 'Submission not confirmed'
}
