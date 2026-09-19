param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Repository = 'meesii/codexter',
    [string]$DistDir = 'dist',
    [string]$AssetBaseUrl = '',
    [switch]$RequireMacOS
)

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Tag -cne "v$Version") {
    throw '版本必须为正式版本，且 Tag 必须等于 v + 版本号'
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw '无效的发布仓库' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$distPath = if ([IO.Path]::IsPathRooted($DistDir)) { $DistDir } else { Join-Path $projectRoot $DistDir }
$setupName = "Codexter-$Version-Setup.exe"
$zipName = "Codexter-$Version-windows-x64.zip"
$setupPath = Join-Path $distPath $setupName
$zipPath = Join-Path $distPath $zipName

if (-not (Test-Path $setupPath)) { throw "Installer not found: $setupPath" }
if (-not (Test-Path $zipPath)) { throw "Portable ZIP not found: $zipPath" }
$macName = "Codexter-$Version-macos-universal.zip"
$macPath = Join-Path $distPath $macName
if ($RequireMacOS -and -not (Test-Path -LiteralPath $macPath -PathType Leaf)) {
    throw "MacOS 包缺失，不能发布不完整的更新清单：$macPath"
}
$requiredFiles = @($setupPath, $zipPath)
if (Test-Path -LiteralPath $macPath -PathType Leaf) { $requiredFiles += $macPath }
foreach ($file in $requiredFiles) {
    if ((Get-Item -LiteralPath $file).Length -eq 0) { throw "不能发布空文件：$file" }
}

if (-not $AssetBaseUrl) {
    $AssetBaseUrl = "https://github.com/$Repository/releases/download/$Tag"
}
$AssetBaseUrl = $AssetBaseUrl.TrimEnd('/')

$manifest = [ordered]@{
    schema = 1
    version = $Version
    tag = $Tag
    published_at = [DateTime]::UtcNow.ToString('o')
    release_url = "https://github.com/$Repository/releases/tag/$Tag"
    windows = [ordered]@{
        installer_url = "$AssetBaseUrl/$setupName"
        installer_sha256 = (Get-FileHash $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        portable_url = "$AssetBaseUrl/$zipName"
        portable_sha256 = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

# 保留 schema=1 和 Windows 字段，兼容已经发布的旧版客户端。
if (Test-Path -LiteralPath $macPath -PathType Leaf) {
    $manifest.macos = [ordered]@{
        archive_url = "$AssetBaseUrl/$macName"
        archive_sha256 = (Get-FileHash $macPath -Algorithm SHA256).Hash.ToLowerInvariant()
        architectures = @('arm64', 'x86_64')
        update_mode = 'manual'
    }
}

$output = Join-Path $distPath 'latest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $output -Encoding utf8NoBOM
Write-Host "==> Update manifest: $output"
