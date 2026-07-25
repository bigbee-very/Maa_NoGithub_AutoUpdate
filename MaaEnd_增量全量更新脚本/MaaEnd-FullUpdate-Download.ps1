<#:
.SYNOPSIS
    MaaEnd 最新版一键下载覆盖 — 无代理，多冗余
.DESCRIPTION
    从 GitHub API 获取最新版本，通过镜像/直链下载到当前目录。
    如果当前目录是 MaaEnd 安装目录，自动清理旧文件并解压覆盖。
    具备 GitHub API 冗余、镜像降级、SHA256 校验等容错机制。
.AUTHOR
    bigbee
#>

param(
    [ValidateSet('stable', 'beta')]
    [string]$Channel = 'stable',
    [switch]$Silent
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
# SSL/TLS 协议设置
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
[System.Net.ServicePointManager]::DefaultConnectionLimit = 8

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogFile = Join-Path $ScriptDir "update.log"

if (Test-Path $LogFile) { Remove-Item -Force $LogFile -ErrorAction SilentlyContinue }

function Write-Log {
    param([string]$Level, [string]$Message)
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$time][$Level] $Message" -Encoding UTF8
}

$script:HttpsProxy = ''
if ($env:HTTPS_PROXY) { $script:HttpsProxy = $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $script:HttpsProxy = $env:HTTP_PROXY }
if (-not $script:HttpsProxy) {
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $proxyEnabled = (Get-ItemProperty -Path $regPath -Name 'ProxyEnable' -ErrorAction SilentlyContinue).ProxyEnable
        $proxyServer = (Get-ItemProperty -Path $regPath -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
        if ($proxyEnabled -and $proxyServer) { $script:HttpsProxy = "http://$proxyServer"; if (-not $Silent) { Write-Host "[信息] 检测到系统代理: $proxyServer" -ForegroundColor Cyan } }
    } catch {}
}

$MirrorHosts = @('https://gh.ddlc.top', 'https://gh-proxy.com')
$GithubProxies = @('https://gh.ddlc.top/', 'https://gh-proxy.com/')
$RetryMax = 3
$PreserveDirs = @('config', 'debug')
$UpdateScripts = @(
    'MaaEnd-FullUpdate-Download.ps1',
    'MaaEnd-全量更新-静默.bat',
    'MaaEnd-全量更新-Debug.bat',
    'MaaEnd-全量更新-静默(beta).bat',
    'MaaEnd-全量更新-Debug(beta).bat',
    '使用前阅读此文件.txt',
    'update.log',
    # 隐藏目录和文件保护
    '.update_temp',
    '.update_backup',
    '.update_state',
    '.pwsh',
    'cache'
)

$ApiBase = 'https://api.github.com/repos/MaaEnd/MaaEnd/releases'

function Write-Step { $m = $args[0]; Write-Host "`n>>> $m" -ForegroundColor Magenta; Write-Log 'STEP' $m }
function Write-Info { $m = $args[0]; Write-Host "[信息] $m" -ForegroundColor Cyan; Write-Log 'INFO' $m }
function Write-Ok { $m = $args[0]; Write-Host "[成功] $m" -ForegroundColor Green; Write-Log 'OK' $m }
function Write-Warn { $m = $args[0]; Write-Host "[注意] $m" -ForegroundColor Yellow; Write-Log 'WARN' $m }
function Write-Err { $m = $args[0]; Write-Host "[错误] $m" -ForegroundColor Red; Write-Log 'ERROR' $m }

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Invoke-GitHubApi {
    param([string]$Url, [int]$TimeoutSec = 15)
    # 先直连，失败再走代理
    foreach ($useProxy in @($false, $true)) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'; $req.Timeout = $TimeoutSec * 1000; $req.ReadWriteTimeout = $TimeoutSec * 1000
            $req.UserAgent = 'MaaEnd-Update/1.0'
            $req.Accept = 'application/vnd.github.v3+json'
            if ($useProxy -and $script:HttpsProxy) { $req.Proxy = New-Object System.Net.WebProxy($script:HttpsProxy) }
            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $json = $reader.ReadToEnd(); $resp.Close(); $reader.Close()
            return ($json | ConvertFrom-Json)
        }
        catch {
            if ($useProxy) { return $null }
        }
    }
    return $null
}

function Invoke-GitHubScrape {
    param([string]$Channel)
    # API 不可达时，从 github.com 网页抓取 tags 列表
    try {
        $req = [System.Net.HttpWebRequest]::Create('https://github.com/MaaEnd/MaaEnd/tags')
        $req.Method = 'GET'; $req.Timeout = 15000; $req.ReadWriteTimeout = 15000
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        if ($script:HttpsProxy) { $req.Proxy = New-Object System.Net.WebProxy($script:HttpsProxy) }
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $html = $reader.ReadToEnd(); $resp.Close(); $reader.Close()
        $tags = @()
        foreach ($m in [regex]::Matches($html, '/MaaEnd/MaaEnd/releases/tag/([^"''<>\s]+)')) {
            $t = $m.Groups[1].Value; if ($t -notin $tags) { $tags += $t }
        }
        if ($tags.Count -eq 0) { return $null }
        if ($Channel -eq 'stable') {
            $tagName = $tags | Where-Object { $_ -notmatch '(beta|rc|alpha|pre)' } | Select-Object -First 1
        } else {
            $tagName = $tags | Where-Object { $_ -match '(beta|rc|alpha|pre)' } | Select-Object -First 1
        }
        if (-not $tagName) { return $null }
        return @{ tag_name = $tagName }
    }
    catch { return $null }
}

function Get-Sha256FromAsset {
    param($Asset)
    if ($Asset.digest) {
        $raw = [string]$Asset.digest
        if ($raw -match '^sha256:(.+)$') { return $matches[1] }
    }
    return $null
}

function Start-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0)

    if (-not $Silent) { Write-Host '⚠ 正在下载，请不要关闭此窗口！根据网络状况可能需要几分钟。' -ForegroundColor Black -BackgroundColor Yellow }

    $hasCurl = $null -ne (Get-Command curl.exe -ErrorAction SilentlyContinue)

    if ($hasCurl) {
        $curlArgs = @('-SfL', '-o', "$OutFile", '--progress-bar', '-A', 'MaaEnd-DL/1.0', '--connect-timeout', '15', '--max-time', '600', '--ssl-no-revoke')
        if ($script:HttpsProxy) { $curlArgs += '--proxy', $script:HttpsProxy }
        $curlArgs += $Url
        for ($try = 1; $try -le $RetryMax; $try++) {
            if ($try -gt 1) { Write-Warn "curl 重试 ($try/$RetryMax)..."; Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 2500) }
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
                Write-Warn "curl 失败"
                Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
            }
        }
        Write-Warn "curl 下载失败，切换到 WebClient..."
    }

    for ($try = 1; $try -le $RetryMax; $try++) {
        if ($try -gt 1) { Write-Warn "WebClient 重试 ($try/$RetryMax)..."; Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 2500) }
        try {
            if (Test-Path $OutFile) { Remove-Item -Force $OutFile }
            Write-Info "使用 WebClient ($Url)..."
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'MaaEnd-DL/1.0')
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
            Write-Warn "WebClient 失败"
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        }
    }
    Write-Err "$DisplayName 下载失败（curl、WebClient 均不可用）"
    return $false
}

function New-Directory {
    param([string]$Path, [switch]$Secure)
    if (-not (Test-Path $Path)) {
        $dir = New-Item -ItemType Directory -Path $Path -Force
        if ($Secure) {
            $acl = Get-Acl $Path
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $Path -AclObject $acl
        }
        $dir | Out-Null
    }
}

function Test-ZipPathSafety {
    param([string]$ZipPath, [string]$DestDir)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $destDirFull = [System.IO.Path]::GetFullPath($DestDir)
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $targetPath = [System.IO.Path]::Combine($destDirFull, $entry.FullName)
            $targetPathFull = [System.IO.Path]::GetFullPath($targetPath)
            if (-not $targetPathFull.StartsWith($destDirFull, [StringComparison]::OrdinalIgnoreCase)) {
                $zip.Dispose()
                return $false
            }
        }
        $zip.Dispose()
        return $true
    }
    catch { return $true }
}

function Expand-Zip {
    param([string]$ZipPath, [string]$DestDir)
    if (-not (Test-ZipPathSafety -ZipPath $ZipPath -DestDir $DestDir)) {
        throw "ZIP文件包含不安全路径，可能存在路径遍历攻击"
    }
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

function Get-LocalVersion {
    $iface = Join-Path $ScriptDir 'interface.json'
    if (-not (Test-Path $iface)) { return $null }
    try {
        $content = Get-Content $iface -Raw -Encoding UTF8
        if ($content -match '"version"\s*:\s*"([^"]+)"') { return $matches[1] }
    } catch {}
    return $null
}

function Install-To-MaaEndDir {
    param([string]$ZipPath)

    if (-not (Test-Path (Join-Path $ScriptDir 'MaaEnd.exe'))) {
        Write-Info '当前目录不是 MaaEnd 安装目录，跳过自动安装'
        return $false
    }

    Write-Step '检测到 MaaEnd 安装目录，执行自动安装'

    # 0. 关闭正在运行的 MaaEnd 进程
    $procNames = @('MaaEnd', 'MXU')
    foreach ($name in $procNames) {
        $running = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($running) {
            Write-Info "正在关闭 $name 进程..."
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }

    # 1. 备份保留目录
    $bakDir = Join-Path $env:TEMP "maaend_install_bak_$(Get-Random)"
    New-Directory $bakDir -Secure
    foreach ($dir in $PreserveDirs) {
        $src = Join-Path $ScriptDir $dir
        if (Test-Path $src) { Copy-Item -Recurse $src (Join-Path $bakDir $dir) -Force }
    }

    # 2. 白名单（不删除 + 不解压覆盖）
    $whitelist = $UpdateScripts + $PreserveDirs
    $zipName = Split-Path $ZipPath -Leaf
    if ($zipName -and $whitelist -notcontains $zipName) { $whitelist += $zipName }

    # 3. 清理非白名单文件和目录
    Write-Info '清理旧文件...'
    # 安全检查：防止删除当前脚本自身
    $currentScript = $MyInvocation.MyCommand.Path
    if ($currentScript) { $whitelist += (Split-Path $currentScript -Leaf) }

    Get-ChildItem $ScriptDir | ForEach-Object {
        if ($_.Name -in $whitelist) { return }
        # 跳过隐藏文件/目录（额外保护）
        if ($_.Attributes -band [IO.FileAttributes]::Hidden) { return }
        try {
            if ($_.PSIsContainer) { Remove-Item -Recurse -Force $_.FullName }
            else { Remove-Item -Force $_.FullName }
        }
        catch { Write-Warn "删除失败: $($_.Name)" }
    }

    # 4. 解压到临时目录
    Write-Info '解压更新包...'
    $extractDir = Join-Path $env:TEMP "maaend_extract_$(Get-Random)"
    New-Directory $extractDir -Secure
    Expand-Zip -ZipPath $ZipPath -DestDir $extractDir

    $entries = Get-ChildItem $extractDir
    $sourceDir = if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { $entries[0].FullName } else { $extractDir }

    # 5. 复制新文件（跳过白名单顶层目录，保留已有文件）
    Get-ChildItem $sourceDir -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($sourceDir.Length + 1)
        $topDir = ($rel -split '[\\/]')[0]
        if ($topDir -in $whitelist) { return }
        $dest = Join-Path $ScriptDir $rel
        if ($_.PSIsContainer) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        else { New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null; Copy-Item $_.FullName $dest -Force }
    }

    # 6. 恢复保留目录中的旧文件（跳过已有，保留新 zip 未覆盖的部分）
    foreach ($dir in $PreserveDirs) {
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

    # 7. 清理
    Remove-Item -Recurse -Force $bakDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue }

    # 8. 重启 MaaEnd
    $exePath = Join-Path $ScriptDir 'MaaEnd.exe'
    if (Test-Path $exePath) {
        Write-Info '正在启动 MaaEnd...'
        Start-Process -FilePath $exePath -ErrorAction SilentlyContinue
    }

    Write-Ok '自动安装完成！'
    return $true
}

# ======== 主流程 ========
Write-Step '获取最新版本信息'

$isArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM')
$arch = if ($isArm) { 'aarch64' } else { 'x86_64' }
Write-Info "检测到架构: $arch"

$release = $null
if ($Channel -eq 'stable') {
    $release = Invoke-GitHubApi "$ApiBase/latest"
} else {
    $list = Invoke-GitHubApi "$ApiBase`?per_page=10"
    if ($list) { $release = $list | Where-Object { $_.prerelease -eq $true } | Select-Object -First 1 }
}
# API 不可达时，用网页抓取作为备用
if (-not $release) {
    Write-Warn 'GitHub API 不可达，尝试备用方案...'
    $release = Invoke-GitHubScrape -Channel $Channel
}

if (-not $release) {
    Write-Err "无法获取 $Channel 版本信息"
    exit 1
}

$tagName = $release.tag_name
Write-Ok "最新 $Channel 版本: $tagName"

$localVer = Get-LocalVersion
if ($localVer) {
    Write-Info "本地版本: $localVer"
    if ($localVer -eq $tagName) {
        Write-Ok "已是最新版本，无需更新"
        exit 0
    }
}

# 匹配对应架构的 asset
$asset = $null
$filename = "MaaEnd-win-$arch-$tagName.zip"
$originalUrl = "https://github.com/MaaEnd/MaaEnd/releases/download/$tagName/$filename"
$expectedSize = 0
$expectedSha256 = $null

if ($release.assets) {
    $pattern = "^MaaEnd-win-$arch-$([regex]::Escape($tagName)).zip$"
    foreach ($a in $release.assets) {
        if ($a.name -match $pattern) { $asset = $a; break }
    }
    if ($asset) {
        $filename = $asset.name
        $originalUrl = $asset.browser_download_url
        $expectedSize = [long]$asset.size
        $expectedSha256 = Get-Sha256FromAsset $asset
    }
}
$filepath = Join-Path $ScriptDir $filename

$mirrorUrls = $MirrorHosts | ForEach-Object { "$_/$originalUrl" }
foreach ($p in $GithubProxies) {
    $proxyUrl = "$p$originalUrl"
    if ($mirrorUrls -notcontains $proxyUrl) { $mirrorUrls += $proxyUrl }
}

Write-Info "文件名: $filename"
Write-Info "文件大小: $(if ($expectedSize -gt 0) { Format-FileSize $expectedSize } else { '未知' })"
Write-Info "原始地址: $originalUrl"
foreach ($mu in $mirrorUrls) { Write-Info "镜像地址: $mu" }

# ======== 下载 ========
Write-Step '开始下载'

# 镜像优先，原链兜底
$tryOrder = @()
foreach ($mu in $mirrorUrls) { $tryOrder += $mu }
if ($script:HttpsProxy) { $tryOrder += $originalUrl }
if ($tryOrder -notcontains $originalUrl) { $tryOrder += $originalUrl }

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

# 下载成功后尝试自动安装到 MaaEnd 目录
$installed = Install-To-MaaEndDir -ZipPath $filepath
if (-not $installed) {
    Write-Ok "MaaEnd $tagName 下载成功!"
    if (Test-Path $filepath) { Write-Info "文件: $filepath" }
}
exit 0
