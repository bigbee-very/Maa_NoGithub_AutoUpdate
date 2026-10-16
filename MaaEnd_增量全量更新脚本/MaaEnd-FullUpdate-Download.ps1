<#:
.SYNOPSIS
    MaaEnd 最新版一键下载覆盖 — 无代理 v2.0（语义化版本 + 智能路由）
.DESCRIPTION
    从 GitHub API 获取最新版本，通过镜像/直链下载到当前目录。
    如果当前目录是 MaaEnd 安装目录，自动清理旧文件并解压覆盖。
    具备 API 主备 + 网页抓取降级、语义化版本比较、跨通道取最新、
    下载线路探测、镜像降级、SHA256 校验等容错机制。
.PARAMETER Channel
    stable / beta。beta 会同时比较正式版与预发布版，取语义化版本更高者。
.PARAMETER Force
    强制重新下载安装（版本相同时也会执行）。
.PARAMETER DryRun
    只探测版本与下载线路，不实际下载、不安装。
.PARAMETER SelfTest
    仅运行内置纯函数自测，不进行任何网络或文件操作。
.AUTHOR
    bigbee
#>

param(
    [ValidateSet('stable', 'beta')]
    [string]$Channel = 'stable',
    [switch]$Silent,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
# SSL/TLS 协议设置
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
[System.Net.ServicePointManager]::DefaultConnectionLimit = 8

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogFile = Join-Path $ScriptDir "update_log.txt"
$script:HasCurl = $null -ne (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)

$MirrorHosts = @(
    'https://gh-proxy.com',
    'https://ghproxy.net',
    'https://gh.ddlc.top',
    'https://ghproxy.homeboyc.cn'
)
$RetryMax = 3
$PreserveDirs = @('config', 'debug')
$RepoSlug = 'MaaEnd/MaaEnd'
$ApiBase = "https://api.github.com/repos/$RepoSlug/releases"
$UpdateScripts = @(
    'MaaEnd-FullUpdate-Download.ps1',
    'MaaEnd-全量更新-静默.bat',
    'MaaEnd-全量更新-Debug.bat',
    'MaaEnd-全量更新-静默(beta).bat',
    'MaaEnd-全量更新-Debug(beta).bat',
    '使用前阅读此文件.txt',
    'update_log.txt',
    'update.log',
    # 隐藏目录和文件保护
    '.update_temp',
    '.update_backup',
    '.update_state',
    '.pwsh',
    'cache'
)

function Write-Log {
    param([string]$Level, [string]$Message)
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # 自测模式只打印，不写文件（否则会在脚本目录留下无意义的 update_log.txt）
    if (-not $SelfTest) { Add-Content -Path $LogFile -Value "[$time][$Level] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function Write-Step { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor Magenta; Write-Log 'STEP' $Msg }
function Write-Info { param([string]$Msg) Write-Host "[信息] $Msg" -ForegroundColor Cyan; Write-Log 'INFO' $Msg }
function Write-Ok { param([string]$Msg) Write-Host "[成功] $Msg" -ForegroundColor Green; Write-Log 'OK' $Msg }
function Write-Warn { param([string]$Msg) Write-Host "[注意] $Msg" -ForegroundColor Yellow; Write-Log 'WARN' $Msg }
function Write-Err { param([string]$Msg) Write-Host "[错误] $Msg" -ForegroundColor Red; Write-Log 'ERROR' $Msg }

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return '未知' }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# ======== 代理探测 ========
# 返回 @{ Url = <可用地址>; ForCurl = <curl 参数值>; Socks = <bool> }
# SOCKS 代理无法交给 .NET WebProxy 使用，此时交给 curl，其它引擎走直连。
function Resolve-ProxyConfig {
    param([string]$RawValue)
    $cfg = @{ Url = ''; ForCurl = $null; Socks = $false }
    $raw = ''
    if ($RawValue) { $raw = ([string]$RawValue).Trim() }
    if (-not $raw) { return $cfg }

    # 形如 "http=127.0.0.1:7897;https=127.0.0.1:7897" 的按协议代理列表
    if ($raw -match '=' -and $raw -match ';|=') {
        foreach ($part in ($raw -split ';')) {
            $kv = $part -split '=', 2
            if ($kv.Count -eq 2 -and $kv[0].Trim() -in @('https', 'http')) {
                $raw = $kv[1].Trim()
                if ($kv[0].Trim() -eq 'https') { break }
            }
        }
        if ($raw -match '=') { return $cfg }
    }
    if ($raw -notmatch '://') { $raw = "http://$raw" }

    if ($raw -match '^(socks4|socks4a|socks5|socks5h)://') {
        $cfg.Socks = $true
        $cfg.Url = $raw
        $cfg.ForCurl = $raw
        return $cfg
    }
    $uri = $null
    if (-not [System.Uri]::TryCreate($raw, [System.UriKind]::Absolute, [ref]$uri)) { return $cfg }
    $norm = "$($uri.Scheme)://$($uri.Host)"
    if (-not $uri.IsDefaultPort) { $norm += ":$($uri.Port)" }
    $cfg.Url = $norm
    $cfg.ForCurl = $norm
    return $cfg
}

function Initialize-Proxy {
    $raw = ''
    $source = ''
    if ($env:HTTPS_PROXY) { $raw = $env:HTTPS_PROXY; $source = '环境变量 HTTPS_PROXY' }
    elseif ($env:HTTP_PROXY) { $raw = $env:HTTP_PROXY; $source = '环境变量 HTTP_PROXY' }
    if (-not $raw) {
        try {
            $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            $proxyEnabled = (Get-ItemProperty -Path $regPath -Name 'ProxyEnable' -ErrorAction SilentlyContinue).ProxyEnable
            $proxyServer = (Get-ItemProperty -Path $regPath -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
            if ($proxyEnabled -and $proxyServer) { $raw = [string]$proxyServer; $source = '系统代理 (IE 设置)' }
        } catch {}
    }
    $script:ProxyConfig = Resolve-ProxyConfig $raw
    $script:SysProxy = $script:ProxyConfig.Url
    if ($script:SysProxy) {
        Write-Info "检测到代理[$source]: $($script:SysProxy)"
        if ($script:ProxyConfig.Socks) { Write-Info 'SOCKS 代理：仅 curl 支持，其它引擎将走直连' }
    }
    else { Write-Info '未检测到代理，将使用直连/镜像' }
}

function New-WebProxyOrNull {
    param([string]$Address)
    if (-not $Address) { return $null }
    if ($Address -match '^(socks4|socks4a|socks5|socks5h)://') { return $null }
    try { return New-Object System.Net.WebProxy($Address) } catch { return $null }
}

# ======== 语义化版本排序键 ========
# 与 MAA 脚本同一套规则：
#   - 主/次/修订号各自零填充到 6 位，数值序 = 字符串序
#   - 正式版用 '~'，预发布版用 '!'（'~' 0x7E > '!' 0x21），故正式版 > 同号预发布版
#   - 预发布标识用 '|' 连接并以 '~' 收尾：标识更少者优先级更高
#   - 数字标识补零（beta.10 > beta.9）；数字标识 < 字母标识
function Get-VersionKey {
    param([string]$Version)
    $v = ([string]$Version).Trim()
    if (-not $v) { return '' }
    if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
    if ($v.Contains('+')) { $v = $v.Split('+')[0] }
    $v = $v.Trim()
    if (-not $v) { return '' }

    $pre = ''
    if ($v.Contains('-')) {
        $idx = $v.IndexOf('-')
        $pre = $v.Substring($idx + 1)
        $v = $v.Substring(0, $idx)
    }
    $v = $v.Trim()
    if (-not $v) { return '' }

    $parts = @($v.Split('.') | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return '' }
    $nums = @()
    foreach ($q in $parts) {
        if (-not ($q -match '^\d+$')) { return '' }
        $nums += [int]$q
    }
    while ($nums.Count -lt 3) { $nums += 0 }

    $key = '{0:D6}.{1:D6}.{2:D6}' -f $nums[0], $nums[1], $nums[2]
    if (-not $pre) { return $key + '.~' }
    $pre = $pre.ToLowerInvariant()
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($id in ($pre -split '[\.\-_]')) {
        if (-not $id) { continue }
        if ($id -match '^\d+$') {
            $n = $id
            if ($n.Length -gt 9) { $n = $n.Substring($n.Length - 9) }
            $ids.Add('0' + $n.PadLeft(9, '0'))
        }
        else { $ids.Add('1' + $id) }
    }
    if ($ids.Count -eq 0) { return $key + '.~' }
    return $key + '.!' + ($ids -join '|') + '~'
}

# A > B 返回 1，A < B 返回 -1，相等返回 0
function Compare-SemVer {
    param([string]$VersionA, [string]$VersionB)
    $ka = Get-VersionKey $VersionA
    $kb = Get-VersionKey $VersionB
    if (-not $ka -and -not $kb) { return 0 }
    if (-not $ka) { return -1 }
    if (-not $kb) { return 1 }
    $c = [string]::CompareOrdinal($ka, $kb)
    if ($c -gt 0) { return 1 }
    if ($c -lt 0) { return -1 }
    return 0
}

# 规范化版本号写法，便于和 tag 直接比较（2.32.0 / v2.32.0 视为同一版本）
function Get-NormalizedVersion {
    param([string]$Version)
    $v = ([string]$Version).Trim()
    if (-not $v) { return '' }
    if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
    return $v
}

# ======== 下载线路候选 ========
function Get-DownloadCandidates {
    param([string]$Url)
    # 镜像站尾部可能带 '/'，先归一化再拼接，避免出现 'https://host//https://...'
    $clean = @()
    foreach ($m in $MirrorHosts) { $clean += $m.TrimEnd('/') }
    return @{
        Direct  = $Url
        Proxied = $Url
        Mirrors = @($clean | ForEach-Object { "$_/$Url" })
    }
}

# ======== 探测各线路是否可用（读取 64KB 即停；-Ms 返回耗时毫秒） ========
function Test-DownloadSpeed {
    param([string]$Url, [int]$TimeoutSec = 5, [long]$TestBytes = 64KB, [string]$Proxy = '', [switch]$NoProxy, [switch]$Ms)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'MaaEnd-DL/1.0'
        $req.AddRange(0, $TestBytes - 1)
        if ($NoProxy) { $req.Proxy = $null }
        elseif ($Proxy) { $req.Proxy = New-WebProxyOrNull $Proxy }
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        $totalRead = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($totalRead -lt $TestBytes) {
            $read = $stream.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }
            $totalRead += $read
        }
        $sw.Stop()
        $stream.Close(); $resp.Close()
        if ($totalRead -eq 0) { return -1 }
        if ($Ms) { return [long]$sw.ElapsedMilliseconds }
        return @{ Url = $Url; SpeedBps = [long]($totalRead * 1000 / [Math]::Max($sw.ElapsedMilliseconds, 1)) }
    }
    catch { return -1 }
}

function Test-UrlCandidates {
    param($Candidates)
    $probe = New-Object System.Collections.Generic.List[object]
    $directMs = -1
    $proxyMs = -1
    $mirrorUp = 0
    $mirrorTotal = @($Candidates.Mirrors).Count
    $mirrorSkipped = $false

    # 直连探测失败时再给一次机会：TUN/代理客户端的出口节点轮换会让单次探测偶发失败
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $directMs = Test-DownloadSpeed -Url $Candidates.Direct -TimeoutSec 5 -NoProxy -Ms
        if ($directMs -ge 0) { break }
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 400 }
    }
    if ($directMs -ge 0) { $probe.Add([pscustomobject]@{ Url = $Candidates.Direct; Ms = $directMs; Route = '直连'; NoProxy = $true }) }

    if ($script:SysProxy) {
        $proxyMs = Test-DownloadSpeed -Url $Candidates.Proxied -TimeoutSec 5 -Proxy $script:ProxyConfig.ForCurl -Ms
        if ($proxyMs -ge 0) { $probe.Add([pscustomobject]@{ Url = $Candidates.Proxied; Ms = $proxyMs; Route = '代理'; NoProxy = $false }) }
    }

    # 只有直连/代理确实很快（<400ms 拿到首批 64KB）时才跳过镜像探测；
    # 否则镜像可能反而更快，仍然值得测一遍。
    if (($directMs -ge 0 -and $directMs -lt 400) -or ($proxyMs -ge 0 -and $proxyMs -lt 400)) {
        $mirrorSkipped = $true
    }
    else {
        foreach ($mu in $Candidates.Mirrors) {
            $ms = Test-DownloadSpeed -Url $mu -TimeoutSec 5 -NoProxy -Ms
            if ($ms -ge 0) { $probe.Add([pscustomobject]@{ Url = $mu; Ms = $ms; Route = '镜像'; NoProxy = $true }); $mirrorUp++ }
        }
    }

    if ($directMs -ge 0) { Write-Info "GitHub 直连可用 (${directMs}ms)" } else { Write-Info 'GitHub 直连不可用' }
    if ($script:SysProxy) {
        if ($proxyMs -ge 0) { Write-Info "代理线路可用 (${proxyMs}ms)" }
        else { Write-Info '代理线路不可用（代理未开启、已失效，或代理不允许访问 GitHub）' }
    }
    if ($mirrorSkipped) { Write-Info '已选定直连/代理，跳过镜像探测' }
    else { Write-Info "镜像可用 $mirrorUp/$mirrorTotal 个" }

    if ($probe.Count -eq 0) { return @() }
    return @($probe | Sort-Object Ms)
}

# ======== GitHub API（直连 → 代理），失败返回 $null ========
function Invoke-GitHubApi {
    param([string]$Url, [int]$TimeoutSec = 15)
    foreach ($useProxy in @($false, $true)) {
        if ($useProxy -and -not $script:SysProxy) { continue }
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'
            $req.Timeout = $TimeoutSec * 1000
            $req.ReadWriteTimeout = $TimeoutSec * 1000
            $req.UserAgent = 'MaaEnd-Update/2.0'
            # 注意：不要给 HttpWebRequest 赋 Accept 之外的自定义头，避免不同 .NET 版本行为差异
            if ($useProxy) { $req.Proxy = New-WebProxyOrNull $script:ProxyConfig.ForCurl }
            else { $req.Proxy = $null }
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

# ======== API 不可达时，从 github.com 发布页抓取 tag 列表 ========
function Invoke-GitHubScrape {
    # /releases 页面按发布时间倒序列出 tag，比 /tags 页面更适合判断"最新"
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($pageUrl in @("https://github.com/$RepoSlug/releases", "https://github.com/$RepoSlug/releases.atom")) {
        foreach ($useProxy in @($false, $true)) {
            if ($useProxy -and -not $script:SysProxy) { continue }
            try {
                $req = [System.Net.HttpWebRequest]::Create($pageUrl)
                $req.Method = 'GET'; $req.Timeout = 15000; $req.ReadWriteTimeout = 15000
                $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
                if ($useProxy) { $req.Proxy = New-WebProxyOrNull $script:ProxyConfig.ForCurl }
                else { $req.Proxy = $null }
                $resp = $req.GetResponse()
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $reader.ReadToEnd(); $resp.Close(); $reader.Close()
                $found = New-Object System.Collections.Generic.List[string]
                foreach ($m in [regex]::Matches($body, "/$RepoSlug/releases/tag/([^""'<>\s]+)")) {
                    $t = [System.Uri]::UnescapeDataString($m.Groups[1].Value)
                    if ($t -and -not $found.Contains($t)) { $found.Add($t) }
                }
                if ($found.Count -eq 0) {
                    # .atom 源：<link ... href=".../releases/tag/vX" />
                    foreach ($m in [regex]::Matches($body, 'releases/tag/([^""''<>\s/]+)')) {
                        $t = [System.Uri]::UnescapeDataString($m.Groups[1].Value)
                        if ($t -and -not $found.Contains($t)) { $found.Add($t) }
                    }
                }
                if ($found.Count -gt 0) {
                    foreach ($t in $found) { $items.Add([pscustomobject]@{ tag_name = $t; prerelease = $null; published_at = $null; assets = @(); scraped = $true }) }
                    return $items
                }
            }
            catch { }
        }
    }
    return $null
}

function Get-Sha256FromAsset {
    param($Asset)
    if ($Asset.digest) {
        $raw = [string]$Asset.digest
        if ($raw -match '^sha256:(.+)$') { return $matches[1] }
    }
    return $null
}

# ======== 挑选目标版本 ========
# stable：以 published_at 最晚的正式版为准（不依赖 /latest 的行为差异）
# beta  ：在正式版与预发布版之间按语义化版本取更高者，版本号相同时优先正式版
function Select-MaaEndRelease {
    param([object[]]$Releases, [string]$RequestedChannel)
    if (-not $Releases -or $Releases.Count -eq 0) { return $null }

    $stables = New-Object System.Collections.Generic.List[object]
    $pres = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Releases) {
        if (-not $r -or -not $r.tag_name) { continue }
        # scraped 结果没有 prerelease 字段，按 tag 名称判断
        $isPre = $null
        if ($null -ne $r.prerelease) { $isPre = [bool]$r.prerelease }
        else { $isPre = ([string]$r.tag_name -match '(?i)(beta|rc|alpha|pre|dev|nightly)') }
        if ($isPre) { $pres.Add($r) } else { $stables.Add($r) }
    }

    $pickLatestByTime = {
        param($list)
        $best = $null
        foreach ($r in $list) {
            if (-not $best) { $best = $r; continue }
            $t1 = $null; $t2 = $null
            try { if ($r.published_at) { $t1 = [DateTime]::Parse([string]$r.published_at) } } catch {}
            try { if ($best.published_at) { $t2 = [DateTime]::Parse([string]$best.published_at) } } catch {}
            if ($t1 -and $t2) { if ($t1 -gt $t2) { $best = $r } }
            elseif ((Compare-SemVer $r.tag_name $best.tag_name) -gt 0) { $best = $r }
        }
        return $best
    }

    $pickNewestBySemVer = {
        param($list)
        $best = $null
        foreach ($r in $list) {
            if (-not $best) { $best = $r; continue }
            $c = Compare-SemVer $r.tag_name $best.tag_name
            if ($c -gt 0) { $best = $r }
            elseif ($c -eq 0) {
                # 版本号相同（如 2.32.0 与 v2.32.0）优先正式版
                $rPre = if ($null -ne $r.prerelease) { [bool]$r.prerelease } else { ([string]$r.tag_name -match '(?i)(beta|rc|alpha|pre)') }
                $bPre = if ($null -ne $best.prerelease) { [bool]$best.prerelease } else { ([string]$best.tag_name -match '(?i)(beta|rc|alpha|pre)') }
                if ($bPre -and -not $rPre) { $best = $r }
            }
        }
        return $best
    }

    if ($RequestedChannel -eq 'stable') {
        $best = & $pickLatestByTime $stables
        if (-not $best -and $pres.Count -gt 0) {
            Write-Warn '未找到正式版，改用最新的预发布版'
            $best = & $pickNewestBySemVer $pres
        }
        return $best
    }

    # beta：正式版与预发布版一起比，取语义化版本更高者
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($r in $stables) { $all.Add($r) }
    foreach ($r in $pres) { $all.Add($r) }
    $best = & $pickNewestBySemVer $all
    if ($best -and $best.prerelease -eq $false -and $pres.Count -gt 0) {
        $preBest = & $pickNewestBySemVer $pres
        if ($preBest -and (Compare-SemVer $best.tag_name $preBest.tag_name) -gt 0) {
            Write-Info "beta 通道：正式版 $($best.tag_name) 比最新预发布版 $($preBest.tag_name) 更新，采用正式版"
        }
    }
    return $best
}

# ======== 运行自测（-SelfTest） ========
function Test-ScriptLogic {
    $script:fail = 0
    function Assert-Same {
        param([string]$Name, $Expected, $Actual)
        if ($Expected -eq $Actual) { Write-Host "  [通过] $Name" -ForegroundColor Green }
        else { Write-Host "  [失败] $Name`n         期望: $Expected`n         实际: $Actual" -ForegroundColor Red; $script:fail = $script:fail + 1 }
    }

    Write-Host '--- Compare-SemVer ---' -ForegroundColor Cyan
    Assert-Same 'beta5 > beta4' 1 (Compare-SemVer 'v2.33.0-beta.5' 'v2.33.0-beta.4')
    Assert-Same 'beta10 > beta9' 1 (Compare-SemVer 'v2.33.0-beta.10' 'v2.33.0-beta.9')
    Assert-Same '预发布 < 同号正式版' (-1) (Compare-SemVer 'v2.32.0-rc.1' 'v2.32.0')
    Assert-Same '正式版 > 同号预发布' 1 (Compare-SemVer 'v2.32.0' 'v2.32.0-rc.1')
    Assert-Same '带 v 与不带 v 相等' 0 (Compare-SemVer 'v2.32.0' '2.32.0')
    Assert-Same 'minor 递增' 1 (Compare-SemVer '2.33.0' '2.32.9')
    Assert-Same '数字段序正确' (-1) (Compare-SemVer 'v2.9.0' 'v2.10.0')
    Assert-Same '比较结果是标量' 'Int32' (Compare-SemVer 'v2.32.0' 'v2.32.0').GetType().Name
    Assert-Same '规范化去掉 v' '2.32.0' (Get-NormalizedVersion 'v2.32.0')

    Write-Host '--- Resolve-ProxyConfig ---' -ForegroundColor Cyan
    Assert-Same 'http 代理' 'http://127.0.0.1:7897' (Resolve-ProxyConfig '127.0.0.1:7897').Url
    Assert-Same 'socks5 标记' $true (Resolve-ProxyConfig 'socks5://127.0.0.1:7897').Socks
    Assert-Same 'socks5 交给 curl' 'socks5://127.0.0.1:7897' (Resolve-ProxyConfig 'socks5://127.0.0.1:7897').ForCurl
    Assert-Same '按协议列表取值' 'http://127.0.0.1:7897' (Resolve-ProxyConfig 'http=127.0.0.1:7897;https=127.0.0.1:7897').Url
    Assert-Same '空值' '' (Resolve-ProxyConfig '').Url

    Write-Host '--- Get-DownloadCandidates ---' -ForegroundColor Cyan
    $cand = Get-DownloadCandidates -Url 'https://github.com/MaaEnd/MaaEnd/releases/download/v2.32.0/MaaEnd-win-x86_64-v2.32.0.zip'
    Assert-Same '镜像数量' $MirrorHosts.Count $cand.Mirrors.Count
    Assert-Same '镜像无多余斜杠' $false ([string]$cand.Mirrors[0]).Contains('//https')
    Assert-Same '直连为原始地址' $true ([string]$cand.Direct).StartsWith('https://github.com/')

    Write-Host '--- Select-MaaEndRelease ---' -ForegroundColor Cyan
    $mockReleases = @(
        [pscustomobject]@{ tag_name = 'v2.33.0-beta.5'; prerelease = $true;  published_at = '2026-10-14T16:27:10Z' },
        [pscustomobject]@{ tag_name = 'v2.33.0-beta.4'; prerelease = $true;  published_at = '2026-10-13T16:41:58Z' },
        [pscustomobject]@{ tag_name = 'v2.32.0';        prerelease = $false; published_at = '2026-10-09T18:47:55Z' },
        [pscustomobject]@{ tag_name = 'v2.32.0-rc.1';   prerelease = $true;  published_at = '2026-10-08T18:41:43Z' }
    )
    Assert-Same 'stable 取正式版' 'v2.32.0' (Select-MaaEndRelease -Releases $mockReleases -RequestedChannel 'stable').tag_name
    Assert-Same 'beta 取更新的预发布版' 'v2.33.0-beta.5' (Select-MaaEndRelease -Releases $mockReleases -RequestedChannel 'beta').tag_name
    # 核心场景：预发布版落后于正式版时，必须取正式版
    $stalePre = @(
        [pscustomobject]@{ tag_name = 'v2.32.0-beta.2'; prerelease = $true;  published_at = '2026-10-07T10:00:00Z' },
        [pscustomobject]@{ tag_name = 'v2.32.0';        prerelease = $false; published_at = '2026-10-09T18:47:55Z' }
    )
    Assert-Same 'beta 通道预发布版落后 → 取正式版' 'v2.32.0' (Select-MaaEndRelease -Releases $stalePre -RequestedChannel 'beta').tag_name
    # 版本号相同（2.32.0 / v2.32.0）优先正式版
    $sameVer = @(
        [pscustomobject]@{ tag_name = 'v2.32.0'; prerelease = $true;  published_at = '2026-10-09T10:00:00Z' },
        [pscustomobject]@{ tag_name = '2.32.0';  prerelease = $false; published_at = '2026-10-09T18:00:00Z' }
    )
    Assert-Same '同版本号优先正式版' '2.32.0' (Select-MaaEndRelease -Releases $sameVer -RequestedChannel 'beta').tag_name
    Assert-Same '空列表返回空' $null (Select-MaaEndRelease -Releases @() -RequestedChannel 'stable')

    Write-Host '--- Get-Sha256FromAsset ---' -ForegroundColor Cyan
    Assert-Same '解析 digest' 'abc123' (Get-Sha256FromAsset ([pscustomobject]@{ digest = 'sha256:abc123' }))
    Assert-Same '无 digest 返回空' $null (Get-Sha256FromAsset ([pscustomobject]@{ digest = $null }))

    Write-Host ''
    if ($script:fail -eq 0) { Write-Host '自测全部通过 ✔' -ForegroundColor Green; return $true }
    Write-Host "自测失败 $($script:fail) 项 ✘" -ForegroundColor Red
    return $false
}

if ($SelfTest) {
    $ok = Test-ScriptLogic
    if ($ok) { exit 0 } else { exit 1 }
}

# ======== 下载 ========
function Start-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0, [switch]$NoProxy)

    if (-not $Silent) { Write-Host '⚠ 正在下载，请不要关闭此窗口！根据网络状况可能需要几分钟。' -ForegroundColor Black -BackgroundColor Yellow }

    $proxyArg = ''
    if (-not $NoProxy -and $script:ProxyConfig) { $proxyArg = $script:ProxyConfig.ForCurl }

    if ($script:HasCurl) {
        $curlArgs = @('-SfL', '-o', $OutFile, '--progress-bar', '-A', 'MaaEnd-DL/1.0', '--connect-timeout', '15', '--max-time', '900',
            '--retry', '2', '--retry-delay', '2', '--ssl-no-revoke')
        if ($proxyArg) { $curlArgs += '--proxy', $proxyArg } else { $curlArgs += '--noproxy', '*' }
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
            if ($NoProxy) { $wc.Proxy = $null } elseif ($proxyArg) { $wc.Proxy = New-WebProxyOrNull $proxyArg }
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

# 本地已安装版本：interface.json 的 version 字段（2.32.0 或 v2.32.0）
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
try {
    Write-Step '获取最新版本信息'

    $isArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM')
    $arch = if ($isArm) { 'aarch64' } else { 'x86_64' }
    Write-Info "检测到架构: $arch"
    Write-Info "更新通道: $Channel"

    Initialize-Proxy

    # GitHub API 主备：先取列表（stable 也从列表里按时间挑，避免 /latest 行为差异）
    $releases = $null
    $perPage = 30
    $listFromScrape = $false
    foreach ($apiUrl in @("$ApiBase`?per_page=$perPage", "$ApiBase/latest")) {
        Write-Info "请求 GitHub API: $apiUrl"
        $data = Invoke-GitHubApi $apiUrl
        if ($data) {
            if ($data -is [array]) { $releases = $data }
            else { $releases = @($data) }   # /latest 返回单个对象
            if ($releases.Count -gt 0) { break }
        }
    }
    if (-not $releases) {
        Write-Warn 'GitHub API 不可达，尝试从发布页抓取...'
        $releases = Invoke-GitHubScrape
        $listFromScrape = $true
    }
    if (-not $releases) {
        Write-Err "无法获取 $Channel 版本信息"
        exit 1
    }
    if ($listFromScrape) { Write-Warn "API 降级：使用网页抓取到的 $($releases.Count) 个版本（无法读取发布时间，仅按版本号排序）" }

    $release = Select-MaaEndRelease -Releases @($releases) -RequestedChannel $Channel
    if (-not $release) {
        Write-Err "无法在已获取的版本列表中确定 $Channel 目标版本"
        exit 1
    }
    $tagName = [string]$release.tag_name
    Write-Ok "最新 $Channel 版本: $tagName"

    $localVer = Get-LocalVersion
    if ($localVer) {
        Write-Info "本地版本: $localVer"
        $cmp = Compare-SemVer $tagName $localVer
        if ($cmp -le 0 -and -not $Force) {
            if ((Get-NormalizedVersion $tagName) -eq (Get-NormalizedVersion $localVer)) { Write-Ok "已是最新版本，无需更新" }
            else { Write-Ok "已是最新（本地 $localVer 高于可用版本 $tagName）" }
            exit 0
        }
    }
    else { Write-Warn '未找到 interface.json 中的版本信息，将直接下载安装' }

    # 匹配对应架构的 asset：MaaEnd-win-<arch>-<tag>.zip
    $asset = $null
    $archPattern = "^MaaEnd-win-$arch-(.+)$"
    foreach ($a in @($release.assets)) {
        $nm = [string]$a.name
        if ($nm -match $archPattern) { $asset = $a; break }
    }
    if ($asset) {
        $filename = [string]$asset.name
        $originalUrl = [string]$asset.browser_download_url
        $expectedSize = [long]$asset.size
        $expectedSha256 = Get-Sha256FromAsset $asset
    }
    else {
        # 没有 assets 信息（例如网页抓取降级）→ 按官方命名规则拼地址
        $filename = "MaaEnd-win-$arch-$tagName.zip"
        $originalUrl = "https://github.com/$RepoSlug/releases/download/$tagName/$filename"
        $expectedSize = 0
        $expectedSha256 = $null
        Write-Warn "未从 API 获取到资源清单，按命名规则推测: $filename"
    }
    $filepath = Join-Path $ScriptDir $filename

    Write-Info "文件名: $filename"
    Write-Info "文件大小: $(if ($expectedSize -gt 0) { Format-FileSize $expectedSize } else { '未知' })"
    Write-Info "原始地址: $originalUrl"

    # ======== 下载（探测直连/代理/镜像 → 按最快顺序尝试）========
    Write-Step '开始下载'

    $cand = Get-DownloadCandidates -Url $originalUrl
    Write-Info '正在探测下载线路（直连 / 代理 / 镜像）...'
    $probes = Test-UrlCandidates -Candidates $cand
    if ($probes.Count -eq 0) {
        if ($script:SysProxy) { Write-Warn '所有线路探测失败。如代理对 GitHub 设置了直连/绕过规则，请关闭该规则后重试。' }
        else { Write-Warn '所有线路探测失败，且未检测到代理。请检查网络或开启代理后重试。' }
    }
    else { Write-Info "最快线路: $($probes[0].Url) [$($probes[0].Route), $($probes[0].Ms)ms]" }

    if ($DryRun) {
        Write-Warn '仅检查模式（-DryRun），跳过下载与安装'
        exit 0
    }

    $attempt = 0
    $tested = @()
    $downloadOk = $false
    foreach ($p in $probes) {
        if ($attempt -ge 4) { break }
        $attempt++
        $tested += $p.Url
        if ($attempt -gt 1) { Write-Info "切换下载源 ($($p.Route)): $($p.Url)" }
        if (Test-Path $filepath) { Remove-Item -Force $filepath -ErrorAction SilentlyContinue }
        $ok = if ($p.NoProxy) {
            Start-Download -Url $p.Url -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize -NoProxy
        } else {
            Start-Download -Url $p.Url -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize
        }
        if ($ok) {
            if ($expectedSha256) {
                Write-Info '验证 SHA256...'
                $hash = (Get-FileHash $filepath -Algorithm SHA256).Hash
                if ($hash -ne $expectedSha256) {
                    Write-Err 'SHA256 校验失败，文件可能损坏，换源重试'
                    Remove-Item -Force $filepath -ErrorAction SilentlyContinue
                    continue
                }
                Write-Ok 'SHA256 校验通过'
            }
            $downloadOk = $true
            break
        }
        Write-Warn "下载源不可用: $($p.Url)"
    }

    # 未探测成功的线路再兜底试一遍
    if (-not $downloadOk) {
        $fallback = New-Object System.Collections.Generic.List[object]
        if ($tested -notcontains $cand.Direct) { $fallback.Add([pscustomobject]@{ Url = $cand.Direct; Route = '直连'; NoProxy = $true }) }
        if ($script:SysProxy -and ($tested -notcontains $cand.Proxied)) { $fallback.Add([pscustomobject]@{ Url = $cand.Proxied; Route = '代理'; NoProxy = $false }) }
        foreach ($mu in $cand.Mirrors) { if ($tested -notcontains $mu) { $fallback.Add([pscustomobject]@{ Url = $mu; Route = '镜像'; NoProxy = $true }) } }
        foreach ($f in $fallback) {
            if ($attempt -ge 7) { break }
            $attempt++
            Write-Info "兜底尝试 ($($f.Route)): $($f.Url)"
            if (Test-Path $filepath) { Remove-Item -Force $filepath -ErrorAction SilentlyContinue }
            $ok = if ($f.NoProxy) {
                Start-Download -Url $f.Url -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize -NoProxy
            } else {
                Start-Download -Url $f.Url -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize
            }
            if ($ok) {
                if ($expectedSha256) {
                    $hash = (Get-FileHash $filepath -Algorithm SHA256).Hash
                    if ($hash -ne $expectedSha256) {
                        Write-Err 'SHA256 校验失败，文件可能损坏，换源重试'
                        Remove-Item -Force $filepath -ErrorAction SilentlyContinue
                        continue
                    }
                    Write-Ok 'SHA256 校验通过'
                }
                $downloadOk = $true
                break
            }
        }
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
}
catch {
    Write-Err "更新过程出错: $_"
    exit 1
}
