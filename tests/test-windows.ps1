# Run with Windows PowerShell 5.1, using temporary local repositories only.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
$temp = Join-Path $env:TEMP ('anywhere-installer-' + [Guid]::NewGuid().ToString('N'))
$repo = Join-Path $temp 'project with spaces'
$bare = Join-Path $temp 'remote.git'
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    git init --bare $bare
    if ($LASTEXITCODE) { throw 'bare init failed' }
    git init -b main $repo
    git -C $repo config user.name Test
    git -C $repo config user.email test@example.invalid
    git -C $repo remote add origin ($bare -replace '\\', '/')
    Set-Content -Path (Join-Path $repo 'README.txt') -Value 'installer test'
    git -C $repo add .
    git -C $repo commit -m initial
    git -C $repo push origin main
    if ($LASTEXITCODE) { throw 'repository setup failed' }
    & (Join-Path $root 'scripts/install-windows.ps1') -RepoPath $repo -IntervalMinutes 1
    $bytes = [Text.Encoding]::UTF8.GetBytes($repo.TrimEnd('\', '/'))
    $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new($bytes)) -Algorithm SHA1).Hash.Substring(0, 8).ToLower()
    $taskName = "anywhere-autosync-project-with-spaces-$hash"
    $task = Get-ScheduledTask -TaskName $taskName
    if (-not $task) { throw 'task was not registered' }
    # Execute the generated VBS synchronously, so quoting errors cannot hide behind task registration.
    $vbs = Join-Path $env:LOCALAPPDATA "anywhere/$taskName.vbs"
    & cscript.exe //NoLogo $vbs
    if ($LASTEXITCODE) { throw 'generated launch command failed' }
    & (Join-Path $root 'scripts/uninstall-windows.ps1') -RepoPath ($repo + '\')
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'task survived uninstall' }
    if (Test-Path $vbs) { throw 'VBS survived uninstall' }
    Write-Host 'Windows parse, install, generated launcher and uninstall checks passed.'
} finally {
    if ($taskName) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
}
