<#:
.SYNOPSIS
    MAA 最新版一键下载覆盖 — 无代理 v3.4（语义化版本 + 智能路由）
.DESCRIPTION
    从 api.maa.plus 获取最新版本信息，通过镜像/直链下载到当前目录。
    如果当前目录是 MAA 安装目录，自动清理旧文件并解压覆盖。
    具备主备 API、语义化版本比较（beta 通道自动取 beta/stable 中较新者）、
    下载线路探测、镜像降级、下载重试、文件校验等冗余机制。
    支持 -Silent 静默模式，适用于 bat 批处理调用。
.PARAMETER Channel
    更新通道: stable / beta / alpha。beta 会同时比较 beta 与 stable，取语义化版本最新者。
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
$script:HasCurl = $null -ne (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)

$ApiBase1 = 'https://api.maa.plus/MaaAssistantArknights/api'
$ApiBase2 = 'https://api2.maa.plus/MaaAssistantArknights/api'
$MirrorHosts = @(
    'https://gh-proxy.com',
    'https://ghproxy.net',
    'https://gh.ddlc.top',
    'https://ghproxy.homeboyc.cn'
)
$SummaryApi = 'version/summary.json'
$RetryMax = 3

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogFile = Join-Path $ScriptDir "update_full.log"

# 日志记录函数
function Write-Log {
    param([string]$Level, [string]$Message)
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$time][$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
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
# SOCKS5 代理无法交给 .NET WebProxy 使用，此时 ForCurl 交给 curl，.NET 引擎走直连。
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
# 规则（遵循 SemVer）：
#   - 主/次/修订号各自零填充到 6 位，保证数值序等于字符串序
#   - 正式版用 '~'，预发布版用 '!' 打头（'~' 0x7E > '!' 0x21），故正式版 > 预发布版
#   - 预发布标识用 '|' 连接并以 '~' 收尾：标识更少者（alpha.1）大于同前缀夜间版（alpha.1.d014）
#   - 数字标识补零，保证 beta.10 > beta.9；数字标识 < 字母标识
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

# ======== 更新线路候选 ========
function Get-DownloadCandidates {
    param([string]$Url)
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
        $req.UserAgent = 'MAA-DL/1.0'
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

function Start-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0, [switch]$NoProxy)

    if (-not $Silent) { Write-Host '⚠ 正在下载，请不要关闭此窗口！根据网络状况可能需要几分钟。' -ForegroundColor Black -BackgroundColor Yellow }

    $proxyArg = ''
    if (-not $NoProxy -and $script:ProxyConfig) { $proxyArg = $script:ProxyConfig.ForCurl }

    # 1. curl（优先，TCP 栈优于 .NET）
    if ($script:HasCurl) {
        $curlArgs = @('-SfL', '-o', $OutFile, '--progress-bar', '-A', 'MAA-DL/1.0', '--connect-timeout', '15', '--max-time', '900',
            '--retry', '2', '--retry-delay', '2', '--ssl-no-revoke')
        if ($proxyArg) { $curlArgs += '--proxy', $proxyArg } else { $curlArgs += '--noproxy', '*' }
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
                Write-Warn "curl 失败"
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

# 按候选线路依次尝试下载；成功返回 $true
function Invoke-CandidateDownload {
    param([string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0, [string]$Sha256 = '',
        [array]$Probes, [string]$DirectUrl = '', [string]$ProxiedUrl = '', [array]$MirrorUrls = @(), [int]$MaxAttempts = 4)

    $attempt = 0
    $tested = @()
    foreach ($p in $Probes) {
        if ($attempt -ge $MaxAttempts) { break }
        $attempt++
        $tested += $p.Url
        if ($attempt -gt 1) { Write-Info "切换下载源 ($($p.Route)): $($p.Url)" }
        if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
        $ok = if ($p.NoProxy) {
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

    $fallback = New-Object System.Collections.Generic.List[object]
    if ($DirectUrl -and ($tested -notcontains $DirectUrl)) { $fallback.Add([pscustomobject]@{ Url = $DirectUrl; Route = '直连'; NoProxy = $true }) }
    if ($script:SysProxy -and $ProxiedUrl -and ($tested -notcontains $ProxiedUrl)) { $fallback.Add([pscustomobject]@{ Url = $ProxiedUrl; Route = '代理'; NoProxy = $false }) }
    foreach ($mu in $MirrorUrls) { if ($tested -notcontains $mu) { $fallback.Add([pscustomobject]@{ Url = $mu; Route = '镜像'; NoProxy = $true }) } }

    foreach ($f in $fallback) {
        if ($attempt -ge ($MaxAttempts + 3)) { break }
        $attempt++
        Write-Info "兜底尝试 ($($f.Route)): $($f.Url)"
        if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
        $ok = if ($f.NoProxy) {
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

# ======== 解析发布包文件名 ========
function Parse-GithubAssetName {
    param([string]$Name)
    $r = @{ Arch = ''; Version = ''; Name = ([string]$Name) }
    if (-not $Name) { return $r }
    $n = [string]$Name
    if ($n -match '^MAA-(v[\d\.]+(?:-[0-9A-Za-z\.]+)?)-win-(x64|arm64)\.zip$') {
        $r.Version = $matches[1]
        $r.Arch = $matches[2]
    }
    return $r
}

# 读取本地已安装版本（MAA.exe 的 ProductVersion/FileVersion，取较高者）
function Get-CurrentVersion {
    $exePath = Join-Path $ScriptDir 'MAA.exe'
    if (-not (Test-Path $exePath)) { return '' }
    $found = @()
    try {
        $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
        foreach ($prop in @($ver.ProductVersion, $ver.FileVersion)) {
            if ($prop -and ($prop -notmatch '^0+(\.0+)*$') -and (Get-VersionKey $prop)) {
                $found += "v$(($prop -split '\+')[0].TrimStart('vV'))"
            }
        }
    }
    catch {}
    if ($found.Count -eq 0) { return '' }
    $best = $found[0]
    foreach ($v in $found) { if ((Compare-SemVer $v $best) -gt 0) { $best = $v } }
    return $best
}

# ======== 全量包自动安装 ========
function Install-To-MaaDir {
    param([string]$ZipPath)

    if (-not (Test-Path (Join-Path $ScriptDir 'MAA.exe'))) {
        Write-Info '当前目录不是 MAA 安装目录，跳过自动安装'
        return $false
    }

    Write-Step '检测到 MAA 安装目录，执行自动安装'

    # 1. 备份白名单目录（config/data/debug）
    $bakDir = Join-Path $env:TEMP "maa_install_bak_$(Get-Random)"
    New-Directory $bakDir -Secure
    foreach ($dir in @('config', 'data', 'debug')) {
        $src = Join-Path $ScriptDir $dir
        if (Test-Path $src) { Copy-Item -Recurse $src (Join-Path $bakDir $dir) -Force }
    }

    # 2. 白名单（不删除 + 不解压覆盖）
    $whitelist = @(
        'Maa-FullUpdate-Download.ps1',
        'Maa-Increment-Update.ps1',
        'Maa-全量更新-静默.bat',
        'Maa-全量更新-Debug.bat',
        'Maa-增量-更新-Debug.bat',
        'Maa-增量-静默版本资源全部更新.bat',
        'Maa-增量-静默只更新版本.bat',
        'Maa-全量更新-静默(beta).bat',
        'Maa-全量更新-Debug(beta).bat',
        'Maa-增量-更新-Debug(beta).bat',
        'Maa-增量-静默版本资源全部更新(beta).bat',
        'Maa-增量-静默只更新版本(beta).bat',
        '使用前阅读此文件.txt',
        'adb',
        'data',
        'config',
        'debug',
        # 隐藏目录和文件保护
        '.update_temp',
        '.update_backup',
        '.update_state',
        '.pwsh',
        '.pwsh_auto_attempted',
        'update.log',
        'update_full.log',
        'cache'
    )
    $zipName = Split-Path $ZipPath -Leaf
    if ($zipName -and $whitelist -notcontains $zipName) { $whitelist += $zipName }

    # 安全检查：防止删除当前脚本自身
    $currentScript = $MyInvocation.MyCommand.Path
    if ($currentScript) { $whitelist += (Split-Path $currentScript -Leaf) }

    # 3. 清理非白名单文件和目录
    Write-Info '清理旧文件...'
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

    # 4. 解压
    Write-Info '解压更新包...'
    $extractDir = Join-Path $env:TEMP "maa_extract_$(Get-Random)"
    New-Directory $extractDir -Secure
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

# ======== 跨通道最新版解析 ========
# beta 语义：取「beta 公测版」与「stable 正式版」中语义化版本更高者。
# 这样当 6.19.2 已正式发布、而 beta 通道仍停留在 6.19.2-beta.2 时，
# 使用 beta 脚本的用户依然能更新到 6.19.2。
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
    foreach ($base in @($ApiBase1, $ApiBase2)) {
        $url = "$base/$SummaryApi"
        Write-Info "请求版本摘要: $url"
        try {
            $summary = Invoke-RestMethod $url -TimeoutSec 10
        }
        catch {
            Write-Warn "API 不可达: $url"
            $summary = $null
        }
        if ($summary -and ($summary.PSObject.Properties.Name -contains 'stable')) { $summarySource = $base; break }
    }
    if (-not $summary -or -not ($summary.PSObject.Properties.Name -contains 'stable')) {
        Write-Err '无法获取版本信息（所有 API 均不可用）'
        return $null
    }

    $cache = @{}
    foreach ($ch in $order) {
        if (-not $summary.$ch) { continue }
        $ver = [string]$summary.$ch.version
        $detailUrl = [string]$summary.$ch.detail
        if (-not $detailUrl) { $detailUrl = "$summarySource/version/$ch.json" }
        $detail = $null
        try { $detail = Invoke-RestMethod $detailUrl -TimeoutSec 10 } catch {}
        if (-not $detail) {
            try { $detail = Invoke-RestMethod "$ApiBase2/version/$ch.json" -TimeoutSec 10 } catch {}
        }
        if (-not $detail) { Write-Warn "无法获取 $ch 通道详情，跳过"; continue }
        if (-not $ver -and $detail.tag_name) { $ver = [string]$detail.tag_name }
        if ($ver -and $detail.version -and (Compare-SemVer ([string]$detail.version) $ver) -gt 0) { $ver = [string]$detail.version }
        $cache[$ch] = @{ Version = $ver; Json = $detail }
    }
    if ($cache.Count -eq 0) { Write-Err '无法获取版本详情'; return $null }

    $bestCh = $order[0]
    if (-not $cache.ContainsKey($bestCh)) { $bestCh = @($cache.Keys)[0] }
    foreach ($k in $cache.Keys) {
        if ((Compare-SemVer $cache[$k].Version $cache[$bestCh].Version) -gt 0) { $bestCh = $k }
    }
    $best = $cache[$bestCh]
    if ($cache.ContainsKey($RequestedChannel) -and $bestCh -ne $RequestedChannel) {
        $reqVer = $cache[$RequestedChannel].Version
        if ((Compare-SemVer $best.Version $reqVer) -gt 0) {
            Write-Ok "最新版本: $($best.Version)（$bestCh 通道）比 $RequestedChannel 通道的 $reqVer 更新，按时间取最新 → $($best.Version)"
        }
        else {
            # 两通道版本号相同时优先正式版（stable）
            Write-Ok "最新版本: $($best.Version)（$RequestedChannel 与 $bestCh 通道均为该版本，优先正式版）"
        }
    }
    else { Write-Ok "最新 $RequestedChannel 版本: $($best.Version)" }
    return @{ Version = [string]$best.Version; Channel = $bestCh; Json = $best.Json; All = $cache }
}

# ======== 运行自测（-SelfTest） ========
# 覆盖本脚本自带的解析/探测纯函数，以及增量脚本导出的选择逻辑（存在则一并校验）
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
    Assert-Same '数字段序正确' (-1) (Compare-SemVer 'v6.9.0' 'v6.10.0')
    Assert-Same '比较结果是标量' 'Int32' (Compare-SemVer 'v6.19.2' 'v6.19.2').GetType().Name

    Write-Host '--- Resolve-ProxyConfig ---' -ForegroundColor Cyan
    Assert-Same 'http 代理' 'http://127.0.0.1:7897' (Resolve-ProxyConfig '127.0.0.1:7897').Url
    Assert-Same 'socks5 标记' $true (Resolve-ProxyConfig 'socks5://127.0.0.1:7897').Socks
    Assert-Same 'socks5 交给 curl' 'socks5://127.0.0.1:7897' (Resolve-ProxyConfig 'socks5://127.0.0.1:7897').ForCurl
    Assert-Same '按协议列表取值' 'http://127.0.0.1:7897' (Resolve-ProxyConfig 'http=127.0.0.1:7897;https=127.0.0.1:7897').Url
    Assert-Same '空值' '' (Resolve-ProxyConfig '').Url

    Write-Host '--- Get-DownloadCandidates ---' -ForegroundColor Cyan
    $cand = Get-DownloadCandidates -Url 'https://github.com/a/b.zip'
    Assert-Same '镜像数量' $MirrorHosts.Count $cand.Mirrors.Count
    Assert-Same '镜像无多余斜杠' $false ([string]$cand.Mirrors[0]).Contains('//https')
    Assert-Same '直连为原始地址' 'https://github.com/a/b.zip' $cand.Direct

    Write-Host '--- Parse-GithubAssetName ---' -ForegroundColor Cyan
    Assert-Same '完整包版本' 'v6.19.2' (Parse-GithubAssetName 'MAA-v6.19.2-win-x64.zip').Version
    Assert-Same '预发布完整包版本' 'v6.19.2-beta.2' (Parse-GithubAssetName 'MAA-v6.19.2-beta.2-win-x64.zip').Version
    Assert-Same 'arm64 识别' 'arm64' (Parse-GithubAssetName 'MAA-v6.19.2-win-arm64.zip').Arch

    Write-Host ''
    if ($script:fail -eq 0) { Write-Host '自测全部通过 ✔' -ForegroundColor Green; return $true }
    Write-Host "自测失败 $($script:fail) 项 ✘" -ForegroundColor Red
    return $false
}

if ($SelfTest) {
    $ok = Test-ScriptLogic
    if ($ok) { exit 0 } else { exit 1 }
}

# ======== 主流程 ========
Write-Step '获取最新版本信息'

# 从配置自动识别更新通道（仅当用户没有显式指定 -Channel 时）
if (-not $PSBoundParameters.ContainsKey('Channel')) {
    $cfgPath = Join-Path $ScriptDir 'config/gui.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $savedChannel = $cfg.'VersionUpdate.VersionType'
            if (-not $savedChannel -and $cfg.VersionUpdate) { $savedChannel = $cfg.VersionUpdate.VersionType }
            $channelMap = @{ '0' = 'stable'; '1' = 'beta'; '2' = 'alpha' }
            if ($savedChannel -and $channelMap["$savedChannel"]) {
                $Channel = $channelMap["$savedChannel"]
                Write-Info "从配置读取更新通道: $Channel"
            }
        }
        catch {}
    }
}
Write-Info "更新通道: $Channel"

Initialize-Proxy

$release = Resolve-MaaRelease -RequestedChannel $Channel
if (-not $release) { exit 1 }
$latestVer = [string]$release.Version

# 已是同版本 → 默认跳过下载（-Force 可强制重装）
$currentVer = Get-CurrentVersion
if ($currentVer) {
    Write-Info "本地版本 (MAA.exe): $currentVer"
    $cmp = Compare-SemVer $latestVer $currentVer
    if ($cmp -le 0 -and -not $Force) {
        if ($cmp -eq 0) { Write-Ok "已是最新 ($currentVer)，跳过下载" }
        else { Write-Ok "已是最新（本地 $currentVer 高于可用版本 $latestVer）" }
        exit 0
    }
}

$isArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM')
$wantArch = if ($isArm) { 'arm64' } else { 'x64' }
$asset = $null
$assetVer = ''
# MAA 的 version/<channel>.json 里，GitHub release 的 assets 位于 details.assets
$allAssets = @()
if ($release.Json.details -and $release.Json.details.assets) { $allAssets = @($release.Json.details.assets) }
elseif ($release.Json.assets) { $allAssets = @($release.Json.assets) }
foreach ($a in $allAssets) {
    $info = Parse-GithubAssetName ([string]$a.name)
    if ($info.Arch -ne $wantArch) { continue }
    if (-not $asset) { $asset = $a; $assetVer = $info.Version; continue }
    if ((Compare-SemVer $info.Version $assetVer) -gt 0) { $asset = $a; $assetVer = $info.Version }
}
if (-not $asset) {
    Write-Err "未找到适用于 win-$wantArch 的更新包（共 $($allAssets.Count) 个资产）"
    exit 1
}
Write-Info "选中更新包: $($asset.name) ($assetVer)"

$filename = $asset.name
$originalUrl = $asset.browser_download_url
$expectedSize = [long]$asset.size
$expectedSha256 = $asset.sha256
$filepath = Join-Path $ScriptDir $filename

Write-Info "文件名: $filename"
Write-Info "文件大小: $(Format-FileSize $expectedSize)"
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
else { Write-Info "最快线路: $($probes[0].Url) [$($probes[0].Route), $($probes[0].Kbs) KB/s]" }

if ($DryRun) {
    Write-Warn '仅检查模式（-DryRun），跳过下载与安装'
    exit 0
}
if (Test-Path $filepath) { Remove-Item -Force $filepath }
$downloadOk = Invoke-CandidateDownload -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize `
    -Sha256 ([string]$expectedSha256) -Probes $probes -DirectUrl $cand.Direct -ProxiedUrl $cand.Proxied -MirrorUrls $cand.Mirrors

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
