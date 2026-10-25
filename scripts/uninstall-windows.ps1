# 卸载 Windows 定时同步
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1 [-RepoPath D:\dev\proj]
#   powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1 -All
param(
    [string]$RepoPath = (Join-Path $PSScriptRoot '..'),
    [switch]$All
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'anywhere'

if ($All) {
    $pattern = 'anywhere-autosync-*'
} else {
    $RepoPath = (Resolve-Path $RepoPath).Path.TrimEnd('\', '/')
    $name = (Split-Path $RepoPath -Leaf) -replace '[^A-Za-z0-9_-]', '-'
    $bytes = [Text.Encoding]::UTF8.GetBytes($RepoPath)
    $hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new($bytes)) -Algorithm SHA1).Hash.Substring(0, 8).ToLower()
    $pattern = "anywhere-autosync-$name-$hash"
}

Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $dir "$($_.TaskName).vbs")
    Write-Host "🗑  已卸载: $($_.TaskName)"
}
