param([Parameter(Mandatory)][string]$SkillRoot)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $SkillRoot).Path
$required = @('SKILL.md','README.md','agents/openai.yaml','scripts/cdp.ps1','scripts/course-ui.ps1','scripts/autoplay.ps1','references/connection.md','references/homework.md','references/validation.md')
foreach ($file in $required) {
    if (!(Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) { throw "Missing: $file" }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1') {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.md') {
    $body = [IO.File]::ReadAllText($file.FullName)
    if ($body -match '(?im)\bTODO\b|\[TODO') { throw "Unfinished scaffold: $($file.Name)" }
    foreach ($link in [regex]::Matches($body,'\]\(([^)]+)\)')) {
        $target = $link.Groups[1].Value
        if ($target -match '^(https?://|#)') { continue }
        $target = $target.Split('#')[0]
        if (!(Test-Path -LiteralPath (Join-Path $file.DirectoryName $target))) { throw "Broken reference: $target" }
    }
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
    $body = [IO.File]::ReadAllText($file.FullName)
    if ($body -match '(?i)[A-Z]:[\\/]Users[\\/][^\\/\s]+[\\/]') { throw "Machine-specific profile path: $($file.Name)" }
}
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root 'scripts/course-ui.ps1')))) -SkillRoot $root -Port 65534
$authorizationStopped = $false
try { Submit-CourseHomework 'offline-test-target' }
catch { if ($_.Exception.Message -like '*current user*authorize*') { $authorizationStopped = $true } else { throw } }
if (!$authorizationStopped) { throw 'Submission authorization guard failed' }
'PASS: required files, PowerShell syntax, Markdown links, portable paths, submission authorization guard'
