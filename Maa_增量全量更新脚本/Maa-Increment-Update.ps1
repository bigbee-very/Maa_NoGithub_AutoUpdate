<#:
.SYNOPSIS
    MAA 一键更新脚本 — 无代理 v3.5（语义化版本 + 智能路由）
.DESCRIPTION
    放置于 MAA 安装目录下直接运行。
    具备语义化版本比较、跨通道最新版解析、代理/直连智能路由、
    下载重试、镜像降级、安装前备份、失败回滚、日志记录、API 缓存等冗余机制。
.PARAMETER Channel
    更新通道: stable / beta / alpha。beta 会同时比较 beta 与 stable，取语义化版本最新者。
.PARAMETER Force
    强制更新（忽略版本/资源时间比较）。
.PARAMETER SelfTest
    仅运行内置纯函数自测，不进行任何网络或文件操作。
.AUTHOR
    bigbee
.PROJECT
    https://github.com/bigbee-very/Maa_NoGithub_AutoUpdate#maa-nogithub-autoupdate
#>

param(
    [ValidateSet('stable', 'beta', 'alpha')]
    [string]$Channel = 'stable',
    [switch]$Force,
    [switch]$SkipVersion,
    [switch]$SkipResource,
    [switch]$DryRun,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
[System.Net.ServicePointManager]::DefaultConnectionLimit = 8
# SSL/TLS 协议设置
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
$script:HasCurl = $null -ne (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ProgressPreference = 'SilentlyContinue'
$script:HttpsProxy = ''
if ($env:HTTPS_PROXY) { $script:HttpsProxy = $env:HTTPS_PROXY } elseif ($env:HTTP_PROXY) { $script:HttpsProxy = $env:HTTP_PROXY }

# ======== 代理探测 ========
# 返回 @{ Url = <可用地址>; ForCurl = <curl 参数值>; DotNet = <WebProxy 地址或 $null>; Socks = <bool> }
# 说明：
#   - SOCKS5 代理无法交给 .NET WebProxy 使用，此时 DotNet 返回 $null，由 curl 接管。
#   - 部分代理客户端（如 Clash）会设置 HTTPS_PROXY=socks5://127.0.0.1:7897，
#     这种地址直接塞给 System.Net.WebProxy 会抛异常并绕过代理，故单独处理。
function Resolve-ProxyConfig {
    param([string]$RawValue)
    $cfg = @{ Url = ''; ForCurl = $null; DotNet = $null; Socks = $false }
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

    $isSocks = $raw -match '^(socks4|socks4a|socks5|socks5h)://'
    if ($isSocks) {
        $cfg.Socks = $true
        $cfg.Url = $raw
        $cfg.ForCurl = $raw                                                        # curl 原生支持 socks5h://
        $cfg.DotNet = $null                                                        # .NET WebProxy 不支持
        return $cfg
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($raw, [System.UriKind]::Absolute, [ref]$uri)) { return $cfg }
    $norm = "$($uri.Scheme)://$($uri.Host)"
    if (-not $uri.IsDefaultPort) { $norm += ":$($uri.Port)" }
    $cfg.Url = $norm
    $cfg.ForCurl = $norm
    $cfg.DotNet = $norm
    return $cfg
}

function Detect-SystemProxy {
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
        }
        catch {}
    }
    $script:ProxyConfig = Resolve-ProxyConfig $raw
    $script:SysProxy = $script:ProxyConfig.Url
    if ($script:SysProxy) {
        Write-Info "检测到代理[$source]: $($script:SysProxy)"
        if ($script:ProxyConfig.Socks) { Write-Info 'SOCKS 代理：仅 curl 支持，其它引擎将走直连' }
    }
    else { Write-Info '未检测到代理，将使用直连/镜像' }
}

# ======== 语义化版本比较 ========
# 支持 v6.19.2 / 6.19.2-beta.2 / v6.18.0-beta.1.d014.g313c9b460c1 / 6.19.1-alpha.1.d096.gf94342d3e2
# 规则遵循 SemVer：正式版 > 预发布版（6.19.2 > 6.19.2-beta.2）
function ConvertTo-VersionParts {
    param([string]$Version)
    $v = ([string]$Version).Trim()
    if (-not $v) { return $null }
    if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
    $v = ($v -split '\+')[0]                      # 丢弃 build metadata
    $v = $v.Trim()

    $pre = ''
    # 主版本号统一为「数字.数字[.数字]」；预发布部分用 - 或 _ 分隔。
    # 注意匹配后要检查左边界：'6.19.1-alpha.1' 应切成 6.19.1 + alpha.1，
    # 而 '6.18.0-beta.1.d014' 应切成 6.18.0 + beta.1.d014
    # （'-' 后面的 alpha.1 属于预发布串，不能再被当成主版本号）。
    if ($v -match '^([0-9]+(?:\.[0-9]+)*?)[\-_](.+)$') { $v = $matches[1]; $pre = $matches[2] }
    $nums = @()
    $segs = @()
    foreach ($p in ($v -split '\.')) {
        if ($p -match '^\d+$') {
            $segs += $p
            $nums += [int]$p
        }
        else { $segs += $p }
    }
    if ($nums.Count -eq 0) { return $null }
    while ($nums.Count -lt 3) { $nums += 0 }

    $preIds = @()
    foreach ($p in ($pre -split '[\.\-_]')) {
        if (-not $p) { continue }
        if ($p -match '^\d+$') { $preIds += , @([int]$p, $true) }
        else { $preIds += , @([string]$p, $false) }
    }
    return @{
        Major   = $nums[0]
        Minor   = $nums[1]
        Patch   = $nums[2]
        Extra   = @($nums[3..($nums.Count - 1)])
        Pre     = $pre
        PreIds  = $preIds
        Segs    = @($segs[0..([Math]::Min(2, $segs.Count - 1))])
        Raw     = ([string]$Version).Trim()
    }
}

# 语义化版本排序键：把版本号压成可直接做字符串比较的定长键。
# 规则（遵循 SemVer）：
#   - 主/次/修订号各自零填充到 6 位，保证数值序等于字符串序
#   - 正式版在预发布段前加 '~'，预发布版加 '!'，因为 '~'(0x7E) > '!'(0x21)
#   - 预发布标识之间用 '|' 连接：标识更少者（alpha.1）排在更多者（alpha.1.d096）之前
#   - 数字标识零填充，保证 beta.10 > beta.9
#   - 数字标识 < 字母标识（SemVer 规定）
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
    if ($v.Contains('_')) {
        $idx = $v.IndexOf('_')
        if (-not $pre) { $pre = $v.Substring($idx + 1) }
        $v = $v.Substring(0, $idx)
    }
    $v = $v.Trim()
    if (-not $v) { return '' }

    $parts = @($v.Split('.') | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return '' }
    $nums = @()
    foreach ($q in $parts) {
        if (-not ($q -match '^\d+$')) { return '' }      # 数字段里混入非数字 → 无法解析
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
    # 末尾加终止符 '~'(0x7E)：标识更少的版本（alpha.1）大于同前缀的夜间版（alpha.1.d014）
    return $key + '.!' + ($ids -join '|') + '~'
}

# 语义化版本比较（A > B 返回 1，A < B 返回 -1，相等返回 0）
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

# 人工核对的排序键（与 Get-VersionKey 同一套规则）
function ConvertTo-VersionComparable {
    param([string]$Version)
    return (Get-VersionKey $Version)
}

# 按语义化版本降序排列（插入排序；比较结果先落盘到变量，避免复合条件里的隐式行为）
function Sort-VersionDescending {
    param([string[]]$Versions)
    $arr = @()
    foreach ($v in $Versions) {
        if (-not $v) { continue }
        if ($arr -notcontains $v) { $arr += $v }
    }
    $n = $arr.Count
    for ($i = 1; $i -lt $n; $i++) {
        $key = $arr[$i]
        $j = $i - 1
        $cmp = 0
        if ($j -ge 0) { $cmp = Compare-SemVer ($arr[$j]) ($key) }
        while ($j -ge 0 -and $cmp -lt 0) {
            $arr[$j + 1] = $arr[$j]
            $j = $j - 1
            if ($j -ge 0) { $cmp = Compare-SemVer ($arr[$j]) ($key) }
        }
        $arr[$j + 1] = $key
    }
    return @($arr)
}

function Select-BestVersion {
    param([string[]]$Versions)
    $best = ''
    foreach ($v in $Versions) {
        if (-not $v) { continue }
        if (-not $best) { $best = $v; continue }
        if ((Compare-SemVer $v $best) -gt 0) { $best = $v }
    }
    return $best
}

function Get-VersionBase {
    param([string]$Version)
    $p = ConvertTo-VersionParts $Version
    if (-not $p) { return '' }
    $seg = @($p.Segs)
    return (@($seg[0], $seg[1], $seg[2]) -join '.')
}

# ======== 版本比较自测（-SelfTest） ========
function Test-ScriptLogic {
    $script:fail = 0
    function Assert-Same {
        param([string]$Name, $Expected, $Actual)
        if ($Expected -eq $Actual) { Write-Host "  [通过] $Name" -ForegroundColor Green }
        else { Write-Host "  [失败] $Name`n         期望: $Expected`n         实际: $Actual" -ForegroundColor Red; $script:fail = $script:fail + 1 }
    }

    Write-Host '--- Compare-SemVer ---' -ForegroundColor Cyan
    Assert-Same 'beta2 < 正式版' (-1) (Compare-SemVer 'v6.19.2-beta.2' 'v6.19.2')
    Assert-Same '正式版 > beta2' 1 (Compare-SemVer 'v6.19.2' 'v6.19.2-beta.2')
    Assert-Same 'beta2 > beta1' 1 (Compare-SemVer 'v6.19.2-beta.2' 'v6.19.2-beta.1')
    Assert-Same 'beta10 > beta9' 1 (Compare-SemVer 'v6.19.2-beta.10' 'v6.19.2-beta.9')
    Assert-Same '相等（带v）' 0 (Compare-SemVer 'v6.19.0' '6.19.0')
    Assert-Same '补零相等' 0 (Compare-SemVer '6.19' 'v6.19.0')
    Assert-Same 'patch 递增' 1 (Compare-SemVer '6.19.10' '6.19.9')
    Assert-Same 'minor 递增' 1 (Compare-SemVer '6.20.0' '6.19.99')
    Assert-Same '夜间版后缀：beta.1 > beta.1.d014' 1 (Compare-SemVer 'v6.18.0-beta.1' 'v6.18.0-beta.1.d014.g313c9b460c1')
    Assert-Same 'alpha.1 > alpha.1.d096' 1 (Compare-SemVer 'v6.19.1-alpha.1' 'v6.19.1-alpha.1.d096.gf94342d3e2')
    Assert-Same 'alpha < 正式版' (-1) (Compare-SemVer 'v6.19.0-alpha.2' 'v6.19.0')
    Assert-Same '数字段序正确 (非字符串比较)' (-1) (Compare-SemVer 'v6.9.0' 'v6.10.0')

    Write-Host '--- Select-BestVersion ---' -ForegroundColor Cyan
    Assert-Same 'beta 通道取较新正式版' 'v6.19.2' (Select-BestVersion @('v6.19.0', 'v6.19.2'))
    Assert-Same 'beta 通道取较新公测版' 'v6.19.3-beta.1' (Select-BestVersion @('v6.19.2', 'v6.19.3-beta.1'))
    Assert-Same '空列表' '' (Select-BestVersion @())

    Write-Host '--- Get-VersionKey / Sort-VersionDescending ---' -ForegroundColor Cyan
    Assert-Same '版本切分：alpha.1 归属预发布' '6.19.1|alpha.1' ((ConvertTo-VersionParts 'v6.19.1-alpha.1') | ForEach-Object { "$(@($_.Segs) -join '.')|$($_.Pre)" })
    Assert-Same '排序键（正式版）' '000006.000019.000002.~' (Get-VersionKey 'v6.19.2')
    Assert-Same '排序键（预发布低于正式版）' $true ((Get-VersionKey 'v6.19.2-beta.2') -lt (Get-VersionKey 'v6.19.2'))
    Assert-Same '排序键（beta.10 > beta.9）' $true ((Get-VersionKey 'v6.19.2-beta.10') -gt (Get-VersionKey 'v6.19.2-beta.9'))
    Assert-Same 'Get-VersionBase' '6.19.0' (Get-VersionBase 'v6.19.0-beta.1.d014.g313c9b460c1')
    Assert-Same '降序（正式版优先于预发布）' 'v6.19.2,v6.19.2-beta.2,v6.19.0' ((Sort-VersionDescending @('v6.19.0', 'v6.19.2-beta.2', 'v6.19.2')) -join ',')
    Assert-Same '比较结果是标量' 'Int32' (Compare-SemVer 'v6.19.2' 'v6.19.2').GetType().Name
    Assert-Same 'compare(alpha.1, 夜间版)' 1 (Compare-SemVer 'v6.19.1-alpha.1' 'v6.19.1-alpha.1.d096.gf94342d3e2')
    Assert-Same '降序（跨多段跨通道）' 'v6.19.2,v6.19.2-beta.2,v6.19.1-alpha.1,v6.19.1-alpha.1.d096.gf94342d3e2,v6.18.9' ((Sort-VersionDescending @('v6.18.9', 'v6.19.1-alpha.1.d096.gf94342d3e2', 'v6.19.1-alpha.1', 'v6.19.2-beta.2', 'v6.19.2')) -join ',')
    Assert-Same '降序（首位即最新）' 'v6.19.2' (@(Sort-VersionDescending @('v6.19.0', 'v6.19.2', 'v6.18.9'))[0])

    Write-Host '--- Resolve-ProxyConfig ---' -ForegroundColor Cyan
    Assert-Same 'http 代理' 'http://127.0.0.1:7897' (Resolve-ProxyConfig '127.0.0.1:7897').Url
    Assert-Same 'http 代理(带 scheme)' 'http://127.0.0.1:7897' (Resolve-ProxyConfig 'http://127.0.0.1:7897').Url
    Assert-Same 'socks5 标记' $true (Resolve-ProxyConfig 'socks5://127.0.0.1:7897').Socks
    Assert-Same 'socks5 的 .NET 代理为空' $null (Resolve-ProxyConfig 'socks5://127.0.0.1:7897').DotNet
    Assert-Same 'socks5 交给 curl' 'socks5://127.0.0.1:7897' (Resolve-ProxyConfig 'socks5://127.0.0.1:7897').ForCurl
    Assert-Same '按协议列表取值' 'http://127.0.0.1:7897' (Resolve-ProxyConfig 'http=127.0.0.1:7897;https=127.0.0.1:7897').Url
    Assert-Same '空值' '' (Resolve-ProxyConfig '').Url

    Write-Host '--- Test-DownloadSpeed -Ms 探测 ---' -ForegroundColor Cyan
    $t0 = Get-Date
    $msNoSwitch = Test-DownloadSpeed -Url 'https://api.maa.plus/MaaAssistantArknights/api/version/summary.json' -TimeoutSec 8 -TestBytes 1KB
    $msWithSwitch = Test-DownloadSpeed -Url 'https://api.maa.plus/MaaAssistantArknights/api/version/summary.json' -TimeoutSec 8 -TestBytes 1KB -Ms
    Write-Host ("    无 -Ms: 类型={0} 值={1}" -f $msNoSwitch.GetType().Name, ($msNoSwitch | Out-String).Trim())
    Write-Host ("    带 -Ms: 类型={0} 值={1}" -f $msWithSwitch.GetType().Name, ($msWithSwitch | Out-String).Trim())
    Assert-Same '不带 -Ms 返回哈希表' 'Hashtable' $msNoSwitch.GetType().Name
    Assert-Same '带 -Ms 返回标量毫秒' $true ($msWithSwitch.GetType().Name -in @('Int32', 'Int64', 'Double'))
    Write-Host '--- Parse-GithubAssetName ---' -ForegroundColor Cyan
    $a = Parse-GithubAssetName 'MAAComponent-OTA-v6.16.0_v6.19.0-win-x64.zip'
    Assert-Same 'OTA 识别' $true $a.IsOta
    Assert-Same 'OTA 源版本' 'v6.16.0' $a.FromVersion
    Assert-Same 'OTA 目标版本' 'v6.19.0' $a.ToVersion
    Assert-Same 'OTA 架构' 'x64' $a.Arch
    $b = Parse-GithubAssetName 'MAA-v6.19.0-win-x64.zip'
    Assert-Same '完整包识别' $false $b.IsOta
    Assert-Same '完整包版本' 'v6.19.0' $b.Version
    Assert-Same '完整包架构' 'x64' $b.Arch
    $c = Parse-GithubAssetName 'MAA-v6.19.0-win-arm64.zip'
    Assert-Same 'arm64 识别' 'arm64' $c.Arch
    Assert-Same 'arm64 不是 x64' $false ($c.Arch -eq 'x64')

    # ---------- 跨通道最新版解析 & 更新包选择（模拟 API，不联网） ----------
    Write-Host '--- Resolve-MaaRelease / Select-MaaAsset（离线模拟） ---' -ForegroundColor Cyan
    $script:MockJson = @{}
    function Invoke-GetJson { param([string]$Url, [int]$TimeoutSec = 15, [string]$Proxy = '') if ($script:MockJson.ContainsKey($Url)) { return $script:MockJson[$Url] } return $null }
    function New-MockAsset {
        param([string]$Base, [string[]]$Names, [string]$Tag)
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($n in $Names) {
            $list.Add([pscustomobject]@{ name = $n; size = 1000000; sha256 = 'deadbeef'; browser_download_url = "$Base/releases/download/$Tag/$n" })
        }
        return $list
    }
    $mockBase = 'https://github.com/MaaAssistantArknights/MaaRelease'
    $script:MockJson["$MaaApiBase/$SummaryApi"] = [pscustomobject]@{
        stable = [pscustomobject]@{ version = 'v6.19.2'; detail = "$MaaApiBase/version/stable.json" }
        beta   = [pscustomobject]@{ version = 'v6.19.2-beta.2'; detail = "$MaaApiBase/version/beta.json" }
        alpha  = [pscustomobject]@{ version = 'v6.19.3-alpha.1'; detail = "$MaaApiBase/version/alpha.json" }
    }
    $stableNames = @('MAA-v6.19.2-win-x64.zip', 'MAA-v6.19.2-win-arm64.zip',
        'MAAComponent-OTA-v6.19.0_v6.19.2-win-x64.zip', 'MAAComponent-OTA-v6.19.0-beta.1_v6.19.2-win-x64.zip',
        'MAAComponent-OTA-v6.19.2-beta.1_v6.19.2-win-x64.zip', 'MAAComponent-OTA-v6.19.2-beta.2_v6.19.2-win-x64.zip',
        'MAAComponent-OTA-v6.19.2-beta.2.d010.ga7ee2c2bf7_v6.19.2-win-x64.zip', 'MAAComponent-OTA-v6.19.2-beta.2.d050.gb93089d920_v6.19.2-win-x64.zip')
    $betaNames = @('MAA-v6.19.2-beta.2-win-x64.zip',
        'MAAComponent-OTA-v6.19.2-beta.1_v6.19.2-beta.2-win-x64.zip',
        'MAAComponent-OTA-v6.19.2-beta.2_v6.19.2-beta.2-win-x64.zip')
    foreach ($u in @("$MaaApiBase/version/stable.json", "$MaaApiBase/version/beta.json")) {
        $ch = if ($u -like '*beta*') { 'beta' } else { 'stable' }
        $tag = if ($ch -eq 'beta') { 'v6.19.2-beta.2' } else { 'v6.19.2' }
        $names = if ($ch -eq 'beta') { $betaNames } else { $stableNames }
        $script:MockJson[$u] = [pscustomobject]@{ version = $tag; details = [pscustomobject]@{ tag_name = $tag; assets = (New-MockAsset $mockBase $names $tag) } }
    }
    $script:MockJson["$MaaApiBase/version/alpha.json"] = [pscustomobject]@{ version = 'v6.19.3-alpha.1'; details = [pscustomobject]@{ tag_name = 'v6.19.3-alpha.1'; assets = (New-MockAsset $mockBase @('MAA-v6.19.3-alpha.1-win-x64.zip') 'v6.19.3-alpha.1') } }

    $relBeta = Resolve-MaaRelease -RequestedChannel 'beta'
    Assert-Same '跨通道：beta 取到更新的正式版' 'v6.19.2' $relBeta.Version
    Assert-Same '跨通道：来源通道为 stable' 'stable' $relBeta.Channel
    $relAlpha = Resolve-MaaRelease -RequestedChannel 'alpha'
    Assert-Same '跨通道：alpha 取到自己的最新版' 'v6.19.3-alpha.1' $relAlpha.Version

    $info = Select-MaaAsset -Release $relBeta -CurrentVersion 'v6.19.2-beta.1' -Arch 'x64'
    Assert-Same 'beta.1 → 6.19.2 用 OTA' 'OTA' $info.Type
    Assert-Same 'beta.1 → 6.19.2 OTA 源版本' 'v6.19.2-beta.1' $info.OtaFrom
    Assert-Same 'beta.1 → 6.19.2 OTA 目标版本' 'v6.19.2' $info.OtaTarget

    $info2 = Select-MaaAsset -Release $relBeta -CurrentVersion 'v6.19.2-beta.2' -Arch 'x64'
    Assert-Same 'beta.2 → 6.19.2 精确匹配 OTA' 'v6.19.2-beta.2' $info2.OtaFrom

    $info3 = Select-MaaAsset -Release $relBeta -CurrentVersion 'v6.19.2-beta.2.d010.ga7ee2c2bf7' -Arch 'x64'
    # 夜间版全名精确命中同名 OTA 时直接用该 OTA（文件差异最小）
    Assert-Same '夜间版 → 6.19.2 精确命中同名夜间版 OTA' 'v6.19.2-beta.2.d010.ga7ee2c2bf7' $info3.OtaFrom

    $info4 = Select-MaaAsset -Release $relBeta -CurrentVersion 'v6.10.7' -Arch 'x64'
    Assert-Same '过旧版本 → 回退完整包' '完整包' $info4.Type
    Assert-Same '完整包版本' 'v6.19.2' (Parse-GithubAssetName ([string]$info4.Asset.name)).Version

    $info5 = Select-MaaAsset -Release $relBeta -CurrentVersion 'v6.19.3' -Arch 'x64'
    Assert-Same '高于全部 OTA 源版本 → 取源版本最高者' 'v6.19.2-beta.2' $info5.OtaFrom

    $infoArm = Select-MaaAsset -Release $relBeta -CurrentVersion 'v6.19.2-beta.2' -Arch 'arm64'
    Assert-Same 'arm64 回退完整包' '完整包' $infoArm.Type
    Assert-Same 'arm64 完整包文件名' 'MAA-v6.19.2-win-arm64.zip' ([string]$infoArm.Asset.name)

    $cand = Get-DownloadCandidates -Url $mockBase
    Assert-Same '候选数：直连1+镜像N' (1 + $MirrorHosts.Count) (1 + $cand.Mirrors.Count)
    Assert-Same '镜像 URL 前缀正确' $true ([string]$cand.Mirrors[0]).StartsWith('http')

    # ---------- 用户报告的核心场景：6.19.2-beta.2 → 6.19.2 ----------
    Write-Host '--- 核心场景：beta.2 用户能否更新到正式版 6.19.2 ---' -ForegroundColor Cyan
    $relBeta2 = Resolve-MaaRelease -RequestedChannel 'beta'
    $fixInfo = Select-MaaAsset -Release $relBeta2 -CurrentVersion 'v6.19.2-beta.2' -Arch 'x64'
    Assert-Same 'beta.2 → 6.19.2 不误报已是最新' $true ((Compare-SemVer $relBeta2.Version 'v6.19.2-beta.2') -gt 0)
    Assert-Same 'beta.2 → 6.19.2 选中目标版本' 'v6.19.2' $fixInfo.Version
    Assert-Same 'beta.2 → 6.19.2 使用 OTA' 'OTA' $fixInfo.Type
    Assert-Same 'beta.2 → 6.19.2 OTA 文件名' 'MAAComponent-OTA-v6.19.2-beta.2_v6.19.2-win-x64.zip' ([string]$fixInfo.Asset.name)
    # ---------- 资源包候选地址 ----------
    $script:MockJson['https://cdn.jsdelivr.net/gh/MaaAssistantArknights/MaaResource@main/resource/version.json'] = [pscustomobject]@{ last_updated = '2026-08-23 01:57:24.000' }
    # 自测必须与运行环境无关：临时把资源版本缓存指到不存在的文件，
    # 否则在真实安装目录里会读到本地缓存，导致断言结果随环境变化
    $savedResCache = $ResCacheFile
    $ResCacheFile = Join-Path $env:TEMP "maa_selftest_no_cache_$(Get-Random).json"
    try { $rt = Get-RemoteResourceTime } finally { $ResCacheFile = $savedResCache }
    Assert-Same '远程资源版本可解析' '2026-08-23 01:57:24' $rt.ToString('yyyy-MM-dd HH:mm:ss')
    Assert-Same '资源时间戳比较：新资源需要更新' $true ($rt -gt (ConvertTo-ResourceTime '2026-08-20 15:52:45'))

    # ---------- 线路选择必须按「持续吞吐」而非「起步延迟」（曾经的选路缺陷） ----------
    # 背景：探测原先报的是拿到首批 64KB 的耗时，起步 42ms 被误当成"够快"，
    # 于是跳过镜像；实测该线路持续只有 127 KB/s，而镜像有 384 KB/s。
    Write-Host '--- 线路选择判据：吞吐优先 ---' -ForegroundColor Cyan
    $fakeCand = @{ Direct = 'https://example.invalid/d'; Proxied = 'https://example.invalid/d'; Mirrors = @('https://example.invalid/m1') }
    $script:HasPseudoProbe = $true
    $oldSpeedFn = ${function:Test-DownloadSpeed}
    function Test-DownloadSpeed {
        param([string]$Url, [int]$TimeoutSec = 5, [long]$TestBytes = 64KB, [string]$Proxy = '', [switch]$NoProxy, [switch]$Ms)
        # 直连：起步很快(40ms)但吞吐很低(120 KB/s)；镜像：吞吐高(1500 KB/s)
        if ($Url -like '*example.invalid/d*') { return @{ Url = $Url; SpeedBps = [long](120 * 1KB); Ms = 40 } }
        return @{ Url = $Url; SpeedBps = [long](1500 * 1KB); Ms = 900 }
    }
    $script:SysProxy = ''
    $routeProbe = Test-UrlCandidates -Candidates $fakeCand
    ${function:Test-DownloadSpeed} = $oldSpeedFn
    Assert-Same '低吞吐直连不再跳过镜像探测' 2 @($routeProbe).Count
    Assert-Same '高吞吐镜像胜出（不再迷信起步延迟）' '镜像' @($routeProbe)[0].Route
    Assert-Same '首条即最快吞吐' $true (@($routeProbe)[0].Kbs -ge @($routeProbe)[1].Kbs)
    # ---------- 属性访问兼容层（曾经的 P0：pscustomobject 上调 ContainsKey 抛异常） ----------
    Write-Host '--- Test-HasProperty / Get-ObjectProperty ---' -ForegroundColor Cyan
    Assert-Same 'hashtable 有属性' $true (Test-HasProperty @{ NoProxy = $true } 'NoProxy')
    Assert-Same 'hashtable 无属性' $false (Test-HasProperty @{ Url = 'x' } 'NoProxy')
    Assert-Same 'pscustomobject 有属性' $true (Test-HasProperty ([pscustomobject]@{ NoProxy = $true }) 'NoProxy')
    Assert-Same 'pscustomobject 无属性' $false (Test-HasProperty ([pscustomobject]@{ Url = 'x' }) 'NoProxy')
    Assert-Same 'PSCustomObject 上不会误调 ContainsKey' $false (Test-HasProperty ([pscustomobject]@{ Url = 'x' }) 'NoProxy')
    Assert-Same '取值(hashtable)' $true (Get-ObjectProperty @{ NoProxy = $true } 'NoProxy' $false)
    Assert-Same '取值(pscustomobject)' $false (Get-ObjectProperty ([pscustomobject]@{ NoProxy = $false }) 'NoProxy' $true)
    Assert-Same '缺省值' 'def' (Get-ObjectProperty ([pscustomobject]@{ Url = 'x' }) 'Missing' 'def')
    Assert-Same '$null 安全' 'def' (Get-ObjectProperty $null 'Anything' 'def')

    # 干跑一次候选下载流程：只验证记录遍历与属性读取不抛异常
    $probeRun = Invoke-CandidateDownload -OutFile (Join-Path $env:TEMP 'maa_should_not_exist.bin') -DisplayName '干跑' `
        -Probes @([pscustomobject]@{ Url = 'https://127.0.0.1:1/none'; Ms = 1; Route = '直连'; NoProxy = $true }) `
        -DirectUrl 'https://127.0.0.1:1/none' -ProxiedUrl 'https://127.0.0.1:1/none' -MirrorUrls @('https://127.0.0.1:1/none') -MaxAttempts 1
    Assert-Same '候选下载流程不抛异常（返回 false）' $false $probeRun
    # ---------- 资源 URL 构造（防止变量名丢失导致 URL 为空） ----------
    Assert-Same '资源仓库变量已定义' 'MaaAssistantArknights/MaaResource' $ResourceRepo
    Assert-Same '资源版本 URL 完整' 'https://raw.githubusercontent.com/MaaAssistantArknights/MaaResource/main/resource/version.json' $ResourceVersionUrl
    Assert-Same '资源 CDN URL 完整' 'https://cdn.jsdelivr.net/gh/MaaAssistantArknights/MaaResource@main/resource/version.json' $ResVersionCdnUrl
    Assert-Same '资源归档 URL 完整' 'https://github.com/MaaAssistantArknights/MaaResource/archive/refs/heads/main.zip' $ResourceArchiveUrl
    Assert-Same '镜像拼接后 URL 合法' $true ([string]$MirrorHosts[0]).TrimEnd('/').Length -gt 0
    Assert-Same '镜像拼接无缺斜杠' $true ("$($MirrorHosts[0].TrimEnd('/'))/$ResourceVersionUrl") -eq "https://gh-proxy.com/$ResourceVersionUrl"
    # ---------- 资源时间戳解析 ----------
    Assert-Same '资源时间戳（.fff）' '2026-08-23 01:57:24' ((ConvertTo-ResourceTime '2026-08-23 01:57:24.000').ToString('yyyy-MM-dd HH:mm:ss'))
    Assert-Same '资源时间戳（无 .fff）' '2026-08-23 01:57:24' ((ConvertTo-ResourceTime '2026-08-23 01:57:24').ToString('yyyy-MM-dd HH:mm:ss'))
    Assert-Same '资源时间戳（T 分隔）' '2026-08-23 01:57:24' ((ConvertTo-ResourceTime '2026-08-23T01:57:24.000').ToString('yyyy-MM-dd HH:mm:ss'))
    Assert-Same '资源时间戳（无效值）' $null (ConvertTo-ResourceTime 'not-a-date')
    Write-Host ''
    if ($script:fail -eq 0) { Write-Host '自测全部通过 ✔' -ForegroundColor Green; return $true }
    Write-Host "自测失败 $($script:fail) 项 ✘" -ForegroundColor Red
    return $false
}

# ======== 发布包文件名解析 ========
function Parse-GithubAssetName {
    param([string]$Name)
    $r = @{ IsOta = $false; Arch = ''; Version = ''; FromVersion = ''; ToVersion = ''; BaseVersion = ''; Name = ([string]$Name) }
    if (-not $Name) { return $r }
    $n = [string]$Name

    # 完整包: MAA-v6.19.0-win-x64.zip / MAA-v6.17.0-beta.5-win-x64.zip
    if ($n -match '^MAA-(v[\d\.]+(?:-[0-9A-Za-z\.]+)?)-win-(x64|arm64)\.zip$') {
        $r.Version = $matches[1]
        $r.Arch = $matches[2]
        $r.BaseVersion = Get-VersionBase $matches[1]
        return $r
    }
    # OTA 增量包: MAAComponent-OTA-v6.16.0_v6.19.0-win-x64.zip
    if ($n -match '^MAAComponent-OTA-(v[\d\.]+(?:-[0-9A-Za-z\.]+)?)_(v[\d\.]+(?:-[0-9A-Za-z\.]+)?)-win-(x64|arm64)\.zip$') {
        $r.IsOta = $true
        $r.FromVersion = $matches[1]
        $r.ToVersion = $matches[2]
        $r.Arch = $matches[3]
        $r.Version = $matches[2]
        $r.BaseVersion = Get-VersionBase $matches[2]
        return $r
    }
    return $r
}

# ======== 下载候选地址（镜像 / 代理 / 直连） ========
# 返回 @{ Direct = <# 不经过代理，直达 GitHub>; Proxied = <# 经过代理>; Mirrors = <# 公共镜像> }
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

# 探测每条线路是否可用（读取 64KB 即停），返回按延迟升序排列的候选列表
# 探测每条线路是否可用（读取 64KB 即停），返回按延迟升序排列的候选列表。
# 策略：先探测直连与代理这两条"短路径"，任一可用就跳过镜像探测，
#       避免在直连/代理已经很快时白白花时间测一堆镜像。
# 探测各线路的「可用性 + 持续吞吐」。
# 关键点：不能拿"首批 64KB 的耗时"当网速用。起步 40ms 只说明 TCP 建连快，
# 不代表 300MB 拉得动（实测见过起步 42ms 但持续只有 127 KB/s 的线路）。
# 因此这里统一以实测吞吐（KB/s）作为判据，并按吞吐降序排序后返回。
function Test-UrlCandidates {
    param($Candidates, [string]$Label = '下载源')
    $probe = New-Object System.Collections.Generic.List[object]
    $directSpeed = -1
    $proxySpeed = -1
    $mirrorUp = 0
    $mirrorCount = @($Candidates.Mirrors).Count
    $mirrorSkipped = 0
    # 达到这个吞吐（KB/s）才认为"这条线路够了，不必再测镜像"
    $goodEnoughKBs = 400

    # 直连探测失败时再给一次机会：TUN/代理客户端的出口节点轮换会让单次探测偶发失败
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $r = Test-DownloadSpeed -Url $Candidates.Direct -TimeoutSec 6 -TestBytes 256KB -NoProxy
        if ($r -ne -1) { break }
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 400 }
    }
    if ($r -ne -1) {
        $directSpeed = [math]::Round($r.SpeedBps / 1024, 1)
        $probe.Add([pscustomobject]@{ Url = $Candidates.Direct; Kbs = $directSpeed; Ms = $r.Ms; Route = '直连'; NoProxy = $true })
    }

    if ($script:SysProxy) {
        $r2 = Test-DownloadSpeed -Url $Candidates.Proxied -TimeoutSec 6 -TestBytes 256KB -Proxy $script:ProxyConfig.ForCurl
        if ($r2 -ne -1) {
            $proxySpeed = [math]::Round($r2.SpeedBps / 1024, 1)
            $probe.Add([pscustomobject]@{ Url = $Candidates.Proxied; Kbs = $proxySpeed; Ms = $r2.Ms; Route = '代理'; NoProxy = $false })
        }
    }

    # 直连/代理已经足够快才跳过镜像；否则镜像很可能更快，必须测
    if (($directSpeed -ge $goodEnoughKBs) -or ($proxySpeed -ge $goodEnoughKBs)) {
        $mirrorSkipped = $mirrorCount
    }
    else {
        foreach ($mu in $Candidates.Mirrors) {
            $rm = Test-DownloadSpeed -Url $mu -TimeoutSec 6 -TestBytes 256KB -NoProxy
            if ($rm -ne -1) {
                $probe.Add([pscustomobject]@{ Url = $mu; Kbs = [math]::Round($rm.SpeedBps / 1024, 1); Ms = $rm.Ms; Route = '镜像'; NoProxy = $true })
                $mirrorUp++
            }
        }
    }

    if ($directSpeed -ge 0) { Write-Info "GitHub 直连: ${directSpeed} KB/s" } else { Write-Info 'GitHub 直连不可用' }
    if ($script:SysProxy) {
        if ($proxySpeed -ge 0) { Write-Info "代理线路: ${proxySpeed} KB/s" }
        else { Write-Info '代理线路不可用（代理未开启、已失效，或代理不允许访问 GitHub）' }
    }
    if ($mirrorSkipped -gt 0) { Write-Info "直连/代理已达 ${goodEnoughKBs} KB/s，跳过 $mirrorSkipped 个镜像探测" }
    else { Write-Info "镜像可用 $mirrorUp/$mirrorCount 个" }

    if ($probe.Count -eq 0) { return @() }
    # 按实测吞吐降序：起点快的线路不一定持续快，只有吞吐能说明问题
    return @($probe | Sort-Object -Property @{ Expression = { [double]$_.Kbs } } -Descending)
}

# ======== DNS 加速（中国 DNS 解析 + 测速 + curl --resolve） ========
# 注意：仅在「直连」线路上使用 --resolve 钉住 IP。有代理时 DNS 由代理侧完成，
# 钉住 IP 反而可能指向不可用的解析结果，故代理线路不带 --resolve。
$DnsChina = @('223.5.5.5', '114.114.114.114', '119.29.29.29')
$SlowDomains = @('raw.githubusercontent.com', 'github.com', 'codeload.github.com')
$script:BestIps = @{}
$script:CurlResolve = @()

function Resolve-DomainFast {
    param([string]$Domain)
    $allDns = $DnsChina + @('System')
    foreach ($dns in $allDns) {
        try {
            if ($dns -eq 'System') {
                $entry = [System.Net.Dns]::GetHostEntry($Domain)
                $ips = $entry.AddressList | Where-Object { $_ -is [System.Net.IPAddress] } | ForEach-Object { $_.ToString() }
            }
            else {
                $raw = & nslookup $Domain $dns 2>$null
                if ($LASTEXITCODE -ne 0) { continue }
                $ips = @()
                foreach ($line in $raw) {
                    if ($line -match '(\d+\.\d+\.\d+\.\d+)') { $ips += $matches[1] }
                }
                $ips = $ips | Select-Object -Unique | Where-Object { $_ -ne $Domain -and $_ -ne $dns }
            }
        }
        catch { continue }
        if ($ips.Count -gt 0) { return $ips }
    }
    return @()
}
function Test-IpSpeed {
    param([string]$Ip, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $socket = New-Object System.Net.Sockets.TcpClient
    $async = $socket.BeginConnect($Ip, $Port, $null, $null)
    if ($async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        $socket.EndConnect($async); $socket.Close()
        return $sw.ElapsedMilliseconds
    }
    return -1
}
function Initialize-DnsAccel {
    # 有代理时不做 IP 钉定：DNS 解析发生在代理侧，客户端测到的速度没有参考意义
    if ($script:SysProxy) { Write-Info '已启用代理，跳过 DNS 直连加速'; return }
    try {
        Write-Info '正在测速 DNS 解析...'
        foreach ($dom in $SlowDomains) {
            $ips = Resolve-DomainFast $dom
            if ($ips.Count -eq 0) { Write-Warn "$dom DNS 解析失败"; continue }
            $bestIp = $null; $bestMs = [long]::MaxValue
            foreach ($ip in $ips) {
                $ms = Test-IpSpeed $ip
                if ($ms -ge 0 -and $ms -lt $bestMs) { $bestMs = $ms; $bestIp = $ip }
            }
            if ($bestIp) {
                $script:BestIps[$dom] = $bestIp
                Write-Ok "$dom → $bestIp (${bestMs}ms)"
                if ($script:HasCurl) { $script:CurlResolve += "--resolve", "$dom`:443`:$bestIp", "--resolve", "$dom`:80`:$bestIp" }
            }
        }
    }
    catch { Write-Warn "DNS 加速失败" }
}
# ======== 配置 ========
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$TempDir = Join-Path $ScriptDir ".update_temp"
$BackupDir = Join-Path $ScriptDir ".update_backup"
$LogFile = Join-Path $ScriptDir "update_log.txt"
$StateFile = Join-Path $ScriptDir ".update_state"
$CacheDir = Join-Path $ScriptDir "cache\api"
$PwshDir = Join-Path $ScriptDir '.pwsh'
$PwshMarkerFile = Join-Path $ScriptDir '.pwsh_auto_attempted'
$script:PwshPath = $null
$script:HasPwsh = $false
$MaaApiBase = 'https://api.maa.plus/MaaAssistantArknights/api'
$MaaApiBase2 = 'https://api2.maa.plus/MaaAssistantArknights/api'
$MirrorHosts = @(
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
    'https://gh.ddlc.top/',
    'https://ghproxy.homeboyc.cn/'
)
$ResourceRepo = 'MaaAssistantArknights/MaaResource'
$ResourceArchiveUrl = "https://github.com/$ResourceRepo/archive/refs/heads/main.zip"
$ResourceVersionUrl = "https://raw.githubusercontent.com/$ResourceRepo/main/resource/version.json"
$ResVersionCdnUrl = "https://cdn.jsdelivr.net/gh/$ResourceRepo@main/resource/version.json"
$SummaryApi = 'version/summary.json'
$MaxRetries = 2
$PreserveDirs = @('achievement', 'background', 'cache', 'config', 'data', 'debug', 'resource')

# ======== 等待提示（所有操作用） ========
function Show-Wait { param([string]$Msg) Write-Host "  ⏳ $Msg" -ForegroundColor DarkYellow }

# ======== 日志 ========
# 说明：这里必须把每条日志同时写入 $LogFile，否则 bat 窗口关闭后就没有任何可分析的记录。
function Write-Log {
    param([string]$Level, [string]$Message)
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$time][$Level] $Message"
    # 自测模式只打印，不写文件（否则会在脚本目录留下无意义的 update_log.txt）
    if (-not $SelfTest) { try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch {} }
    switch ($Level) {
        'INFO' { Write-Host "[信息] $Message" -ForegroundColor Cyan }
        'OK' { Write-Host "[成功] $Message" -ForegroundColor Green }
        'WARN' { Write-Host "[注意] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[错误] $Message" -ForegroundColor Red }
        'STEP' { Write-Host "`n>>> $Message" -ForegroundColor Magenta }
    }
}

function Write-Step { Write-Log 'STEP' $args }
function Write-Info { Write-Log 'INFO' $args }
function Write-Ok { Write-Log 'OK' $args }
function Write-Warn { Write-Log 'WARN' $args }
function Write-Err { Write-Log 'ERROR' $args }

# ======== 状态管理 ========
function Set-State {
    param([string]$Phase, [string]$Version = '', [string]$Detail = '')
    @{ Phase = $Phase; Version = $Version; Detail = $Detail; Time = (Get-Date -Format 'o') } |
    ConvertTo-Json -Compress | Set-Content $StateFile -Encoding UTF8
}

function Clear-State { if (Test-Path $StateFile) { Remove-Item -Force $StateFile } }

# ======== 工具函数 ========
# 统一读取属性：同时兼容 hashtable 与 PSCustomObject。
# 注意：不要在记录对象上调用 .ContainsKey()，hashtable 才有该方法；
# PSCustomObject 上调用会抛 "does not contain a method named 'ContainsKey'"。
function Test-HasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ObjectProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function New-WebProxyOrNull {
    param([string]$Address)
    # SOCKS 代理无法交给 .NET 使用，返回 $null 表示直连（由 curl 处理代理）
    if (-not $Address) { return $null }
    if ($Address -match '^(socks4|socks4a|socks5|socks5h)://') { return $null }
    try { return New-Object System.Net.WebProxy($Address) } catch { return $null }
}

function Invoke-GetJson {
    param([string]$Url, [int]$TimeoutSec = 15, [string]$Proxy = '')
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'; $req.Timeout = $TimeoutSec * 1000; $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'MAA-Update/2.2'
        if ($Proxy) { $req.Proxy = New-WebProxyOrNull $Proxy }
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $json = $reader.ReadToEnd(); $resp.Close(); $reader.Close()
        return ($json | ConvertFrom-Json)
    }
    catch { return $null }
}

# 多来源按序尝试，返回第一个可解析且满足 $Validate 的结果
function Get-FirstJson {
    param([string[]]$Urls, [scriptblock]$Validate = $null, [int]$TimeoutSec = 10, [int]$Rounds = 2)
    for ($i = 1; $i -le $Rounds; $i++) {
        if ($i -gt 1) { Write-Info "重试第 $i 次..." }
        Show-Wait "[$i/$Rounds] 正在检查资源版本..."
        foreach ($u in $Urls) {
            $j = Invoke-GetJson $u -TimeoutSec $TimeoutSec
            if ($j -and ((-not $Validate) -or (& $Validate $j))) { return $j }
        }
    }
    return $null
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return '未知' }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# ======== 实际下载测速（替代 HEAD 延迟测速，解决 TUN 下全0ms 问题） ========
# 返回耗时毫秒数；-1 表示不可用
function Test-DownloadSpeed {
    param([string]$Url, [int]$TimeoutSec = 5, [long]$TestBytes = 100KB, [string]$Proxy = '', [switch]$NoProxy, [switch]$Ms)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'MAA-Update/2.2'
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
        # -Ms：返回耗时毫秒（用于线路探测排序）；否则返回速度对象
        if ($Ms) { return [long]$sw.ElapsedMilliseconds }
        return @{ Url = $Url; SpeedBps = [long]($totalRead * 1000 / [Math]::Max($sw.ElapsedMilliseconds, 1)) }
    }
    catch { return -1 }
}

function Test-ZipPathSafety {
    param([string]$ZipPath, [string]$DestDir)
    # 验证ZIP文件路径安全性，防止路径遍历攻击
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $destDirFull = [System.IO.Path]::GetFullPath($DestDir)
        foreach ($entry in $zip.Entries) {
            # 跳过目录条目
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            # 构造目标路径
            $targetPath = [System.IO.Path]::Combine($destDirFull, $entry.FullName)
            $targetPathFull = [System.IO.Path]::GetFullPath($targetPath)
            # 验证目标路径是否在目标目录内
            if (-not $targetPathFull.StartsWith($destDirFull, [StringComparison]::OrdinalIgnoreCase)) {
                $zip.Dispose()
                return $false
            }
        }
        $zip.Dispose()
        return $true
    }
    catch {
        # 如果无法验证，允许解压（但会记录警告）
        return $true
    }
}

function Expand-Zip {
    param([string]$ZipPath, [string]$DestDir)
    # 验证ZIP文件安全性
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

function New-Directory {
    param([string]$Path, [switch]$Secure)
    if (-not (Test-Path $Path)) {
        $dir = New-Item -ItemType Directory -Path $Path -Force
        if ($Secure) {
            # 设置安全权限：仅当前用户完全控制
            $acl = Get-Acl $Path
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                "FullControl",
                "ContainerInherit,ObjectInherit",
                "None",
                "Allow"
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $Path -AclObject $acl
        }
        $dir | Out-Null
    }
}

# ======== 分片下载（大文件加速） ========
function Start-SegmentedDownload {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0, [int]$Segments = 4, [long]$MinSize = 10MB)

    try {
        # HEAD 获取总大小
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'; $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
        $req.UserAgent = 'MAA-Update/2.2'
        $resp = $req.GetResponse()
        $totalLen = $resp.ContentLength; $resp.Close()
        if ($totalLen -le $MinSize) { return $false }
    }
    catch { return $false }

    $segFiles = @()
    try {
        Write-Info "启用分片下载 ($Segments 片, 共 $(Format-FileSize $totalLen))"
        New-Directory (Split-Path $OutFile -Parent)

        $segSize = [Math]::Ceiling($totalLen / $Segments)
        $segFiles = @(); $segTasks = @(); $psInstances = @()
        $pool = [RunspaceFactory]::CreateRunspacePool(1, $Segments)
        $pool.Open()

        for ($i = 0; $i -lt $Segments; $i++) {
            $from = $i * $segSize
            $to = [Math]::Min(($i + 1) * $segSize - 1, $totalLen - 1)
            $segFile = "$OutFile.part$i"
            $segFiles += $segFile

            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript({
                    param($u, $f, $t, $o)
                    $r = [System.Net.HttpWebRequest]::Create($u)
                    $r.Method = 'GET'; $r.Timeout = 30000; $r.ReadWriteTimeout = 120000
                    $r.UserAgent = 'MAA-Update/2.2'; $r.AddRange($f, $t)
                    $s = $r.GetResponse().GetResponseStream()
                    $fs = [System.IO.File]::Create($o)
                    $buf = New-Object byte[] 65536
                    while (($rd = $s.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $rd) }
                    $fs.Close(); $s.Close()
                }).AddParameters(@{u = $Url; f = $from; t = $to; o = $segFile })
            $psInstances += $ps
            $segTasks += $ps.BeginInvoke()
        }

        $failed = $false
        for ($i = 0; $i -lt $Segments; $i++) {
            try {
                $segTasks[$i].AsyncWaitHandle.WaitOne() | Out-Null
                $null = $psInstances[$i].EndInvoke($segTasks[$i])
            } catch { $failed = $true; Write-Warn "分片 $i 下载失败" }
        }
        $pool.Close(); $pool.Dispose()
        foreach ($psInstance in $psInstances) { $psInstance.Dispose() }

        if ($failed) { throw '分片下载失败' }

        # 合并前检查所有分片存在且非空
        foreach ($f in $segFiles) {
            if (-not (Test-Path $f) -or (Get-Item $f).Length -eq 0) { throw "分片文件缺失或为空: $f" }
        }

        $fsOut = [System.IO.File]::Create($OutFile)
        foreach ($f in $segFiles) {
            $fsIn = [System.IO.File]::OpenRead($f)
            $fsIn.CopyTo($fsOut); $fsIn.Close()
            Remove-Item -Force $f
        }
        $fsOut.Close()

        $actualSize = (Get-Item $OutFile).Length
        if ($ExpectedSize -gt 0 -and $actualSize -ne $ExpectedSize) {
            Write-Warn "分片下载大小不匹配: 期望 $(Format-FileSize $ExpectedSize), 实际 $(Format-FileSize $actualSize)"
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue; return $false
        }
        Write-Ok "$DisplayName 下载完成 ($(Format-FileSize $actualSize), 分片)"
        return $true
    }
    catch {
        Write-Warn "分片下载失败，回退单线程"
        foreach ($f in $segFiles) { Remove-Item -Force $f -ErrorAction SilentlyContinue }
        return $false
    }
}

# ======== 查找 pwsh（PATH + 常见安装路径） ========
function Find-PwshPath {
    $e = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($e) { $script:PwshPath = $e.Source; $script:HasPwsh = $true; return $true }
    $paths = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "$env:ProgramFiles\PowerShell\7-preview\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { $script:PwshPath = $p; $script:HasPwsh = $true; return $true }
    }
    return $false
}

# ======== pwsh 自动安装（仅首次运行尝试自动下载） ========
function Ensure-Pwsh {
    $localPwsh = Join-Path $PwshDir 'pwsh.exe'
    # 已安装或便携版已存在
    if (Find-PwshPath) { return $true }
    if (Test-Path $localPwsh) { $script:PwshPath = $localPwsh; $script:HasPwsh = $true; return $true }
    # 已尝试过自动安装 → 仅提示，不再检查本地安装包或下载
    if (Test-Path $PwshMarkerFile) {
        Write-Warn 'PowerShell 7 未安装。HTTP/2 下载不可用，可能影响资源更新。'
        Write-Warn '请从微软商店安装：https://apps.microsoft.com/detail/9mz1snwt0n5d?hl=zh-CN&gl=CN'
        return $false
    }
    # 首次运行：检查本地安装包 + 自动下载
    Write-Info 'PowerShell 7 未安装，首次运行尝试安装...'
    $localInstaller = Get-ChildItem "$ScriptDir\*" -Include 'PowerShell*.exe', 'PowerShell*.msi', 'PowerShell*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($localInstaller) {
        $inst = $localInstaller.FullName
        Write-Info "发现本地安装包: $($localInstaller.Name)"
        if ($inst -match '\.msi$') {
            $p = Start-Process msiexec.exe -ArgumentList "/package `"$inst`" /quiet ADD_PATH=1" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0 -and (Find-PwshPath)) { Remove-Item -Force $inst; Write-Ok 'PowerShell 7 安装成功'; return $true }
        } elseif ($inst -match '\.zip$') {
            New-Directory $PwshDir; Expand-Zip $inst $PwshDir
            if (Test-Path $localPwsh) { $script:PwshPath = $localPwsh; $script:HasPwsh = $true; Remove-Item -Force $inst; Write-Ok 'PowerShell 便携版就绪'; return $true }
        } elseif ($inst -match '\.exe$') {
            $p = if ($script:IsAdmin) { Start-Process $inst -ArgumentList '/quiet', 'ADD_PATH=1' -Wait -PassThru -NoNewWindow } else { Start-Process $inst -Wait -PassThru -NoNewWindow }
            if ($p.ExitCode -eq 0 -and (Find-PwshPath)) { Remove-Item -Force $inst; Write-Ok 'PowerShell 7 安装成功'; return $true }
        }
        Write-Warn "本地安装包处理失败"
    }
    # 首次运行：自动尝试安装
    Write-Info 'PowerShell 7 未安装，首次运行尝试自动下载...'
    $pwshVer = '7.6.2'
    $wg = Get-Command 'winget' -ErrorAction SilentlyContinue
    if ($wg) {
        Write-Info '使用 winget 安装 PowerShell（正在下载，请耐心等待）...'
        $p = Start-Process winget -ArgumentList 'install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--installer-type', 'wix', '--silent', '--accept-package-agreements' -NoNewWindow -PassThru
        $done = $p.WaitForExit(300000)
        if (-not $done) { $p.Kill(); Write-Warn 'winget 超时' }
        else { Start-Sleep 2; if (Find-PwshPath) { New-Item -Force $PwshMarkerFile | Out-Null; return $true } }
    }
    if (Find-PwshPath) { New-Item -Force $PwshMarkerFile | Out-Null; return $true }
    # 从微软 CDN 下载 PowerShell（国内可访问）
    Write-Info '从微软 CDN 尝试下载 PowerShell 7...'
    $pwshCdnUrl = "https://dotnetcli.azureedge.net/PowerShell/$pwshVer/PowerShell-$pwshVer-win-x64.msi"
    $pwshMsiPath = Join-Path $TempDir "PowerShell-$pwshVer-win-x64.msi"
    $pwshDlOk = $false
    if ($script:HasCurl) {
        New-Directory $TempDir
        & curl.exe -L -f -o $pwshMsiPath $pwshCdnUrl --connect-timeout 10 --max-time 120
        if ($LASTEXITCODE -eq 0 -and (Test-Path $pwshMsiPath)) { $pwshDlOk = $true }
    }
    if (-not $pwshDlOk) {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($pwshCdnUrl, $pwshMsiPath)
            if (Test-Path $pwshMsiPath) { $pwshDlOk = $true }
        } catch {}
    }
    if ($pwshDlOk) {
        $p = Start-Process msiexec.exe -ArgumentList "/package `"$pwshMsiPath`" /quiet ADD_PATH=1" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) { Start-Sleep 2; if (Find-PwshPath) { Remove-Item -Force $pwshMsiPath; Write-Ok 'PowerShell 7 安装成功'; return $true } }
        Remove-Item -Force $pwshMsiPath -ErrorAction SilentlyContinue
    }
    # 创建标记，下次不再自动下载
    New-Item -Force $PwshMarkerFile | Out-Null
    Write-Warn 'PowerShell 7 自动安装失败。尝试从微软商店安装：'
    Write-Warn 'https://apps.microsoft.com/detail/9mz1snwt0n5d?hl=zh-CN&gl=CN'
    return $false
}

# ======== HTTP/2 下载（pwsh + .NET SocketsHttpHandler） ========
function Start-Http2Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0, [string]$Proxy = '')
    if (-not $script:HasPwsh) { return $false }
    if ($Proxy -and $Proxy -match '^(socks4|socks4a|socks5|socks5h)://') { return $false }
    try {
        Write-Info "尝试 HTTP/2 下载 (pwsh)..."
        New-Directory $TempDir -Secure
        New-Directory (Split-Path $OutFile -Parent)
        $ps1 = Join-Path $TempDir 'http2_dl.ps1'
        # 使用安全的参数传递，避免命令注入
        $ps1Content = @'
param([string]$Url, [string]$OutFile, [string]$Proxy)
try {
    $h = [System.Net.Http.SocketsHttpHandler]::new()
    $h.EnableMultipleHttp2Connections = $true
    if ($Proxy) { $h.Proxy = [System.Net.WebProxy]::new($Proxy); $h.UseProxy = $true } else { $h.UseProxy = $false }
    $c = [System.Net.Http.HttpClient]::new($h)
    $c.DefaultRequestHeaders.UserAgent.ParseAdd('MAA-Update/2.2')
    $c.Timeout = [TimeSpan]::FromSeconds(600)
    $r = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    $r.Version = [System.Net.HttpVersion]::Version20
    $resp = $c.SendAsync($r, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { exit 1 }
    $s = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $f = [System.IO.File]::Create($OutFile)
    $s.CopyToAsync($f).GetAwaiter().GetResult()
    $f.Close()
    exit 0
} catch { exit 2 }
'@
        $ps1Content | Set-Content $ps1 -Encoding UTF8
        & $script:PwshPath -NoProfile -File $ps1 -Url $Url -OutFile $OutFile -Proxy $Proxy
        $http2ExitCode = $LASTEXITCODE
        Remove-Item -Force $ps1 -ErrorAction SilentlyContinue
        if ($http2ExitCode -eq 0 -and (Test-Path $OutFile)) {
            $actualSize = (Get-Item $OutFile).Length
            if ($ExpectedSize -le 0 -or $actualSize -eq $ExpectedSize) {
                Write-Ok "$DisplayName 下载完成 (HTTP/2, $(Format-FileSize $actualSize))"
                return $true
            }
            Write-Warn "HTTP/2 大小不匹配"; Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        } else { Write-Warn "HTTP/2 退出($LASTEXITCODE)" }
    } catch { Write-Warn "HTTP/2 下载失败" }
    return $false
}

# ======== 下载（curl → HttpWebRequest → pwsh HTTP/2 → 分片） ========
function Start-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0, [switch]$NoProxy)

    $proxyArg = ''
    if (-not $NoProxy -and $script:ProxyConfig) { $proxyArg = $script:ProxyConfig.ForCurl }
    # 直连线路可以带 --resolve（DNS 加速）；代理线路必须让代理解析域名
    $resolveArgs = @()
    if ($NoProxy -and $script:CurlResolve) { $resolveArgs = $script:CurlResolve }

    # 0. curl.exe（TCP 栈优于 .NET，优先）
    if ($script:HasCurl) {
        $curlArgs = @('-SfL', '-o', $OutFile, '--progress-bar', '--connect-timeout', '10', '--max-time', '900',
            '--retry', '2', '--retry-delay', '2', '--ssl-no-revoke', '-A', 'MAA-Update/2.2')
        if ($proxyArg) { $curlArgs += '--proxy', $proxyArg } else { $curlArgs += '--noproxy', '*' }
        $curlArgs += $resolveArgs
        $curlArgs += $Url
        for ($try = 1; $try -le $MaxRetries; $try++) {
            if ($try -gt 1) { Write-Warn "curl 重试第 $try 次..."; Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 2500) }
            try {
                Write-Info "尝试 curl 下载..."
                New-Directory (Split-Path $OutFile -Parent)
                & curl.exe @curlArgs
                if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile)) {
                    $actualSize = (Get-Item $OutFile).Length
                    if ($ExpectedSize -le 0 -or $actualSize -eq $ExpectedSize) {
                        Write-Ok "$DisplayName 下载完成 (curl, $(Format-FileSize $actualSize))"
                        return $true
                    }
                    Write-Warn "curl 大小不匹配"; Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
                }
                elseif ($LASTEXITCODE -ne 0) {
                    Write-Warn "curl 退出($LASTEXITCODE)，等待重试..."
                }
            }
            catch { Write-Warn "curl 下载失败"; Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
        }
    }

    # 1. 单线程 HttpWebRequest（带 Write-Progress 进度条）
    for ($try = 1; $try -le $MaxRetries; $try++) {
        if ($try -gt 1) { Write-Warn "下载重试第 $try 次...正在下载不要关闭程序"; Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 2500) }
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'; $req.Timeout = 15000; $req.ReadWriteTimeout = 60000
            $req.UserAgent = 'MAA-Update/2.2'
            if ($NoProxy) { $req.Proxy = $null } elseif ($proxyArg) { $req.Proxy = New-WebProxyOrNull $proxyArg }
            $resp = $req.GetResponse()
            $totalLen = $resp.ContentLength
            $stream = $resp.GetResponseStream()
            New-Directory (Split-Path $OutFile -Parent)
            $fs = [System.IO.File]::Create($OutFile)
            $buffer = New-Object byte[] 65536
            $totalRead = 0
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fs.Write($buffer, 0, $read); $totalRead += $read
                if ($totalLen -gt 0) {
                    $pct = [Math]::Min(99, [int](($totalRead / $totalLen) * 100))
                    Write-Progress -Activity "下载 $DisplayName" -Status "$pct% ($(Format-FileSize $totalRead)/$(Format-FileSize $totalLen))" -PercentComplete $pct
                }
            }
            $fs.Close(); $stream.Close(); $resp.Close()
            Write-Progress -Activity "下载 $DisplayName" -Completed
            $actualSize = (Get-Item $OutFile).Length
            if ($ExpectedSize -gt 0 -and $actualSize -ne $ExpectedSize) {
                Write-Warn "文件大小不匹配: 期望 $(Format-FileSize $ExpectedSize), 实际 $(Format-FileSize $actualSize)"
                Remove-Item -Force $OutFile -ErrorAction SilentlyContinue; continue
            }
            Write-Ok "$DisplayName 下载完成 ($(Format-FileSize $actualSize))"
            return $true
        }
        catch {
            Write-Warn "下载失败"
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        }
    }
    Write-Progress -Activity "下载 $DisplayName" -Completed

    # 2. pwsh HTTP/2 下载（SocketsHttpHandler，受限网络兜底）
    if (Start-Http2Download -Url $Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize -Proxy $proxyArg) {
        return $true
    }

    # 3. 分片下载（>10MB 大文件加速，最后兜底）
    if (Start-SegmentedDownload -Url $Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize) {
        return $true
    }

    Write-Err "$DisplayName 下载失败（curl/HttpWebRequest/HTTP/2/分片 均不可用）"
    return $false
}

# 按候选线路依次尝试下载；成功返回 $true
function Invoke-CandidateDownload {
    param([string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0, [string]$Sha256 = '', [array]$Probes,
        [string]$DirectUrl = '', [string]$ProxiedUrl = '', [array]$MirrorUrls = @(),
        [int]$MaxAttempts = 4)

    $attempt = 0
    $tested = @()

    # 已探测成功的线路按探测速度优先
    foreach ($p in $Probes) {
        if ($attempt -ge $MaxAttempts) { break }
        $attempt++
        $tested += $p.Url
        $noProxy = [bool](Get-ObjectProperty $p 'NoProxy' $false)
        $label = if ($noProxy) { '直连/镜像' } else { '代理' }
        if ($attempt -gt 1) { Write-Info "切换下载源 ($label): $($p.Url)" }
        if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
        $ok = if ($noProxy) {
            Start-Download -Url $p.Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize -NoProxy
        } else {
            Start-Download -Url $p.Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize
        }
        if ($ok) {
            if (-not $Sha256) { return $true }
            $hash = (Get-FileHash $OutFile -Algorithm SHA256).Hash
            if ($hash -eq $Sha256) { Write-Ok 'SHA256 校验通过'; return $true }
            Write-Err 'SHA256 校验失败，文件可能损坏，换源重试'
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
            continue
        }
        Write-Warn "下载源不可用: $($p.Url)"
    }

    # 未探测成功的线路再兜底试一遍
    $fallback = New-Object System.Collections.Generic.List[object]
    if ($DirectUrl -and ($tested -notcontains $DirectUrl)) { $fallback.Add([pscustomobject]@{ Url = $DirectUrl; NoProxy = $true }) }
    if ($script:SysProxy -and $ProxiedUrl -and ($tested -notcontains $ProxiedUrl)) { $fallback.Add([pscustomobject]@{ Url = $ProxiedUrl; NoProxy = $false }) }
    foreach ($mu in $MirrorUrls) { if ($tested -notcontains $mu) { $fallback.Add([pscustomobject]@{ Url = $mu; NoProxy = $true }) } }

    foreach ($f in $fallback) {
        if ($attempt -ge ($MaxAttempts + 3)) { break }
        $attempt++
        Write-Info "兜底尝试: $($f.Url)"
        if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
        $ok = if ([bool](Get-ObjectProperty $f 'NoProxy' $false)) {
            Start-Download -Url $f.Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize -NoProxy
        } else {
            Start-Download -Url $f.Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize
        }
        if ($ok) {
            if (-not $Sha256) { return $true }
            $hash = (Get-FileHash $OutFile -Algorithm SHA256).Hash
            if ($hash -eq $Sha256) { Write-Ok 'SHA256 校验通过'; return $true }
            Write-Err 'SHA256 校验失败，文件可能损坏，换源重试'
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        }
    }
    return $false
}

# ======== 版本检测（多来源取最新） ========
function Get-CurrentVersion {
    $candidates = New-Object System.Collections.Generic.List[object]

    # 1: MAA.exe
    $exePath = Join-Path $ScriptDir 'MAA.exe'
    if (Test-Path $exePath) {
        try {
            $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
            foreach ($prop in @($ver.ProductVersion, $ver.FileVersion)) {
                if ($prop -and ($prop -notmatch '^0+(\.0+)*$') -and (ConvertTo-VersionParts $prop)) {
                    $candidates.Add(@{ Version = "v$(($prop -split '\+')[0].TrimStart('vV'))"; Source = 'MAA.exe' })
                    break
                }
            }
        }
        catch {}
    }
    # 2: MaaCore.dll
    $dllPath = Join-Path $ScriptDir 'MaaCore.dll'
    if (Test-Path $dllPath) {
        try {
            $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dllPath)
            foreach ($prop in @($ver.ProductVersion, $ver.FileVersion)) {
                if ($prop -and ($prop -notmatch '^0+(\.0+)*$') -and (ConvertTo-VersionParts $prop)) {
                    $candidates.Add(@{ Version = "v$(($prop -split '\+')[0].TrimStart('vV'))"; Source = 'MaaCore.dll' })
                    break
                }
            }
        }
        catch {}
    }
    # 3: config/gui.json —— MAA 更新器在更新完成后会写入实际运行版本
    #    （例如 6.19.2-beta.2），比 exe 文件版本更贴近真实运行版本。
    $cfgPath = Join-Path $ScriptDir 'config/gui.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $names = @()
            foreach ($holder in @($cfg.VersionUpdate, ($cfg.Global.VersionUpdate), ($cfg.Default.VersionUpdate))) {
                if ($holder -and $holder.name) { $names += [string]$holder.name }
            }
            foreach ($n in $names) {
                if (-not $n) { continue }
                if ($n -notmatch '\d') { continue }
                if (-not (ConvertTo-VersionParts $n)) { continue }
                $candidates.Add(@{ Version = "v$($n.TrimStart('vV'))"; Source = 'gui.json' })
                break
            }
        }
        catch {}
    }

    if ($candidates.Count -eq 0) {
        Write-Warn '无法检测当前版本，使用 v0.0.0'
        return 'v0.0.0'
    }
    # 取语义化版本最高者：避免 gui.json 中的历史版本号把真实版本"拉低"（导致重复更新）
    # 或把真实版本"抬高"（导致漏更新）
    $best = $null
    foreach ($c in $candidates) {
        if (-not $best) { $best = $c; continue }
        if ((Compare-SemVer $c.Version $best.Version) -gt 0) { $best = $c }
    }
    foreach ($c in $candidates) {
        $mark = if ($c.Source -eq $best.Source) { '← 采用' } else { '' }
        Write-Info "版本来源 $($c.Source): $($c.Version) $mark"
    }
    return $best.Version
}

# ======== API 缓存 ========
function Read-ApiCache {
    param([string]$ApiPath)
    $cache = Join-Path $CacheDir "$ApiPath.cache"
    if (Test-Path $cache) {
        try { return (Get-Content $cache -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return $null
}

function Write-ApiCache {
    param([string]$ApiPath, $Data)
    $cache = Join-Path $CacheDir "$ApiPath.cache"
    New-Directory (Split-Path $cache -Parent)
    $Data | ConvertTo-Json -Depth 10 -Compress | Set-Content $cache -Encoding UTF8
}

# 实时请求优先；仅当实时请求失败时才回退缓存（避免把残缺响应写进缓存后长期使用）
function Request-WithCache {
    param([string]$Url, [string]$CacheKey, [int]$TimeoutSec = 15)
    $data = Invoke-GetJson $Url -TimeoutSec $TimeoutSec
    if ($data) { Write-ApiCache -ApiPath $CacheKey -Data $data; return $data }
    $cached = Read-ApiCache -ApiPath $CacheKey
    if ($cached) { Write-Warn "API 不可达，使用本地缓存 ($CacheKey)"; return $cached }
    return $null
}

# ======== 资源版本缓存（4h 过期） ========
$ResCacheFile = Join-Path $CacheDir 'resource_version.json'
function Read-ResVersionCache {
    if (-not (Test-Path $ResCacheFile)) { return $null }
    try {
        $cache = Get-Content $ResCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $cache.last_updated) { return $null }
        $age = [DateTime]::Now - [DateTime]::ParseExact([string]$cache.cached_at, 'yyyy-MM-dd HH:mm:ss', $null)
        # 过期或时间戳无法解析 → 视为无缓存，强制联网刷新
        if ($age.TotalHours -le 4 -and $age.TotalHours -ge -1) { return $cache }
    }
    catch {}
    return $null
}
function Write-ResVersionCache {
    param([string]$LastUpdated)
    $cache = @{ last_updated = $LastUpdated; cached_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    New-Directory $CacheDir
    $cache | ConvertTo-Json -Compress | Set-Content $ResCacheFile -Encoding UTF8
}

# 解析资源时间戳（容错 .fff 缺失 / 空格与 T 分隔两种写法）
function ConvertTo-ResourceTime {
    param([string]$Value)
    $formats = @('yyyy-MM-dd HH:mm:ss.fff', 'yyyy-MM-dd HH:mm:ss', "yyyy-MM-dd'T'HH:mm:ss.fff", "yyyy-MM-dd'T'HH:mm:ss")
    foreach ($f in $formats) {
        try { return [DateTime]::ParseExact([string]$Value, $f, $null) } catch {}
    }
    try { return [DateTime]::Parse([string]$Value) } catch {}
    return $null
}

function Get-LocalResourceTime {
    $localVerPath = Join-Path $ScriptDir 'resource/version.json'
    if (-not (Test-Path $localVerPath)) { return $null }
    try {
        $localJson = Get-Content $localVerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return ConvertTo-ResourceTime $localJson.last_updated
    }
    catch { return $null }
}

# 获取远程资源版本：jsDelivr CDN → raw.githubusercontent 镜像 → GitHub 直连/代理
function Get-RemoteResourceTime {
    $remoteJson = Read-ResVersionCache
    if ($remoteJson) { Write-Info '使用缓存的资源版本'; return (ConvertTo-ResourceTime $remoteJson.last_updated) }

    $urls = @($ResVersionCdnUrl)
    # 注意（原版 bug）：镜像站尾部带 '/'，直接拼接会变成
    # 'https://gh-proxy.comhttps://raw...'，必须先补上分隔斜杠
    $urls += @($MirrorHosts | ForEach-Object { "$($_.TrimEnd('/'))/$ResourceVersionUrl" })
    if ($script:SysProxy) { $urls += $ResourceVersionUrl }
    $remoteJson = Get-FirstJson -Urls $urls -Validate { param($j) $null -ne $j.last_updated } -TimeoutSec 10
    if ($remoteJson -and $remoteJson.last_updated) {
        Write-ResVersionCache ([string]$remoteJson.last_updated)
        return (ConvertTo-ResourceTime $remoteJson.last_updated)
    }
    return $null
}

# ======== 跨通道最新版解析 ========
# beta 语义：取「beta 公测版」与「stable 正式版」中语义化版本更高者。
# 这样当 6.19.2 已正式发布、而 beta 通道仍停留在 6.19.2-beta.2 时，
# 使用 beta 脚本的用户依然能更新到 6.19.2（而不是被判定为"已是最新"）。
function Resolve-MaaRelease {
    param([string]$RequestedChannel)

    if ($RequestedChannel -in @('beta', 'alpha')) {
        $order = @($RequestedChannel)
        if ($order -notcontains 'stable') { $order += 'stable' }
        if ($RequestedChannel -eq 'alpha' -and $order -notcontains 'beta') { $order += 'beta' }
        Write-Info "通道 $RequestedChannel：同时比较 $(($order -join ' / ')) 中的最新版"
    }
    else { $order = @('stable') }

    $summary = $null
    $summarySource = ''
    foreach ($base in @($MaaApiBase, $MaaApiBase2)) {
        $url = "$base/$SummaryApi"
        Write-Info "请求版本摘要: $url"
        $summary = Request-WithCache -Url $url -CacheKey "version/summary.json"
        if ($summary -and ($summary.PSObject.Properties.Name -contains 'stable')) { $summarySource = $base; break }
    }
    if (-not $summary -or -not ($summary.PSObject.Properties.Name -contains 'stable')) {
        Write-Err '无法获取版本信息（API 和缓存均不可用）'
        return $null
    }

    # 拉取候选通道详情
    $cache = @{}
    foreach ($ch in $order) {
        if (-not $summary.$ch) { continue }
        $ver = [string]$summary.$ch.version
        $detail = $summary.$ch.detail
        if (-not $detail) { $detail = "$summarySource/version/$ch.json" }
        $json = Request-WithCache -Url $detail -CacheKey "version/$ch.json"
        if (-not $json) {
            $alt = "$MaaApiBase2/version/$ch.json"
            $json = Request-WithCache -Url $alt -CacheKey "version/$ch.json"
        }
        if (-not $json) { Write-Warn "无法获取 $ch 通道详情，跳过"; continue }
        if ($ver -and (Compare-SemVer ([string]$json.version) $ver) -gt 0) { $ver = [string]$json.version }
        $cache[$ch] = @{ Version = $ver; Detail = $detail; Json = $json }
    }
    if ($cache.Count -eq 0) { Write-Err '无法获取版本详情'; return $null }

    # 选择最新版本
    $names = @(Sort-VersionDescending @($cache.Keys | ForEach-Object { $cache[$_].Version }))
    # Sort-VersionDescending 返回的是版本号，映射回通道名
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($v in $names) { foreach ($k in $cache.Keys) { if ($cache[$k].Version -eq $v -and $ordered -notcontains $k) { $ordered.Add($k) } } }
    $names = @($ordered)
    $best = $cache[$names[0]]
    if ($cache.ContainsKey($RequestedChannel) -and $names[0] -ne $RequestedChannel) {
        $reqVer = $cache[$RequestedChannel].Version
        if ((Compare-SemVer $best.Version $reqVer) -gt 0) {
            Write-Ok "最新版本: $($best.Version)（$($names[0]) 通道）比 $RequestedChannel 通道的 $reqVer 更新，按时间取最新 → $($best.Version)"
        }
        else {
            # 两通道版本号相同时优先正式版（stable）
            Write-Ok "最新版本: $($best.Version)（$RequestedChannel 与 $($names[0]) 通道均为该版本，优先正式版）"
        }
    }
    else { Write-Ok "最新 $RequestedChannel 版本: $($best.Version)" }

    return @{
        Version   = [string]$best.Version
        Channel   = $names[0]
        Detail    = $best.Detail
        Json      = $best.Json
        Requested = $RequestedChannel
        All       = $cache
    }
}

# ======== 更新包选择 ========
function Select-MaaAsset {
    param($Release, [string]$CurrentVersion, [string]$Arch)

    $full = New-Object System.Collections.Generic.List[object]
    $otas = New-Object System.Collections.Generic.List[object]
    foreach ($a in $Release.Json.details.assets) {
        $info = Parse-GithubAssetName ([string]$a.name)
        if (-not $info.Arch -or $info.Arch -ne $Arch) { continue }
        if ($info.IsOta) {
            $fromOk = ConvertTo-VersionParts $info.FromVersion
            if (-not $fromOk) { continue }
            $otas.Add(@{ Asset = $a; Info = $info })
        }
        else { $full.Add(@{ Asset = $a; Info = $info }) }
    }

    # 完整包：选语义化版本最高的 x64/arm64 包（兼容预发布命名 MAA-v6.19.0-beta.2-win-x64.zip）
    $bestFull = $null
    foreach ($f in $full) {
        if (-not $bestFull) { $bestFull = $f; continue }
        if ((Compare-SemVer $f.Info.Version $bestFull.Info.Version) -gt 0) { $bestFull = $f }
    }

    # OTA 选择策略（按优先级）：
    #   1) 源版本恰好等于当前版本（含 gui.json 记录的夜间版全名）
    #   2) 源版本 = 当前版本的基础版本号（例：当前 6.19.2-beta.2.d010.ga7ee2c2bf7 时用 beta.2 的 OTA）
    #   3) 没有任何精确匹配时，从「源版本 <= 当前版本」里挑。同一基础版本下的夜间版更贴近
    #      当前文件状态，因此只要它不比兜底候选更旧就优先使用。
    # 注意：这里刻意避免 `if (...) { $x = ...; continue }` 的写法 —— 在「赋值即语句」的
    # 分支里 PowerShell 会终止整个管道，导致循环提前结束（曾导致 OTA 选错源版本）。
    $cur = ConvertTo-VersionParts $CurrentVersion
    $curBase = Get-VersionBase $CurrentVersion
    $curVerNoV = $CurrentVersion.TrimStart('vV')
    $otaExact = $null
    $otaBase = $null
    $applicable = New-Object System.Collections.Generic.List[object]
    foreach ($o in $otas) {
        if ($o.Info.ToVersion -ne $Release.Version) { continue }
        $fromNoV = $o.Info.FromVersion.TrimStart('vV')
        if ($fromNoV -eq $curVerNoV) { $otaExact = $o }
        elseif ($curBase -and $fromNoV -eq $curBase) { $otaBase = $o }
        elseif ($cur -and (Compare-SemVer $o.Info.FromVersion $CurrentVersion) -le 0) { $applicable.Add($o) }
    }
    $otaBest = $otaExact
    if (-not $otaBest) { $otaBest = $otaBase }
    if (-not $otaBest -and $applicable.Count -gt 0) {
        $sameBaseBest = $null
        foreach ($o in $applicable) {
            if ($curBase -and (Get-VersionBase $o.Info.FromVersion) -eq $curBase) {
                if (-not $sameBaseBest) { $sameBaseBest = $o }
                elseif ((Compare-SemVer $o.Info.FromVersion $sameBaseBest.Info.FromVersion) -gt 0) { $sameBaseBest = $o }
            }
            if (-not $otaBest) { $otaBest = $o }
            elseif ((Compare-SemVer $o.Info.FromVersion $otaBest.Info.FromVersion) -gt 0) { $otaBest = $o }
        }
        if ($sameBaseBest -and (Compare-SemVer $sameBaseBest.Info.FromVersion $otaBest.Info.FromVersion) -ge 0) { $otaBest = $sameBaseBest }
    }

    $latestFull = if ($bestFull) { $bestFull } else { $null }
    $label = if ($otaBest) { "OTA 增量包 $($otaBest.Info.FromVersion) → $($otaBest.Info.ToVersion)" }
    elseif ($latestFull) { "完整包 $($latestFull.Info.Version)" }
    else { '无' }
    Write-Info "更新包选择: $label (当前 $CurrentVersion, 共 $($otas.Count) 个 OTA / $($full.Count) 个完整包)"

    $selected = if ($otaBest) { $otaBest.Asset } elseif ($latestFull) { $latestFull.Asset } else { $null }
    $type = if ($otaBest) { 'OTA' } elseif ($latestFull) { '完整包' } else { '' }
    return @{
        Version     = $Release.Version
        Channel     = $Release.Channel
        Type        = $type
        Asset       = $selected
        OtaAsset    = if ($otaBest) { $otaBest.Asset } else { $null }
        OtaFrom     = if ($otaBest) { $otaBest.Info.FromVersion } else { '' }
        OtaTarget   = if ($otaBest) { $otaBest.Info.ToVersion } else { '' }
        FullAsset   = if ($latestFull) { $latestFull.Asset } else { $null }
        DetailJson  = $Release.Json
        Arch        = $Arch
    }
}

# ======== 检查版本更新 ========
function Check-VersionUpdate {
    Write-Step '检查 MAA 版本更新'

    $configPath = Join-Path $ScriptDir 'config/gui.json'
    if ((Test-Path $configPath) -and ($Channel -eq 'stable')) {
        try {
            $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $savedChannel = $cfg.'VersionUpdate.VersionType'
            if (-not $savedChannel -and $cfg.VersionUpdate) { $savedChannel = $cfg.VersionUpdate.VersionType }
            if ($savedChannel) {
                $channelMap = @{ '0' = 'stable'; '1' = 'beta'; '2' = 'alpha' }
                $detected = $channelMap["$savedChannel"]
                if ($detected) { $Channel = $detected; Write-Info "从配置读取更新通道: $Channel" }
            }
        }
        catch {}
    }
    Write-Info "更新通道: $Channel"

    $release = Resolve-MaaRelease -RequestedChannel $Channel
    if (-not $release) { return $null }

    $latestVer = [string]$release.Version
    $cmp = Compare-SemVer $latestVer $script:CurrentVersion
    if ($cmp -le 0 -and -not $Force) {
        if ($cmp -eq 0) { Write-Ok "已是最新 ($($script:CurrentVersion))" }
        else { Write-Ok "已是最新（当前 $($script:CurrentVersion) 高于可用版本 $latestVer）" }
        return $null
    }
    if ($Force -and $cmp -eq 0) { Write-Warn "强制更新模式：重新安装 $latestVer" }

    $isArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM')
    $arch = if ($isArm) { 'arm64' } else { 'x64' }

    $info = Select-MaaAsset -Release $release -CurrentVersion $script:CurrentVersion -Arch $arch
    if (-not $info.Asset) { Write-Err "未找到适用于 win-$arch 的更新包"; return $null }

    Write-Info "新版本: $latestVer ($($info.Type))"
    return $info
}

# ======== 下载更新（线路探测 + 多源冗余） ========
function Download-UpdatePackage {
    param($UpdateInfo)
    $asset = $UpdateInfo.Asset
    $filename = $asset.name
    $filepath = Join-Path $ScriptDir $filename
    $expectedSize = [long]$asset.size
    $originalUrl = $asset.browser_download_url

    Write-Info "原始: $originalUrl"
    Write-Info '正在探测下载线路（直连 / 代理 / 镜像）...'
    $cand = Get-DownloadCandidates -Url $originalUrl
    $probes = Test-UrlCandidates -Candidates $cand
    if ($probes.Count -eq 0) {
        if ($script:SysProxy) { Write-Warn '所有线路探测失败。如代理对 GitHub 设置了直连/绕过规则，请关闭该规则后重试。' }
        else { Write-Warn '所有线路探测失败，且未检测到代理。请检查网络或开启代理后重试。' }
    }
    else { Write-Info "最快线路: $($probes[0].Url) [$($probes[0].Route), $($probes[0].Kbs) KB/s]" }

    if ($DryRun) { Write-Warn '仅检查模式，跳过下载'; return $null }
    if (Test-Path $filepath) { Remove-Item -Force $filepath }
    Set-State -Phase 'downloading' -Version $UpdateInfo.Version -Detail $filename

    if (Invoke-CandidateDownload -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize `
            -Sha256 ([string]$asset.sha256) -Probes $probes -DirectUrl $cand.Direct -ProxiedUrl $cand.Proxied -MirrorUrls $cand.Mirrors) {
        return $filepath
    }
    Write-Err "下载失败（所有镜像和原始地址均不可用）"
    return $null
}

# ======== 安装更新（带备份/回滚） ========
function Install-Update {
    param([string]$PackagePath, $UpdateInfo)
    Write-Step '安装更新'
    if (-not (Test-Path $PackagePath)) { Write-Err "更新包不存在"; return $false }

    Set-State -Phase 'extracting' -Version $UpdateInfo.Version
    $extractDir = Join-Path $TempDir 'extract'
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    New-Directory $extractDir -Secure
    try {
        Show-Wait '正在解压更新包...'
        Expand-Zip -ZipPath $PackagePath -DestDir $extractDir
    }
    catch { Write-Err "解压失败: $_"; return $false }

    # 检测根目录
    $entries = Get-ChildItem $extractDir
    $sourceDir = $extractDir
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
        $sourceDir = $entries[0].FullName
        Write-Info "检测到根目录: $($entries[0].Name)"
    }

    $removeListPath = Join-Path $sourceDir 'removelist.txt'
    $changesJsonPath = Join-Path $sourceDir 'changes.json'
    $isOta = (Test-Path $removeListPath) -or (Test-Path $changesJsonPath)

    # ===== 准备备份目录 =====
    if (Test-Path $BackupDir) { Remove-Item -Recurse -Force $BackupDir }
    New-Directory $BackupDir

    # ===== 收集变更列表 =====
    $removeFiles = New-Object System.Collections.Generic.List[string]
    $affectedFiles = New-Object System.Collections.Generic.List[string]

    if ($isOta) {
        Write-Info 'OTA 增量更新包'
        # 删除列表
        if (Test-Path $removeListPath) {
            foreach ($f in (Get-Content $removeListPath -Encoding UTF8)) {
                $f = $f.Trim()
                if (-not $f -or $f.EndsWith('\') -or $f.EndsWith('/')) { continue }
                $removeFiles.Add($f)
                $affectedFiles.Add($f)
            }
        }
        if (Test-Path $changesJsonPath) {
            try {
                $changes = Get-Content $changesJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($changes.deleted) {
                    foreach ($f in $changes.deleted) {
                        $f = $f.Trim()
                        if (-not $f -or $f.EndsWith('\') -or $f.EndsWith('/')) { continue }
                        $removeFiles.Add($f); $affectedFiles.Add($f)
                    }
                }
            }
            catch { Write-Warn 'changes.json 解析失败，跳过' }
        }
        # 新增文件列表
        $controlFiles = @('removelist.txt', 'changes.json')
        $payloadFiles = Get-ChildItem $sourceDir -File -Recurse | Where-Object {
            $rel = $_.FullName.Substring($sourceDir.Length + 1)
            $rel -notin $controlFiles
        }
        foreach ($file in $payloadFiles) {
            $rel = $file.FullName.Substring($sourceDir.Length + 1)
            $affectedFiles.Add($rel)
        }
    }

    # ===== 备份受影响文件 =====
    Set-State -Phase 'backingup' -Version $UpdateInfo.Version
    Write-Info "备份 $($affectedFiles.Count) 个受影响文件..."
    foreach ($rel in $affectedFiles) {
        $src = Join-Path $ScriptDir $rel
        $dest = Join-Path $BackupDir $rel
        if (Test-Path $src) {
            New-Directory (Split-Path $dest -Parent)
            try { Copy-Item $src $dest -Force } catch { Write-Warn "备份失败: $rel" }
        }
    }
    Write-Ok "备份完成 (备份目录: $BackupDir)"

    # ===== 执行 OTA =====
    if ($isOta) {
        Set-State -Phase 'removing' -Version $UpdateInfo.Version
        foreach ($f in $removeFiles) {
            $fp = Join-Path $ScriptDir $f
            try { if (Test-Path $fp) { Remove-Item -Force $fp } } catch { Write-Warn "跳过删除: $f" }
        }
        Set-State -Phase 'installing' -Version $UpdateInfo.Version
        foreach ($file in $payloadFiles) {
            $rel = $file.FullName.Substring($sourceDir.Length + 1)
            $dest = Join-Path $ScriptDir $rel
            New-Directory (Split-Path $dest -Parent)
            try { Copy-Item $file.FullName $dest -Force } catch { Write-Warn "跳过复制: $rel" }
        }
    }
    else {
        # ===== 完整包 =====
        Write-Info '完整更新包'
        Set-State -Phase 'full_install' -Version $UpdateInfo.Version
        # 备份保留目录（含 resource/cache，避免完整包里的旧资源覆盖本地已更新的资源）
        foreach ($d in $PreserveDirs) {
            $src = Join-Path $ScriptDir $d
            if (Test-Path $src) { Copy-Item -Recurse $src (Join-Path $BackupDir $d) -Force }
        }
        # 备份所有将被覆盖的文件（完整包更新无 OTA 差异清单，全量保护）
        $controlFiles = @('removelist.txt', 'changes.json')
        $overwriteFiles = Get-ChildItem $sourceDir -File -Recurse
        $overwriteFiles | ForEach-Object {
            $rel = $_.FullName.Substring($sourceDir.Length + 1)
            $topDir = ($rel -split '[\\/]')[0]
            if ($topDir -in $PreserveDirs -or $rel -in $controlFiles) { return }
            $src = Join-Path $ScriptDir $rel
            if (Test-Path $src) {
                $backupDest = Join-Path $BackupDir $rel
                New-Directory (Split-Path $backupDest -Parent)
                Copy-Item $src $backupDest -Force
            }
        }
        # 复制新文件（跳过保留目录中的控制文件）
        $overwriteFiles | ForEach-Object {
            $rel = $_.FullName.Substring($sourceDir.Length + 1)
            $topDir = ($rel -split '[\\/]')[0]
            if ($topDir -in $PreserveDirs -or $rel -in $controlFiles) { return }
            $dest = Join-Path $ScriptDir $rel
            New-Directory (Split-Path $dest -Parent)
            Copy-Item $_.FullName $dest -Force
        }
        # 恢复保留目录（不覆盖已有文件）
        foreach ($d in $PreserveDirs) {
            $src = Join-Path $BackupDir $d
            $dst = Join-Path $ScriptDir $d
            if (-not (Test-Path $src)) { continue }
            New-Directory $dst
            Get-ChildItem $src -Recurse | ForEach-Object {
                $rel = $_.FullName.Substring($src.Length + 1)
                $target = Join-Path $dst $rel
                if ($_.PSIsContainer) { New-Directory $target } else { if (-not (Test-Path $target)) { Copy-Item $_.FullName $target } }
            }
        }
    }

    Write-Ok "更新完成: $($UpdateInfo.Version)"
    Clear-State
    return $true
}

# ======== 回滚 ========
function Restore-Backup {
    Write-Step '回滚更新'
    if (-not (Test-Path $BackupDir)) { Write-Warn '无备份可回滚'; return }
    $files = Get-ChildItem $BackupDir -File -Recurse
    $count = 0
    foreach ($file in $files) {
        $rel = $file.FullName.Substring($BackupDir.Length + 1)
        $dest = Join-Path $ScriptDir $rel
        New-Directory (Split-Path $dest -Parent)
        try { Copy-Item $file.FullName $dest -Force; $count++ } catch { Write-Warn "回滚失败: $rel" }
    }
    Write-Ok "已回滚 $count 个文件"
}

# ======== 资源更新 ========
function Update-Resource {
    Write-Step '检查游戏资源更新'

    $localTime = Get-LocalResourceTime
    if (-not $localTime) { $localTime = Get-Date 0 }
    Write-Info "本地资源时间: $($localTime.ToString('yyyy-MM-dd HH:mm:ss'))"

    $remoteTime = Get-RemoteResourceTime
    if (-not $remoteTime) {
        Write-Warn '无法获取远程资源版本，跳过资源更新'
        return $false
    }
    Write-Info "远程资源时间: $($remoteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    if ($remoteTime -le $localTime -and -not $Force) { Write-Ok '资源已是最新'; return $true }

    Write-Info "发现新资源 ($($remoteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
    if ($DryRun) { Write-Warn '仅检查模式，跳过资源下载'; return $null }

    # 资源包下载：探测线路后按最快顺序下载（约 12MB，无需分片）
    $resZip = Join-Path $TempDir 'MaaResource.zip'
    if (-not $script:HasPwsh) { Write-Info 'pwsh 不可用，HTTP/2 下载将被跳过' }
    Write-Info '正在探测下载线路（直连 / 代理 / 镜像）...'
    $cand = Get-DownloadCandidates -Url $ResourceArchiveUrl
    $probes = Test-UrlCandidates -Candidates $cand
    $dlOk = Invoke-CandidateDownload -OutFile $resZip -DisplayName '游戏资源包' -Probes $probes `
        -DirectUrl $cand.Direct -ProxiedUrl $cand.Proxied -MirrorUrls $cand.Mirrors
    if (-not $dlOk) { Write-Err '资源下载失败'; return $false }

    # 解压
    $resExtract = Join-Path $TempDir 'MaaResource'
    if (Test-Path $resExtract) { Remove-Item -Recurse -Force $resExtract }
    try {
        Show-Wait '正在解压资源包...'
        Expand-Zip -ZipPath $resZip -DestDir $resExtract
    }
    catch { Write-Err "解压失败: $_"; return $false }

    $resSource = Join-Path $resExtract 'MaaResource-main/resource'
    if (-not (Test-Path $resSource)) { $resSource = Join-Path $resExtract 'resource' }
    if (-not (Test-Path $resSource)) { Write-Err '未找到 resource 目录'; return $false }

    Write-Info '合并资源文件...'
    $target = Join-Path $ScriptDir 'resource'
    New-Directory $target
    Get-ChildItem $resSource -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($resSource.Length + 1)
        $dest = Join-Path $target $rel
        if ($_.PSIsContainer) { New-Directory $dest } else { New-Directory (Split-Path $dest -Parent); Copy-Item $_.FullName $dest -Force }
    }
    Write-Ok "资源更新完成 ($($remoteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
    return $true
}

# ======== 全量下载回退（增量失败时调用） ========
function Invoke-FullDownload {
    $fullDlScript = Join-Path $ScriptDir 'Maa-FullUpdate-Download.ps1'
    if (-not (Test-Path $fullDlScript)) {
        Write-Warn "全量下载脚本不存在: $fullDlScript"
        return $false
    }
    Write-Warn '增量更新失败，尝试全量下载覆盖...'
    try {
        & $fullDlScript -Channel $Channel -Silent
        if ($LASTEXITCODE -eq 0) {
            Write-Ok '全量下载覆盖完成'
            return $true
        }
    }
    catch { Write-Warn "全量下载异常" }
    return $false
}

# ======== 清理 ========
function Cleanup-Temp {
    foreach ($d in @($TempDir, $BackupDir)) { if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue } }
    Write-Info '临时文件已清理'
}

# ======== 主流程 ========
if ($SelfTest) {
    $ok = Test-ScriptLogic
    if ($ok) { exit 0 } else { exit 1 }
}

try {
    # 保留历史日志并追加本次会话（日志是最重要的排障依据，不能每次运行都清掉）
    Write-Log 'INFO' "=== MAA 更新脚本 v3.5 启动 ==="
    Write-Log 'INFO' "目录: $ScriptDir | 通道: $Channel | PowerShell $($PSVersionTable.PSVersion)"
    if ($Force) { Write-Warn '强制更新模式' }
    if ($DryRun) { Write-Warn '仅检查模式（不下载）' }
    Write-Info "日志: $LogFile"

    # 读取上次中断的状态
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Warn "检测到上次未完成的更新 (阶段: $($state.Phase), 版本: $($state.Version))"
            # 尝试回滚
            if (Test-Path $BackupDir) { Restore-Backup }
        }
        catch {}
        Clear-State
    }

    # 清理残留
    Get-ChildItem $ScriptDir -Filter "*.temp" | Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path $TempDir) { Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue }

    # 系统代理检测
    Detect-SystemProxy

    # DNS 加速（解析 + 测速 + curl --resolve；有代理时自动跳过）
    Initialize-DnsAccel

    # 确保 pwsh 可用（HTTP/2 下载）
    Ensure-Pwsh | Out-Null

    $script:CurrentVersion = Get-CurrentVersion

    # 记录 MAA 是否在运行
    $maaWasRunning = $null -ne (Get-Process 'MAA' -ErrorAction SilentlyContinue)

    # === 版本更新检查 ===
    $updateInfo = $null
    if (-not $SkipVersion) { $updateInfo = Check-VersionUpdate }

    # === 资源更新检查（快速版，只查版本号，不下载） ===
    $needResourceUpdate = $false
    if (-not $SkipResource) {
        $localRt = Get-LocalResourceTime
        if (-not $localRt) { $localRt = Get-Date 0 }
        $remoteRt = Get-RemoteResourceTime
        if ($remoteRt) {
            if ($remoteRt -gt $localRt -or $Force) { $needResourceUpdate = $true }
            else { Write-Ok '资源已是最新' }
        }
        else { Write-Warn '无法获取远程资源版本，跳过资源更新' }
    }

    # === 判断是否需要更新 ===
    if (-not $updateInfo -and -not $needResourceUpdate) {
        if ($maaWasRunning) { Write-Info '已是最新，无需更新' }
        else { Write-Ok '已是最新' }
        Clear-State
        exit 0
    }

    # === 需要更新 → 先下载，再关 MAA，最后安装 ===
    $pkgPath = $null
    $updateApplied = $false

    # 1. 下载更新包（三级回退：OTA → 完整包 → 全量下载覆盖）
    if ($updateInfo) {
        # 第一优先级：OTA 增量包
        $pkgPath = Download-UpdatePackage $updateInfo

        # 第二优先级：OTA 失败时尝试完整包
        if (-not $pkgPath -and $updateInfo.FullAsset -and $updateInfo.Type -eq 'OTA') {
            Write-Warn 'OTA 下载失败，尝试完整包...'
            $fullInfo = @{
                Version    = $updateInfo.Version
                Channel    = $updateInfo.Channel
                Type       = '完整包'
                Asset      = $updateInfo.FullAsset
                DetailJson = $updateInfo.DetailJson
                Arch       = $updateInfo.Arch
            }
            $pkgPath = Download-UpdatePackage $fullInfo
            if ($pkgPath) { $updateInfo = $fullInfo }
        }

        # 第三优先级：完整包也失败 → 全量下载覆盖
        if (-not $pkgPath -and -not $DryRun) {
            if (Invoke-FullDownload) {
                $updateApplied = $true
                $updateInfo = $null
            }
        }
    }

    # 2. 关闭 MAA（安装前才关）
    $maaProc = Get-Process 'MAA' -ErrorAction SilentlyContinue
    if ($maaProc) {
        Write-Warn "正在关闭 MAA (PID: $($maaProc.Id))..."
        if (-not $DryRun) {
            $maaProc.CloseMainWindow() | Out-Null
            if (-not $maaProc.WaitForExit(5000)) { $maaProc.Kill(); Start-Sleep 2 }
        }
    }

    # 3. 安装版本更新
    if ($pkgPath -and $updateInfo) {
        $updateApplied = Install-Update -PackagePath $pkgPath -UpdateInfo $updateInfo
        if (Test-Path $pkgPath) { Remove-Item -Force $pkgPath -ErrorAction SilentlyContinue }
        if (-not $updateApplied -and (Test-Path $BackupDir)) { Restore-Backup }
        # 增量安装失败 → 全量下载回退
        if (-not $updateApplied -and -not $DryRun) {
            if (Invoke-FullDownload) { $updateApplied = $true }
        }
    }

    # 4. 资源更新
    if ($needResourceUpdate) { Update-Resource | Out-Null }

    Cleanup-Temp
    Clear-State
    Write-Log 'OK' "=== 更新完成 ==="

    # === 重启 MAA ===
    # 仅当「运行前 MAA 本来在跑」且「本次真的执行了更新」时才重启；
    # 仅检查模式（-DryRun）不应启动任何程序
    if ($maaWasRunning -and -not $DryRun -and (Test-Path (Join-Path $ScriptDir 'MAA.exe'))) {
        Write-Info '启动 MAA...'
        Start-Process (Join-Path $ScriptDir 'MAA.exe') -WorkingDirectory $ScriptDir
        Write-Ok 'MAA 已重新启动'
    }

}
catch {
    $errDetail = "$_"
    if ($_.ScriptStackTrace) { $errDetail = "$errDetail`n$($_.ScriptStackTrace)" }
    Write-Err "更新过程出错: $errDetail"
    Write-Log 'ERROR' "出错位置: $($_.InvocationInfo.PositionMessage)"
    if (Test-Path $BackupDir) { Restore-Backup }
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
    Clear-State
    exit 1
}
