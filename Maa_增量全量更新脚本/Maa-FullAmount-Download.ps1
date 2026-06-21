<#:
.SYNOPSIS
    MAA 最新版一键下载覆盖 — 无代理，多冗余
.DESCRIPTION
    从 api.maa.plus 获取最新版本信息，通过镜像/直链下载到当前目录。
    如果当前目录是 MAA 安装目录，自动清理旧文件并解压覆盖。
    具备主备 API、镜像降级、下载重试、文件校验等冗余机制。
    支持 -Silent 静默模式，适用于 bat 批处理调用。
.AUTHOR
    bigbee
.PROJECT
    https://github.com/bigbee-very/Maa_NoGithub_AutoUpdate#maa-nogithub-autoupdate
#>

param(
    [ValidateSet('stable', 'beta', 'alpha')]
    [string]$Channel = 'stable',
    [switch]$Silent
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$script:HttpsProxy = ''
if ($env:HTTPS_PROXY) { $script:HttpsProxy = $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $script:HttpsProxy = $env:HTTP_PROXY }
if (-not $script:HttpsProxy) {
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $proxyEnabled = (Get-ItemProperty -Path $regPath -Name 'ProxyEnable' -ErrorAction SilentlyContinue).ProxyEnable
        $proxyServer = (Get-ItemProperty -Path $regPath -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
        if ($proxyEnabled -and $proxyServer) { $script:HttpsProxy = "http://$proxyServer"; Write-Info "检测到系统代理: $($script:HttpsProxy)" }
    } catch {}
}

$ApiBase1 = 'https://api.maa.plus/MaaAssistantArknights/api'
$ApiBase2 = 'https://api2.maa.plus/MaaAssistantArknights/api'
$MirrorHosts = @(
    'https://gh.ddlc.top',
    'https://gh-proxy.com',
    'https://agent.imgg.dev'
)
$GithubProxies = @(
    'https://gh.ddlc.top/',
    'https://gh-proxy.com/'
)
$SummaryApi = 'version/summary.json'
$RetryMax = 3

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Write-Step { Write-Host "`n>>> $($args[0])" -ForegroundColor Magenta }
function Write-Info { Write-Host "[信息] $($args[0])" -ForegroundColor Cyan }
function Write-Ok { Write-Host "[成功] $($args[0])" -ForegroundColor Green }
function Write-Warn { Write-Host "[注意] $($args[0])" -ForegroundColor Yellow }
function Write-Err { Write-Host "[错误] $($args[0])" -ForegroundColor Red }

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Start-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0)

    if (-not $Silent) { Write-Host '⚠ 正在下载，请不要关闭此窗口！根据网络状况可能需要几分钟。' -ForegroundColor Black -BackgroundColor Yellow }

    $hasCurl = $null -ne (Get-Command curl.exe -ErrorAction SilentlyContinue)

    # 1. curl（优先，TCP 栈优于 .NET）
    if ($hasCurl) {
        $curlArgs = @('-SfL', '-o', "$OutFile", '--progress-bar', '-A', 'MAA-DL/1.0', '--connect-timeout', '15', '--max-time', '600', '--ssl-no-revoke')
        if ($script:HttpsProxy) { $curlArgs += '--proxy', $script:HttpsProxy }
        $curlArgs += $Url
        for ($try = 1; $try -le $RetryMax; $try++) {
            if ($try -gt 1) {
                Write-Warn "curl 重试 ($try/$RetryMax)..."
                Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 2500)
            }
            try {
                if (Test-Path $OutFile) { Remove-Item -Force $OutFile }
                Write-Info "使用 curl.exe ($Url)..."
                & curl.exe @curlArgs
                if ($LASTEXITCODE -ne 0) { throw "curl 返回退出码 $LASTEXITCODE" }
                if (-not (Test-Path $OutFile)) { throw "输出文件未创建" }
                $actualSize = (Get-Item $OutFile).Length
                if ($ExpectedSize -gt 0 -and $actualSize -ne $ExpectedSize) {
                    Write-Warn "文件大小不匹配: 期望 $(Format-FileSize $ExpectedSize), 实际 $(Format-FileSize $actualSize)"
                    Remove-Item -Force $OutFile -ErrorAction SilentlyContinue; continue
                }
                Write-Ok "$DisplayName 下载完成 ($(Format-FileSize $actualSize))"
                return $true
            }
            catch {
                Write-Warn "curl 失败: $($_.Exception.Message.Trim())"
                Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
            }
        }
        Write-Warn "curl 下载失败，切换到 WebClient..."
    }

    # 2. WebClient（带进度）
    for ($try = 1; $try -le $RetryMax; $try++) {
        if ($try -gt 1) {
            Write-Warn "WebClient 重试 ($try/$RetryMax)..."
            Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 2500)
        }
        try {
            if (Test-Path $OutFile) { Remove-Item -Force $OutFile }
            Write-Info "使用 WebClient ($Url)..."
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'MAA-DL/1.0')
            if ($script:HttpsProxy) { $wc.Proxy = New-Object System.Net.WebProxy($script:HttpsProxy) }
            $wc.DownloadFile($Url, $OutFile)
            if (-not (Test-Path $OutFile)) { throw "输出文件未创建" }
            $actualSize = (Get-Item $OutFile).Length
            if ($ExpectedSize -gt 0 -and $actualSize -ne $ExpectedSize) {
                Write-Warn "文件大小不匹配: 期望 $(Format-FileSize $ExpectedSize), 实际 $(Format-FileSize $actualSize)"
                Remove-Item -Force $OutFile -ErrorAction SilentlyContinue; continue
            }
            Write-Ok "$DisplayName 下载完成 ($(Format-FileSize $actualSize))"
            return $true
        }
        catch {
            Write-Warn "WebClient 失败: $($_.Exception.Message.Trim())"
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        }
    }
    Write-Err "$DisplayName 下载失败（curl、WebClient 均不可用）"
    return $false
}

function Expand-Zip {
    param([string]$ZipPath, [string]$DestDir)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)
        return
    }
    catch { Write-Warn "ZipFile 解压失败，尝试 Shell COM..." }
    try {
        $shell = New-Object -ComObject Shell.Application
        $shell.NameSpace($DestDir).CopyHere($shell.NameSpace($ZipPath).Items(), 16)
        return
    }
    catch { throw "无法解压文件" }
}

function Install-To-MaaDir {
    param([string]$ZipPath)

    if (-not (Test-Path (Join-Path $ScriptDir 'MAA.exe'))) {
        Write-Info '当前目录不是 MAA 安装目录，跳过自动安装'
        return $false
    }

    Write-Step '检测到 MAA 安装目录，执行自动安装'

    # 1. 备份白名单目录（config/data/resource/debug）
    $bakDir = Join-Path $env:TEMP "maa_install_bak_$(Get-Random)"
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
    foreach ($dir in @('config', 'data', 'resource', 'debug')) {
        $src = Join-Path $ScriptDir $dir
        if (Test-Path $src) { Copy-Item -Recurse $src (Join-Path $bakDir $dir) -Force }
    }

    # 2. 白名单（不删除 + 不解压覆盖）
    $whitelist = @(
        'Maa-FullAmount-Download.ps1',
        'Maa-Increment-Update.ps1',
        'Maa-全量更新-静默.bat',
        'Maa-全量更新-Debug.bat',
        'Maa-增量-更新-Debug.bat',
        'Maa-增量-静默版本资源全部更新.bat',
        'Maa-增量-静默只更新版本.bat',
        '使用前阅读此文件.txt',
        'adb',
        'resource',
        'data',
        'config',
        'debug'
    )
    $zipName = Split-Path $ZipPath -Leaf
    if ($zipName -and $whitelist -notcontains $zipName) { $whitelist += $zipName }

    # 3. 清理非白名单文件和目录
    Write-Info '清理旧文件...'
    Get-ChildItem $ScriptDir | ForEach-Object {
        if ($_.Name -in $whitelist) { return }
        try {
            if ($_.PSIsContainer) { Remove-Item -Recurse -Force $_.FullName }
            else { Remove-Item -Force $_.FullName }
        }
        catch { Write-Warn "删除失败: $($_.Name) - $_" }
    }

    # 4. 解压
    Write-Info '解压更新包...'
    $extractDir = Join-Path $env:TEMP "maa_extract_$(Get-Random)"
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Expand-Zip -ZipPath $ZipPath -DestDir $extractDir

    $entries = Get-ChildItem $extractDir
    $sourceDir = if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { $entries[0].FullName } else { $extractDir }

    # 复制到 ScriptDir（跳过白名单顶层目录，保留已有文件）
    Get-ChildItem $sourceDir -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($sourceDir.Length + 1)
        $topDir = ($rel -split '[\\/]')[0]
        if ($topDir -in $whitelist) { return }
        $dest = Join-Path $ScriptDir $rel
        if ($_.PSIsContainer) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        else { New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null; Copy-Item $_.FullName $dest -Force }
    }
    
    # 5. 恢复白名单目录中的旧文件（跳过已有，保留新 zip 未覆盖的部分）
    foreach ($dir in @('config', 'data', 'resource', 'debug')) {
        $bakPath = Join-Path $bakDir $dir
        if (-not (Test-Path $bakPath)) { continue }
        Get-ChildItem $bakPath -Recurse | ForEach-Object {
            $rel = $_.FullName.Substring($bakPath.Length + 1)
            if (-not $rel) { return }
            $target = [System.IO.Path]::Combine($ScriptDir, $dir, $rel)
            if ($_.PSIsContainer) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
            else {
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                if (-not (Test-Path $target)) { Copy-Item $_.FullName $target -Force }
            }
        }
    }

    # 6. 清理
    Remove-Item -Recurse -Force $bakDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue }

    Write-Ok '自动安装完成！'
    return $true
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
$expectedSha256 = $asset.sha256
$filepath = Join-Path $ScriptDir $filename
$mirrorUrls = $MirrorHosts | ForEach-Object { "$_/$originalUrl" }
if ($GithubProxies) {
    foreach ($p in $GithubProxies) {
        $proxyUrl = "$p$originalUrl"
        if ($mirrorUrls -notcontains $proxyUrl) { $mirrorUrls += $proxyUrl }
    }
}

Write-Info "文件名: $filename"
Write-Info "文件大小: $(Format-FileSize $expectedSize)"
Write-Info "原始地址: $originalUrl"
foreach ($mu in $mirrorUrls) { Write-Info "镜像地址: $mu" }

# ======== 下载（镜像优先 → 代理直连兜底）========
Write-Step '开始下载'

$tryOrder = @()
foreach ($mu in $mirrorUrls) { $tryOrder += $mu }
# 完整包大（250MB），镜像优先省代理流量，代理直连最后兜底
if ($script:HttpsProxy) { $tryOrder += $originalUrl }
if ($tryOrder -notcontains $originalUrl) { $tryOrder += $originalUrl }

# HEAD 测速排序
Write-Info "正在测试下载源可用性..."
$scoredSources = New-Object System.Collections.Generic.List[object]
$testedCount = 0; $allUrls = $tryOrder
foreach ($u in $allUrls) {
    if ($testedCount -ge 8) { break }
    try {
        $req = [System.Net.HttpWebRequest]::Create($u)
        $req.Method = 'HEAD'; $req.Timeout = 3000; $req.ReadWriteTimeout = 3000
        $req.UserAgent = 'MAA-DL/1.0'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $req.GetResponse()
        $sw.Stop(); $resp.Close()
        $scoredSources.Add(@{ Url = $u; Ms = $sw.ElapsedMilliseconds })
    } catch { continue }
    $testedCount++
}
if ($scoredSources.Count -gt 0) {
    $testedSet = @{}; $tryOrder = @()
    foreach ($s in ($scoredSources | Sort-Object Ms)) { $tryOrder += $s.Url; $testedSet[$s.Url] = $true }
    foreach ($u in $allUrls) { if (-not $testedSet.ContainsKey($u)) { $tryOrder += $u } }
    Write-Info "最佳源: ($(($scoredSources | Sort-Object Ms)[0].Ms)ms)"
}

$downloadOk = $false
foreach ($url in $tryOrder) {
    if (Start-Download -Url $url -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize) {
        if ($expectedSha256) {
            Write-Info '验证 SHA256...'
            $hash = Get-FileHash $filepath -Algorithm SHA256
            if ($hash.Hash -ne $expectedSha256) {
                Write-Warn 'SHA256 校验失败，尝试下一个源'
                Remove-Item -Force $filepath -ErrorAction SilentlyContinue
                continue
            }
            Write-Ok 'SHA256 校验通过'
        }
        $downloadOk = $true
        break
    }
    Write-Warn "下载源不可用，尝试下一个..."
}

if (-not $downloadOk) {
    Write-Err '所有下载源均失败'
    exit 1
}

# 下载成功后尝试自动安装到 MAA 目录
$installed = Install-To-MaaDir -ZipPath $filepath
if (-not $installed) {
    Write-Ok "MAA $latestVer 下载成功!"
    if (Test-Path $filepath) { Write-Info "文件: $filepath" }
}
exit 0
