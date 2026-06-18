<#:
.SYNOPSIS
    MAA 一键更新脚本 — 无代理 v2.2（带故障冗余）
.DESCRIPTION
    放置于 MAA 安装目录下直接运行。
    具备下载重试、镜像降级、安装前备份、失败回滚、日志记录、API 缓存等冗余机制。
.AUTHOR
    bigbee
#>

param(
    [ValidateSet('stable', 'beta', 'alpha')]
    [string]$Channel = 'stable',
    [switch]$Force,
    [switch]$SkipVersion,
    [switch]$SkipResource,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
[System.Net.ServicePointManager]::DefaultConnectionLimit = 8
$script:HasCurl = $null -ne (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ======== DNS 加速（中国 DNS 解析 + 测速 + hosts/curl-resolve） ========
$DnsChina = @('223.5.5.5', '114.114.114.114', '119.29.29.29')
$SlowDomains = @('raw.githubusercontent.com', 'github.com', 'codeload.github.com')
$script:BestIps = @{}
$script:HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$script:HostsMarker = '# MAA-Update'
$script:CurlResolve = @()

function Resolve-DomainFast {
    param([string]$Domain)
    $allDns = $DnsChina + @('System')
    foreach ($dns in $allDns) {
        try {
            if ($dns -eq 'System') {
                $entry = [System.Net.Dns]::GetHostEntry($Domain)
                $ips = $entry.AddressList | Where-Object { $_ -is [System.Net.IPAddress] -and $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() }
            }
            else {
                $raw = & nslookup $Domain $dns 2>$null
                if ($LASTEXITCODE -ne 0) { continue }
                $ips = @()
                foreach ($line in $raw) {
                    if ($line -match '(\d+\.\d+\.\d+\.\d+)') { $ips += $matches[1] }
                }
                $ips = $ips | Select-Object -Unique | Where-Object { $_ -ne $Domain }
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
                if ($script:IsAdmin) {
                    $content = Get-Content $script:HostsPath -Raw -ErrorAction SilentlyContinue
                    if ($content) { $content = $content -replace "(?m)^\d+\.\d+\.\d+\.\d+\s+$dom\s*`n", '' }
                    "$bestIp $dom" | Out-File $script:HostsPath -Append -Encoding ASCII
                }
            }
        }
    }
    catch { Write-Warn "DNS 加速失败: $_" }
}
function Cleanup-DnsAccel {
    if ($script:IsAdmin -and (Test-Path $script:HostsPath)) {
        $content = Get-Content $script:HostsPath -Raw -ErrorAction SilentlyContinue
        if ($content) {
            foreach ($dom in $SlowDomains) {
                $content = $content -replace "(?m)^\d+\.\d+\.\d+\.\d+\s+$dom\s*`n", ''
            }
            Set-Content $script:HostsPath -Value $content -Encoding ASCII
        }
    }
}

# ======== 配置 ========
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$TempDir = Join-Path $ScriptDir ".update_temp"
$BackupDir = Join-Path $ScriptDir ".update_backup"
$LogFile = Join-Path $ScriptDir "update.log"
$StateFile = Join-Path $ScriptDir ".update_state"
$CacheDir = Join-Path $ScriptDir "cache\api"
$PwshDir = Join-Path $ScriptDir '.pwsh'
$PwshMarkerFile = Join-Path $ScriptDir '.pwsh_auto_attempted'
$script:PwshPath = $null
$script:HasPwsh = $false
$MaaApiBase = 'https://api.maa.plus/MaaAssistantArknights/api'
$MaaApiBase2 = 'https://api2.maa.plus/MaaAssistantArknights/api'
$MirrorHosts = @(
    'https://agent.imgg.dev',
    'https://ghproxy.net/https://github.com',
    'https://gh-proxy.com/https://github.com'
)
$GithubProxies = @(
    'https://ghproxy.net/',
    'https://gh-proxy.com/'
)
$ResourceRepo = 'MaaAssistantArknights/MaaResource'
$ResourceArchiveUrl = "https://github.com/$ResourceRepo/archive/refs/heads/main.zip"
$ResourceVersionUrl = "https://raw.githubusercontent.com/$ResourceRepo/main/resource/version.json"
$SummaryApi = 'version/summary.json'
$MaxRetries = 2
$PreserveDirs = @('achievement', 'background', 'cache', 'config', 'data', 'debug')

# ======== 等待提示（所有操作用） ========
function Show-Wait { param([string]$Msg) Write-Host "  ⏳ $Msg" -ForegroundColor DarkYellow }

# ======== 日志 ========
function Write-Log {
    param([string]$Level, [string]$Message)
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$time][$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
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
function Invoke-GetJson {
    param([string]$Url, [int]$TimeoutSec = 15)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'; $req.Timeout = $TimeoutSec * 1000; $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'MAA-Update/2.2'
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $json = $reader.ReadToEnd(); $resp.Close(); $reader.Close()
        return ($json | ConvertFrom-Json)
    }
    catch { return $null }
}

function Get-FileSize {
    param([string]$Url, [int]$TimeoutSec = 10)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'; $req.Timeout = $TimeoutSec * 1000; $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'MAA-Update/2.2'
        $resp = $req.GetResponse()
        $size = $resp.ContentLength; $resp.Close()
        return [long]$size
    }
    catch { return -1 }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -lt 0) { return '未知' }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
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

function New-Directory { param([string]$Path) if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

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
            } catch { $failed = $true; Write-Warn "分片 $i 下载失败: $_" }
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
        Write-Warn "分片下载失败，回退单线程: $_"
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
    if ($script:IsAdmin) {
        $msiUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$pwshVer/PowerShell-$pwshVer-win-x64.msi"
        $msiFile = Join-Path $TempDir "PowerShell-$pwshVer-win-x64.msi"
        foreach ($u in @("https://gh-proxy.com/$msiUrl", "https://ghproxy.net/$msiUrl", $msiUrl)) {
            if (Start-Download -Url $u -OutFile $msiFile -DisplayName "PowerShell $pwshVer MSI") { break }
        }
        if ((Test-Path $msiFile) -and ((Get-Item $msiFile).Length -gt 1MB)) {
            Write-Info '正在静默安装 PowerShell 7...'
            $p = Start-Process msiexec.exe -ArgumentList "/package `"$msiFile`" /quiet ADD_PATH=1" -Wait -PassThru -NoNewWindow
            Remove-Item -Force $msiFile -ErrorAction SilentlyContinue
            if ($p.ExitCode -eq 0 -and (Find-PwshPath)) { New-Item -Force $PwshMarkerFile | Out-Null; return $true }
        }
    }
    # 创建标记，下次不再自动下载
    New-Item -Force $PwshMarkerFile | Out-Null
    Write-Warn 'PowerShell 7 自动安装失败。请从微软商店安装：'
    Write-Warn 'https://apps.microsoft.com/detail/9mz1snwt0n5d?hl=zh-CN&gl=CN'
    return $false
}

# ======== HTTP/2 下载（pwsh + .NET SocketsHttpHandler） ========
function Start-Http2Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0)
    if (-not $script:HasPwsh) { return $false }
    try {
        Write-Info "尝试 HTTP/2 下载 (pwsh)..."
        New-Directory $TempDir
        New-Directory (Split-Path $OutFile -Parent)
        $ps1 = Join-Path $TempDir 'http2_dl.ps1'
        @"
param(`$u, `$o)
try {
    `$h = [System.Net.Http.SocketsHttpHandler]::new()
    `$h.EnableMultipleHttp2Connections = `$true
    `$c = [System.Net.Http.HttpClient]::new(`$h)
    `$c.DefaultRequestHeaders.UserAgent.ParseAdd('MAA-Update/2.2')
    `$c.Timeout = [TimeSpan]::FromSeconds(600)
    `$r = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, `$u)
    `$r.Version = [System.Net.HttpVersion]::Version20
    `$resp = `$c.SendAsync(`$r, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not `$resp.IsSuccessStatusCode) { exit 1 }
    `$s = `$resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    `$f = [System.IO.File]::Create(`$o)
    `$s.CopyToAsync(`$f).GetAwaiter().GetResult()
    `$f.Close()
    exit 0
} catch { exit 2 }
"@ | Set-Content $ps1 -Encoding UTF8
        & $script:PwshPath -NoProfile -File $ps1 $Url $OutFile
        Remove-Item -Force $ps1 -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile)) {
            $actualSize = (Get-Item $OutFile).Length
            if ($ExpectedSize -le 0 -or $actualSize -eq $ExpectedSize) {
                Write-Ok "$DisplayName 下载完成 (HTTP/2, $(Format-FileSize $actualSize))"
                return $true
            }
            Write-Warn "HTTP/2 大小不匹配"; Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        } else { Write-Warn "HTTP/2 退出($LASTEXITCODE)" }
    } catch { Write-Warn "HTTP/2 下载失败: $_" }
    return $false
}

# ======== 下载（带进度 + 重试 + 校验 + 分片 + BITS + HTTP/2 + curl） ========
function Start-Download {
    param([string]$Url, [string]$OutFile, [string]$DisplayName, [long]$ExpectedSize = 0)

    # 0. pwsh HTTP/2 下载（SocketsHttpHandler，适合受限网络）
    if (Start-Http2Download -Url $Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize) {
        return $true
    }

    # 1. curl.exe（TCP 栈优于 .NET，优先）
    if ($script:HasCurl) {
        for ($try = 1; $try -le $MaxRetries; $try++) {
            if ($try -gt 1) { Write-Warn "curl 重试第 $try 次..." }
            try {
                Write-Info "尝试 curl 下载..."
                New-Directory (Split-Path $OutFile -Parent)
                & curl.exe -L -f -o $OutFile --connect-timeout 5 --max-time 600 --speed-limit 10240 --speed-time 15 $script:CurlResolve $Url
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
            catch { Write-Warn "curl 下载失败: $_"; Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
        }
    }

    # 2. 分片下载（>10MB 大文件加速）
    if (Start-SegmentedDownload -Url $Url -OutFile $OutFile -DisplayName $DisplayName -ExpectedSize $ExpectedSize) {
        return $true
    }

    # 3. 单线程 HttpWebRequest
    for ($try = 1; $try -le $MaxRetries; $try++) {
        if ($try -gt 1) { Write-Warn "下载重试第 $try 次...正在下载不要关闭程序" }
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = 'GET'; $req.Timeout = 15000; $req.ReadWriteTimeout = 60000
            $req.UserAgent = 'MAA-Update/2.2'
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
            Write-Warn "下载失败: $_"
            Remove-Item -Force $OutFile -ErrorAction SilentlyContinue
        }
    }
    Write-Progress -Activity "下载 $DisplayName" -Completed

    Write-Err "$DisplayName 下载失败（curl/分片/HTTP 均不可用）"
    return $false
}

# ======== 版本检测（4 级降级） ========
function Get-CurrentVersion {
    # 1: MAA.exe
    $exePath = Join-Path $ScriptDir 'MAA.exe'
    if (Test-Path $exePath) {
        try {
            $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
            foreach ($prop in @($ver.FileVersion, $ver.ProductVersion)) {
                if ($prop -and ($prop -notmatch '^0+(\.0+)*$')) {
                    $v = "v$(($prop -split '\+')[0].TrimStart('v'))"
                    Write-Info "当前版本 (MAA.exe): $v"; return $v
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
            foreach ($prop in @($ver.FileVersion, $ver.ProductVersion)) {
                if ($prop -and ($prop -notmatch '^0+(\.0+)*$')) {
                    $v = "v$(($prop -split '\+')[0].TrimStart('v'))"
                    Write-Info "当前版本 (MaaCore.dll): $v"; return $v
                }
            }
        }
        catch {}
    }
    # 3: gui.json
    $cfgPath = Join-Path $ScriptDir 'config/gui.json'
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.VersionUpdate.name) { Write-Info "当前版本 (gui.json): $($cfg.VersionUpdate.name)"; return $cfg.VersionUpdate.name }
        }
        catch {}
    }
    Write-Warn '无法检测当前版本，使用 0.0.0'
    return 'v0.0.0'
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

function Request-WithCache {
    param([string]$Url, [string]$CacheKey, [int]$TimeoutSec = 15)
    $data = Invoke-GetJson $Url -TimeoutSec $TimeoutSec
    if ($data) { Write-ApiCache -ApiPath $CacheKey -Data $data; return $data }
    $cached = Read-ApiCache -ApiPath $CacheKey
    if ($cached) { Write-Warn "API 不可达，使用缓存 ($CacheKey)"; return $cached }
    return $null
}

# ======== 资源版本缓存（24h 过期） ========
$ResCacheFile = Join-Path $CacheDir 'resource_version.json'
function Read-ResVersionCache {
    if (-not (Test-Path $ResCacheFile)) { return $null }
    try {
        $cache = Get-Content $ResCacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = [DateTime]::Now - [DateTime]::ParseExact($cache.cached_at, 'yyyy-MM-dd HH:mm:ss', $null)
        if ($age.TotalHours -le 24) { return $cache }
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

# ======== 检查版本更新 ========
function Check-VersionUpdate {
    Write-Step '检查 MAA 版本更新'

    $configPath = Join-Path $ScriptDir 'config/gui.json'
    if ((Test-Path $configPath) -and ($Channel -eq 'stable')) {
        try {
            $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $savedChannel = $cfg.'VersionUpdate.VersionType'
            if ($savedChannel) {
                $channelMap = @{ '0' = 'stable'; '1' = 'beta'; '2' = 'alpha' }
                $detected = $channelMap["$savedChannel"]
                if ($detected) { $Channel = $detected; Write-Info "从配置读取更新通道: $Channel" }
            }
        }
        catch {}
    }
    Write-Info "更新通道: $Channel"

    # API 主备切换
    $summary = $null
    foreach ($base in @($MaaApiBase, $MaaApiBase2)) {
        $url = "$base/$SummaryApi"
        Write-Info "请求版本摘要: $url"
        $summary = Request-WithCache -Url $url -CacheKey "version/summary.json"
        if ($summary -and $summary.$Channel) { break }
    }
    if (-not $summary -or -not $summary.$Channel) {
        Write-Err '无法获取版本信息（API 和缓存均不可用）'
        return $null
    }

    $latestVer = $summary.$Channel.version
    Write-Ok "最新 $Channel 版本: $latestVer"

    # 版本相同时直接跳过，不查详情
    $c = $script:CurrentVersion.TrimStart('v'); $l = $latestVer.TrimStart('v')
    if ($c -eq $l -and -not $Force) { Write-Ok "已是最新 ($($script:CurrentVersion))"; return $null }

    # 详情获取（主 API + 备用 API 两种方式）
    $detailUrl = $summary.$Channel.detail
    $detail = Request-WithCache -Url $detailUrl -CacheKey "version/$Channel.json"
    if (-not $detail) {
        $backupUrl = "$MaaApiBase2/version/$Channel.json"
        $detail = Request-WithCache -Url $backupUrl -CacheKey "version/$Channel.json"
    }
    if (-not $detail) { Write-Err '无法获取版本详情'; return $null }

    $assets = $detail.details.assets
    if (-not $assets) { Write-Err '版本详情中无 assets 列表'; return $null }

    $isArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM')
    $arch = if ($isArm) { 'arm64' } else { 'x64' }

    # 优先 OTA，兜底完整包
    $otaAsset = $null; $fullAsset = $null
    $currentVer = $script:CurrentVersion
    foreach ($a in $assets) {
        $name = [string]$a.name
        if (-not $name.Contains('win')) { continue }
        if (($isArm) -xor ($name.Contains('arm64'))) { continue }
        if ($name.Contains('OTA') -and $name.Contains($currentVer)) { $otaAsset = $a; Write-Info "找到匹配的 OTA 包: $name"; break }
        if ($name -match "^MAA-v[\d\.]+\-win-$arch\.zip$") { $fullAsset = $a }
    }
    $selected = $otaAsset; $pkgType = 'OTA'
    if (-not $selected) { $selected = $fullAsset; $pkgType = '完整包' }
    if (-not $selected) { Write-Err "未找到适用于 win-$arch 的更新包"; return $null }

    Write-Info "新版本: $latestVer"
    return @{ Version = $latestVer; Type = $pkgType; Asset = $selected; DetailJson = $detail; Arch = $arch }
}

# ======== 下载更新（镜像列表冗余） ========
function Download-UpdatePackage {
    param($UpdateInfo)
    $asset = $UpdateInfo.Asset
    $filename = $asset.name
    $filepath = Join-Path $ScriptDir $filename
    $expectedSize = [long]$asset.size
    $originalUrl = $asset.browser_download_url

    Write-Info "原始: $originalUrl"

    $tryOrder = @()
    # 1. 镜像（替换 github.com 域名）
    foreach ($m in $MirrorHosts) {
        $tryOrder += ($originalUrl -replace 'https://github\.com/', "$m/")
    }
    # 2. 社区代理（拼接完整 URL）
    foreach ($p in $GithubProxies) {
        $tryOrder += "$p$originalUrl"
    }
    # 3. 原始 GitHub（兜底）
    $tryOrder += $originalUrl

    for ($try = 0; $try -lt $tryOrder.Count -and $try -lt ($MaxRetries + 2); $try++) {
        $url = $tryOrder[$try]
        if ($try -gt 0) { Write-Info "切换下载源: $url" }
        
        if ($DryRun) { Write-Warn '仅检查模式，跳过下载'; return $null }
        if (Test-Path $filepath) { Remove-Item -Force $filepath }
        Set-State -Phase 'downloading' -Version $UpdateInfo.Version -Detail $filename
        
        if (Start-Download -Url $url -OutFile $filepath -DisplayName $filename -ExpectedSize $expectedSize) {
            return $filepath
        }
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
    New-Directory $extractDir
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
        # 备份保留目录
        foreach ($d in $PreserveDirs) {
            $src = Join-Path $ScriptDir $d
            if (Test-Path $src) { Copy-Item -Recurse $src (Join-Path $BackupDir $d) -Force }
        }
        # 复制新文件（跳过保留目录中的控制文件）
        $controlFiles = @('removelist.txt', 'changes.json')
        Get-ChildItem $sourceDir -File -Recurse | ForEach-Object {
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

    $localVerPath = Join-Path $ScriptDir 'resource/version.json'
    $localTime = Get-Date 0
    if (Test-Path $localVerPath) {
        try {
            $localJson = Get-Content $localVerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $localTime = [DateTime]::ParseExact($localJson.last_updated, 'yyyy-MM-dd HH:mm:ss.fff', $null)
        }
        catch {}
    }
    Write-Info "本地资源时间: $($localTime.ToString('yyyy-MM-dd HH:mm:ss'))"

    $remoteJson = Read-ResVersionCache
    if (-not $remoteJson) {
        for ($i = 1; $i -le 2; $i++) {
            if ($i -gt 1) { Write-Info "重试第 $i 次..." }
            Show-Wait "[$i/2] 正在检查资源版本..."
            $remoteJson = Invoke-GetJson $ResourceVersionUrl -TimeoutSec 10
            if ($remoteJson -and $remoteJson.last_updated) { Write-ResVersionCache $remoteJson.last_updated; break }
        }
    }
    else { Write-Info '使用缓存的资源版本' }
    if (-not $remoteJson -or -not $remoteJson.last_updated) {
        Write-Warn '无法获取远程资源版本，跳过资源更新'
        return $false
    }

    $remoteTime = [DateTime]::ParseExact($remoteJson.last_updated, 'yyyy-MM-dd HH:mm:ss.fff', $null)
    Write-Info "远程资源时间: $($remoteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    if ($remoteTime -le $localTime -and -not $Force) { Write-Ok '资源已是最新'; return $true }

    Write-Info "发现新资源 ($($remoteJson.last_updated))"
    if ($DryRun) { Write-Warn '仅检查模式，跳过资源下载'; return $null }

    # 资源包下载 - 多源多策略重试
    $resZip = Join-Path $TempDir 'MaaResource.zip'
    $dlOk = $false
    $resUrls = @(
        $ResourceArchiveUrl,
        "https://gh-proxy.com/$ResourceArchiveUrl",
        "https://ghproxy.net/$ResourceArchiveUrl"
    )
    if (-not $script:HasPwsh) { Write-Info 'pwsh 不可用，HTTP/2 下载将被跳过' }
    for ($try = 1; $try -le 2; $try++) {
        if ($try -gt 1) { Write-Info "资源下载重试第 $try 次..."; Start-Sleep 2 }
        foreach ($rurl in $resUrls) {
            if (Start-Download -Url $rurl -OutFile $resZip -DisplayName '游戏资源包') { $dlOk = $true; break }
            Write-Warn "资源下载源不可用: $rurl"
        }
        if ($dlOk) { break }
    }
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
    Write-Ok "资源更新完成 ($($remoteJson.last_updated))"
    return $true
}

# ======== 清理 ========
function Cleanup-Temp {
    Cleanup-DnsAccel
    foreach ($d in @($TempDir, $BackupDir)) { if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue } }
    Write-Info '临时文件已清理'
}

# ======== 主流程 ========
try {
    # 清旧日志，写新日志
    if (Test-Path $LogFile) { Remove-Item -Force $LogFile -ErrorAction SilentlyContinue }
    Write-Log 'INFO' "=== MAA 更新脚本 v2.2 启动 ==="
    Write-Log 'INFO' "目录: $ScriptDir | 通道: $Channel"
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

    # DNS 加速（解析 + 测速 + hosts/curl-resolve）
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
        $localRp = Join-Path $ScriptDir 'resource/version.json'
        $localRt = Get-Date 0
        if (Test-Path $localRp) {
            try { $localRj = Get-Content $localRp -Raw -Encoding UTF8 | ConvertFrom-Json; $localRt = [DateTime]::ParseExact($localRj.last_updated, 'yyyy-MM-dd HH:mm:ss.fff', $null) } catch {}
        }
        # 检查缓存
        $remoteRj = Read-ResVersionCache
        if (-not $remoteRj) {
            for ($i = 1; $i -le 2; $i++) {
                if ($i -gt 1) { Start-Sleep 1 }
                Show-Wait "[$i/2] 正在检查资源版本..."
                $remoteRj = Invoke-GetJson $ResourceVersionUrl -TimeoutSec 10
                if ($remoteRj -and $remoteRj.last_updated) {
                    Write-ResVersionCache $remoteRj.last_updated; break
                }
            }
        }
        else { Write-Info '使用缓存的资源版本' }
        if ($remoteRj -and $remoteRj.last_updated) {
            $remoteRt = [DateTime]::ParseExact($remoteRj.last_updated, 'yyyy-MM-dd HH:mm:ss.fff', $null)
            if ($remoteRt -gt $localRt -or $Force) { $needResourceUpdate = $true }
            else { Write-Ok '资源已是最新' }
        }
        else { Write-Warn '无法获取远程资源版本，跳过资源更新（可按上方说明手动安装 PowerShell 7 后重试）' }
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

    # 1. 下载更新包（MAA 仍可运行）
    if ($updateInfo) {
        $pkgPath = Download-UpdatePackage $updateInfo
    }

    # 2. 关闭 MAA（安装前才关）
    $maaProc = Get-Process 'MAA' -ErrorAction SilentlyContinue
    if ($maaProc) {
        Write-Warn "正在关闭 MAA (PID: $($maaProc.Id))..."
        if (-not $DryRun) {
            $maaProc.CloseMainWindow() | Out-Null
            Start-Sleep 1
            if (-not $maaProc.HasExited) { $maaProc.Kill(); Start-Sleep 2 }
        }
    }

    # 3. 安装版本更新
    if ($pkgPath) {
        $updateApplied = Install-Update -PackagePath $pkgPath -UpdateInfo $updateInfo
        if (Test-Path $pkgPath) { Remove-Item -Force $pkgPath -ErrorAction SilentlyContinue }
        if (-not $updateApplied -and (Test-Path $BackupDir)) { Restore-Backup }
    }

    # 4. 资源更新
    if ($needResourceUpdate) { Update-Resource }

    Cleanup-Temp
    Clear-State
    Write-Log 'OK' "=== 更新完成 ==="

    # === 重启 MAA ===
    if ($maaWasRunning -and (Test-Path (Join-Path $ScriptDir 'MAA.exe'))) {
        Write-Info '启动 MAA...'
        Start-Process (Join-Path $ScriptDir 'MAA.exe') -WorkingDirectory $ScriptDir
        Write-Ok 'MAA 已重新启动'
    }

}
catch {
    Write-Err "更新过程出错: $_"
    Write-Err $_.ScriptStackTrace
    Write-Log 'ERROR' "异常: $_"
    if (Test-Path $BackupDir) { Restore-Backup }
    Cleanup-Temp
    Clear-State
    exit 1
}
