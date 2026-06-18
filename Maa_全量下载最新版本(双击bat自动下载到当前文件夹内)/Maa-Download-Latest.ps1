<#:
.SYNOPSIS
    MAA 最新版一键下载 — 无代理，多冗余
.DESCRIPTION
    从 api.maa.plus 获取最新版本信息，通过镜像/直链下载到当前目录。
    具备主备 API、镜像降级、下载重试、文件校验等冗余机制。
#>

param(
    [ValidateSet('stable', 'beta', 'alpha')]
    [string]$Channel = 'stable'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$ApiBase1 = 'https://api.maa.plus/MaaAssistantArknights/api'
$ApiBase2 = 'https://api2.maa.plus/MaaAssistantArknights/api'
$MirrorHosts = @(
    'https://agent.imgg.dev',
    'https://ghproxy.net/https://github.com',
    'https://gh-proxy.com/https://github.com'
)
$GithubProxies = @(
    'https://ghproxy.net/',
    'https://gh-proxy.com/'
)
$SummaryApi = 'version/summary.json'
$RetryMax = 3

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Write-Step  { Write-Host "`n>>> $($args[0])" -ForegroundColor Magenta }
function Write-Info  { Write-Host "[信息] $($args[0])" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "[成功] $($args[0])" -ForegroundColor Green }
function Write-Warn  { Write-Host "[注意] $($args[0])" -ForegroundColor Yellow }
function Write-Err   { Write-Host "[错误] $($args[0])" -ForegroundColor Red }

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Start-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0)

    Write-Host '⚠ 正在下载，请不要关闭此窗口！根据网络状况可能需要几分钟。' -ForegroundColor Black -BackgroundColor Yellow

    $useCurl = $null -ne (Get-Command curl.exe -ErrorAction SilentlyContinue)

    for ($try = 1; $try -le $RetryMax; $try++) {
        if ($try -gt 1) {
            Write-Warn "下载重试 ($try/$RetryMax)..."
            Start-Sleep 2
        }
        try {
            if (Test-Path $OutFile) { Remove-Item -Force $OutFile }

            if ($useCurl) {
                Write-Info "使用 curl.exe 下载..."
                $result = curl.exe -sSfL -o "$OutFile" "$Url" -A 'MAA-DL/1.0' --connect-timeout 15 --max-time 600 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "curl 返回退出码 $LASTEXITCODE : $result"
                }
            } else {
                Write-Info "使用 WebClient 下载..."
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent', 'MAA-DL/1.0')
                $wc.DownloadFile($Url, $OutFile)
            }

            if (-not (Test-Path $OutFile)) {
                throw "输出文件未创建"
            }
            $actualSize = (Get-Item $OutFile).Length
            if ($ExpectedSize -gt 0 -and $actualSize -ne $ExpectedSize) {
                Write-Warn "文件大小不匹配: 期望 $(Format-FileSize $ExpectedSize), 实际 $(Format-FileSize $actualSize)"
                Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
                continue
            }
            Write-Ok "$DisplayName 下载完成 ($(Format-FileSize $actualSize))"
            return $true
        }
        catch {
            Write-Warn "下载失败: $($_.Exception.Message.Trim())"
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        }
    }
    Write-Err "$DisplayName 下载失败（已重试 $RetryMax 次）"
    return $false
}

# ======== 主流程 ========
Write-Step '获取最新版本信息'

$summary = $null
foreach ($base in @($ApiBase1, $ApiBase2)) {
    $url = "$base/$SummaryApi"
    Write-Info "请求版本摘要: $url"
    try {
        $summary = Invoke-RestMethod $url -TimeoutSec 10
        if ($summary.$Channel) { break }
    }
    catch {
        Write-Warn "API 不可达: $url"
    }
}

if (-not $summary -or -not $summary.$Channel) {
    Write-Err '无法获取版本信息（所有 API 均不可用）'
    exit 1
}

$latestVer = $summary.$Channel.version
$detailUrl = $summary.$Channel.detail
Write-Ok "最新 $Channel 版本: $latestVer"

$detail = $null
try { $detail = Invoke-RestMethod $detailUrl -TimeoutSec 10 }
catch {}
if (-not $detail) {
    $backupUrl = "$ApiBase2/version/$Channel.json"
    try { $detail = Invoke-RestMethod $backupUrl -TimeoutSec 10 }
    catch {}
}
if (-not $detail) {
    Write-Err '无法获取版本详情'
    exit 1
}

$asset = $null
foreach ($a in $detail.details.assets) {
    if ($a.name -match "^MAA-v[\d\.]+\-win-x64\.zip$") { $asset = $a; break }
}
if (-not $asset) {
    Write-Err '未找到适用于 win-x64 的更新包'
    exit 1
}

$filename = $asset.name
$originalUrl = $asset.browser_download_url
$expectedSize = [long]$asset.size
$filepath = Join-Path $ScriptDir $filename
$mirrorUrls = $MirrorHosts | ForEach-Object { $originalUrl -replace 'https://github\.com/', "$_/" }

Write-Info "文件名: $filename"
Write-Info "文件大小: $(Format-FileSize $expectedSize)"
Write-Info "原始地址: $originalUrl"
foreach ($mu in $mirrorUrls) { Write-Info "镜像地址: $mu" }

# ======== 下载（多镜像轮换 → 代理 → 原始）========
Write-Step '开始下载'

$tryOrder = @()
foreach ($mu in $mirrorUrls) { $tryOrder += $mu }
foreach ($p in $GithubProxies) { $tryOrder += "$p$originalUrl" }
$tryOrder += $originalUrl

$downloadOk = $false
foreach ($url in $tryOrder) {
    if (Start-Download -Url $url -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize) {
        $downloadOk = $true
        break
    }
    Write-Warn "下载源不可用，尝试下一个..."
}

if (-not $downloadOk) {
    Write-Err '所有下载源均失败'
    exit 1
}

Write-Ok "MAA $latestVer 下载成功!"
Write-Info "文件: $filepath"
exit 0
