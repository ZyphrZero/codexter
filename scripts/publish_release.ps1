param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$DistDir = 'dist'
)

$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Tag -cne "v$Version") { throw '发布版本与 Tag 不匹配' }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw '无效的发布仓库' }
if (-not $env:GH_TOKEN) { throw '缺少 GitHub 发布凭据' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$distPath = if ([IO.Path]::IsPathRooted($DistDir)) { $DistDir } else { Join-Path $projectRoot $DistDir }

function Invoke-Gh {
    param([string[]]$Arguments)
    & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI 失败：$($Arguments[0]) $($Arguments[1])" }
}

$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
function Get-LatestRelease {
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    } catch {
        # 仅 404 表示尚无正式版；权限、网络、限流错误必须停止发布。
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}
function Get-TagRelease {
    # /releases/tags/{tag} 只查询已公开版本；必须使用含草稿的鉴权列表并翻页。
    $page = 1
    do {
        $items = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page" -Headers $headers
        $found = @($items | Where-Object { $_.tag_name -ceq $Tag })
        if ($found.Count -gt 1) { throw '存在多个同名草稿，请先在 GitHub 核对' }
        if ($found.Count -eq 1) { return $found[0] }
        $page++
    } while ($items.Count -eq 100)
    return $null
}

# 发布前统一生成清单，任一平台缺包都会在创建 Release 前失败。
& "$PSScriptRoot/generate_update_manifest.ps1" -Version $Version -Tag $Tag -Repository $Repository -DistDir $distPath -RequireMacOS
$names = @("Codexter-$Version-Setup.exe", "Codexter-$Version-windows-x64.zip", "Codexter-$Version-macos-universal.zip", 'latest.json')
$files = @($names | ForEach-Object { Join-Path $distPath $_ })
$existing = Get-TagRelease
if ($existing -and -not $existing.draft) { throw '该版本已正式发布；请增加版本号，不覆盖用户正在下载的文件' }
$latest = Get-LatestRelease
if ($latest) {
    if ($latest.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { throw '无法判断现有最新版本，停止发布以避免回退' }
    if ([version]$Version -le [version]$Matches[1]) { throw '新版本必须高于当前最新版本，禁止覆盖更新入口' }
}

if (-not $existing) {
    # 默认要求目标仓库 Tag 已存在；独立发布仓库的 Tag 由维护者提前创建。
    Invoke-Gh -Arguments @('release', 'create', $Tag, '--repo', $Repository, '--verify-tag', '--draft', '--title', "Codexter $Version", '--notes', 'Windows 安装版 / 便携版；MacOS Universal ZIP（本机临时签名，未公证）。')
}
# 重试仅覆盖未公开的草稿资产；正式版本拒绝覆盖。
Invoke-Gh -Arguments (@('release', 'upload', $Tag, '--repo', $Repository, '--clobber') + $files)
$draft = Get-TagRelease
if (-not $draft -or -not $draft.draft) { throw '发布对象不再是草稿，停止操作' }
foreach ($name in $names) {
    $asset = @($draft.assets | Where-Object { $_.name -ceq $name })
    $local = Get-Item -LiteralPath (Join-Path $distPath $name)
    if ($asset.Count -ne 1 -or $asset[0].state -ne 'uploaded' -or $asset[0].size -ne $local.Length) {
        throw "草稿资产校验失败：$name"
    }
    # GitHub 支持资产 digest 时同时比对内容，不只比对名称和大小。
    if ($asset[0].digest) {
        $digest = 'sha256:' + (Get-FileHash $local.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($asset[0].digest -cne $digest) { throw "草稿资产摘要不匹配：$name" }
    }
}
Invoke-Gh -Arguments @('release', 'edit', $Tag, '--repo', $Repository, '--draft=false', '--latest')
Write-Host "已完整发布 $Repository $Tag"
