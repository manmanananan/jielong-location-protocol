<#
.SYNOPSIS
    一键准备接龙抓包环境：装 mitmproxy、起代理、装 CA。

.DESCRIPTION
    幂等：重复跑不会重复安装、不会重复导入证书。
    每一步都可以用开关跳过，方便分步排障：

        pwsh -File scripts\setup.ps1 -Port 8899
        pwsh -File scripts\setup.ps1 -Port 8888 -OutDir D:\jl-mitm
        pwsh -File scripts\setup.ps1 -SkipInstall -SkipCa     # 只起代理

.PARAMETER Port
    mitmproxy 监听端口。默认 8899。冲突就换一个（8080/8888/9090 都常用）。

.PARAMETER OutDir
    mitmproxy 的 confdir（CA 与 flow 文件放这里）。
    默认 <仓库根>\mitm —— 这个目录已被 .gitignore 排除。

.PARAMETER SkipInstall
    跳过 mitmproxy 安装检查。

.PARAMETER SkipCa
    跳过 CA 导入。

.PARAMETER SkipProxy
    跳过设置系统代理（只想生成 CA 时用）。

.PARAMETER Force
    confdir 里已有证书也重新生成（旧证书会覆盖，客户端需重新导入）。

.PARAMETER Addon
    addon 脚本路径，默认自动找仓库里的 src\jl_addon.py。

.EXAMPLE
    pwsh -File scripts\setup.ps1 -Port 8899

.EXAMPLE
    pwsh -File scripts\setup.ps1 -Port 8888 -OutDir D:\jl-mitm -SkipInstall

.NOTES
    收尾请务必执行 docs\03-mitm-setup.md §8 的清理清单：
    关系统代理、停 mitmproxy、删受信任根证书、清掉 sign_body_*.json。
#>
[CmdletBinding()]
param(
    [int]    $Port        = 8899,
    [string] $OutDir      = "",
    [string] $Addon       = "",
    [switch] $SkipInstall,
    [switch] $SkipCa,
    [switch] $SkipProxy,
    [switch] $Force
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot "mitm" }
if (-not $Addon)  { $Addon  = Join-Path $RepoRoot "src\jl_addon.py" }

$ProxyReg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok  ([string]$msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 0. 预检
Write-Step "预检"
Write-Ok "仓库根目录: $RepoRoot"
Write-Ok "端口: $Port"
Write-Ok "confdir: $OutDir"
Write-Ok "addon: $Addon"

if (-not (Test-Path $Addon)) {
    throw "找不到 addon: $Addon  （用 -Addon 指定路径）"
}

# 端口占用检查：避免 mitmdump 起来立刻退出，而后面步骤还以为成功了
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) {
    $owner = (Get-Process -Id $busy[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName
    throw "端口 $Port 已被占用（进程: $owner）。换一个 -Port，或先停掉它。"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------------------------------------------------------------- 1. 装 mitmproxy
if (-not $SkipInstall) {
    Write-Step "检查 mitmproxy"
    $mitm = Get-Command mitmdump -ErrorAction SilentlyContinue
    if ($mitm) {
        Write-Ok "已安装: $($mitm.Source)"
        & mitmdump --version 2>&1 | Select-Object -First 2 | ForEach-Object { Write-Host "         $_" }
    }
    else {
        Write-Warn "未找到 mitmdump，尝试安装"
        $uv = Get-Command uv -ErrorAction SilentlyContinue
        if ($uv) {
            Write-Host "    使用 uv tool install mitmproxy ..."
            & uv tool install mitmproxy
            # uv 装完的目录可能不在当前 PATH，手动补一下
            $uvBin = Join-Path $env:USERPROFILE ".local\bin"
            if ((Test-Path $uvBin) -and ($env:PATH -notlike "*$uvBin*")) { $env:PATH = "$uvBin;$env:PATH" }
        }
        else {
            Write-Warn "没有 uv，改用 pip"
            & python -m pip install --upgrade mitmproxy
        }
        $mitm = Get-Command mitmdump -ErrorAction SilentlyContinue
        if (-not $mitm) {
            throw "mitmdump 仍不可用。手动装：uv tool install mitmproxy  （或 python -m pip install mitmproxy）"
        }
        Write-Ok "安装完成: $($mitm.Source)"
    }
}
else {
    Write-Step "跳过安装检查"
}

# ---------------------------------------------------------------- 2. 生成 CA
Write-Step "生成 / 检查 CA"
# confdir 下没有证书就先跑一次触发初始化；mitmproxy 在真正开始监听时才生成
$cerPath = Join-Path $OutDir "mitmproxy-ca-cert.cer"
$haveMitm = Get-Command mitmdump -ErrorAction SilentlyContinue
if ($Force -and (Test-Path $cerPath)) {
    Write-Warn "-Force 指定，删除旧证书后重新生成"
    Get-ChildItem $OutDir -Filter "mitmproxy*" | Remove-Item -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $cerPath) -and $haveMitm) {
    Write-Host "    首次运行，生成证书 ..."
    $tmp = $null
    try {
        $tmp = Start-Process -FilePath "mitmdump" `
            -ArgumentList "--set", "confdir=$OutDir", "--listen-port", "$Port" `
            -PassThru -WindowStyle Hidden
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and -not (Test-Path $cerPath)) { Start-Sleep -Milliseconds 400 }
    }
    catch {
        Write-Warn "启动 mitmdump 生成证书失败: $($_.Exception.Message)"
    }
    finally {
        if ($tmp -and -not $tmp.HasExited) { Stop-Process -Id $tmp.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
    }
}
elseif (-not $haveMitm) {
    Write-Warn "mitmdump 不在 PATH，跳过证书生成（装完再跑一次本脚本即可）"
}
if (Test-Path $cerPath) {
    Write-Ok "证书: $cerPath"
}
else {
    Write-Warn "证书尚未生成"
}

# ---------------------------------------------------------------- 3. 装 CA 到受信任根
if (-not $SkipCa) {
    Write-Step "导入 CA 到『受信任的根证书颁发机构』"
    if (-not (Test-Path $cerPath)) {
        Write-Warn "证书不存在，跳过导入: $cerPath"
        Write-Warn "先确认 mitmdump 可用，再重跑本脚本"
    }
    else {
        $already = Get-ChildItem Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -like "*mitmproxy*" }
        if ($already) {
            Write-Ok "已存在 mitmproxy 根证书，跳过（要重装先按 docs/03 §3.3 删掉）"
        }
        else {
            # -user Root 不需要管理员；若微信抓不到再考虑装到 LocalMachine
            & certutil -addstore -user Root $cerPath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "certutil 导入失败（退出码 $LASTEXITCODE）。可改用图形界面：Start-Process '$cerPath'"
            }
            else {
                Write-Ok "已导入 CurrentUser\Root"
            }
        }
    }
}

# ---------------------------------------------------------------- 4. 系统代理
if (-not $SkipProxy) {
    Write-Step "设置系统代理"
    $old = Get-ItemProperty $ProxyReg -ErrorAction SilentlyContinue
    Write-Host "    原值: ProxyEnable=$($old.ProxyEnable) ProxyServer=$($old.ProxyServer)"
    Write-Host "    （已在脚本里备份到 $OutDir\proxy-backup.txt）"
    @(
        "ProxyEnable=$($old.ProxyEnable)"
        "ProxyServer=$($old.ProxyServer)"
        "ProxyOverride=$($old.ProxyOverride)"
        "AutoConfigURL=$($old.AutoConfigURL)"
    ) | Set-Content -Path (Join-Path $OutDir "proxy-backup.txt") -Encoding utf8

    if ($old.AutoConfigURL) {
        Write-Warn "检测到 PAC（AutoConfigURL=$($old.AutoConfigURL)），它可能绕过代理，先移除"
        Remove-ItemProperty $ProxyReg -Name AutoConfigURL -ErrorAction SilentlyContinue
    }

    Set-ItemProperty $ProxyReg -Name ProxyEnable   -Value 1
    Set-ItemProperty $ProxyReg -Name ProxyServer   -Value "127.0.0.1:$Port"
    Set-ItemProperty $ProxyReg -Name ProxyOverride -Value "<local>;127.*;localhost"
    Write-Ok "系统代理 → 127.0.0.1:$Port"
    Write-Warn "已运行的进程不会立刻生效，微信需要完全退出再启动"
}

# ---------------------------------------------------------------- 5. 冒烟测试
Write-Step "冒烟测试（验证 CA 与上游链路）"
try {
    $probe = & curl.exe -s --max-time 15 -x "http://127.0.0.1:$Port" `
        "https://jielong.huolieyun.com/activity/activityDetail" `
        -X POST -H "Content-Type: application/json" -d "{}" 2>&1
    if ([string]::IsNullOrWhiteSpace(($probe -join ""))) {
        Write-Warn "无响应 —— 代理还没启动（这一步本来就在起代理之前，属正常）"
    }
    else {
        Write-Host "    响应: $probe"
        if ("$probe" -match "901") { Write-Ok "链路通（status:901 = 路径存在且鉴权先于业务）" }
        else { Write-Warn "响应不符合预期，确认上游是否可达、是否被上游代理拦截" }
    }
}
catch {
    Write-Warn "冒烟测试未执行：$($_.Exception.Message)"
}

# ---------------------------------------------------------------- 6. 起代理
Write-Step "启动 mitmdump"
Write-Host @"
    在新窗口里跑（前台，方便看日志）：

        mitmdump -s "$Addon" --listen-port $Port --set confdir="$OutDir"

    或直接让本脚本起一个后台进程：

        Start-Process mitmdump -ArgumentList '-s','"$Addon"','--listen-port','$Port','--set','confdir="$OutDir"'

    加改写时先设环境变量（同一个 shell）：

        `$env:JL_REWRITE="1"
        `$env:JL_LAT="<TARGET_LAT>"; `$env:JL_LON="<TARGET_LON>"
        `$env:JL_NAME="<PLACE_NAME>"; `$env:JL_ADDR="<PLACE_ADDRESS>"

    抓包产物落在 $OutDir（已在 .gitignore 里），
    其中 sign_body_*.json 含真实凭据，不要提交、不要外传。
"@ -ForegroundColor Gray

Write-Step "完成"
Write-Host "    下一步：docs\03-mitm-setup.md §6 验证；README.md §3 使用" -ForegroundColor Green
Write-Host "    收尾：docs\03-mitm-setup.md §8 清理清单（关代理 / 停进程 / 删证书）" -ForegroundColor Yellow
