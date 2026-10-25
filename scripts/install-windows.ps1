# 在 Windows 上为某个仓库安装定时自动同步（任务计划程序）
# 依赖: Git for Windows（自带 Git Bash）
# 用法（PowerShell）:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 [-RepoPath D:\dev\proj] [-IntervalMinutes 10]
param(
    [string]$RepoPath = (Join-Path $PSScriptRoot '..'),
    [ValidateRange(1, 525600)]
    [int]$IntervalMinutes = 10
)
$ErrorActionPreference = 'Stop'

$RepoPath = (Resolve-Path $RepoPath).Path.TrimEnd('\', '/')
$script = Join-Path $PSScriptRoot 'autosync.sh'
# Reject command-shell metacharacters before generating the wscript/bash command.
foreach ($path in @($RepoPath, $script)) {
    foreach ($code in @(10, 13, 33, 34, 36, 37, 38, 39, 60, 62, 94, 96, 124)) {
        if ($path.Contains([string][char]$code)) { throw 'Unsupported shell character in path; use a plain local drive path.' }
    }
}
if ($RepoPath -notmatch '^[A-Za-z]:\\') { throw 'Use a local drive path; UNC paths are not supported.' }

$bash = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $bash) { throw '未找到 Git for Windows (bash.exe)，请先安装: https://git-scm.com/download/win' }

function ConvertTo-PosixPath([string]$p) {
    $p = $p -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLower() + $Matches[2] }
    return $p
}

& $bash (ConvertTo-PosixPath $script) '--dry-run' (ConvertTo-PosixPath $RepoPath)
if ($LASTEXITCODE -ne 0) { throw 'Repository preflight failed; configure Git remotes before installing.' }

$name = (Split-Path $RepoPath -Leaf) -replace '[^A-Za-z0-9_-]', '-'
$bytes = [Text.Encoding]::UTF8.GetBytes($RepoPath)
$hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new($bytes)) -Algorithm SHA1).Hash.Substring(0, 8).ToLower()
$taskName = "anywhere-autosync-$name-$hash"

# 用 VBScript 包一层，后台静默运行，不弹黑窗口
$dir = Join-Path $env:LOCALAPPDATA 'anywhere'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$vbs = Join-Path $dir "$taskName.vbs"
$cmd = "`"$bash`" -lc `"ANYWHERE_DAEMON=1 '$(ConvertTo-PosixPath $script)' '$(ConvertTo-PosixPath $RepoPath)'`""
$vbsLines = @(
    'Set shell = CreateObject("WScript.Shell")'
    ('exitCode = shell.Run("' + ($cmd -replace '"', '""') + '", 0, True)')
    'WScript.Quit exitCode'
)
Set-Content -Path $vbs -Value $vbsLines -Encoding Unicode

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
# 单次运行最长 30 分钟，超时由任务计划程序结束。macOS 的 launchd 任务没有对应上限。
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# 普通用户权限下注册 AtLogOn 触发器可能报 0x80070005 拒绝访问，自动回退到纯时间触发器
try {
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($repeat, $logon) `
        -Settings $settings -Description "anywhere autosync: $RepoPath" -Force -ErrorAction Stop | Out-Null
} catch {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($repeat) `
        -Settings $settings -Description "anywhere autosync: $RepoPath" -Force | Out-Null
}

Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

Write-Host "✅ 已安装: $taskName"
Write-Host "   仓库: $RepoPath"
Write-Host "   间隔: $IntervalMinutes 分钟"
Write-Host "   日志: $env:USERPROFILE\.anywhere\logs\autosync.log"
