# 03 · mitmproxy 安装与链路搭建（Windows）

> 目标：从零到「微信小程序的 HTTPS 流量能在终端里看到明文」。
> 全部命令按 PowerShell 7 写，关键处标注坑。

---

## 0. 全景

```
┌──────────────┐   系统代理    ┌──────────────┐   上游    ┌──────────────────────┐
│ 微信 (WMPF)  │ ───────────▶ │  mitmproxy   │ ───────▶ │ jielong.huolieyun.com│
│ 小程序       │ 127.0.0.1:8899│  + addon     │  TLS     │ :443                 │
└──────────────┘               └──────────────┘           └──────────────────────┘
        信任自签 CA ↑                    ↑ 明文在这里可读写
```

四件事必须都成立，缺一个就抓不到：

1. mitmproxy 在跑，监听端口对；
2. 系统代理指向这个端口（且 PAC 没把流量绕过去）；
3. 自签 CA 装进「受信任的根证书颁发机构」；
4. 客户端**愿意**用系统代理（微信基本愿意，个别版本要额外确认）。

---

## 1. 安装 mitmproxy

### 1.1 推荐：uv（隔离环境，不污染全局 Python）

```powershell
# 装 uv（已有可跳过）
irm https://astral.sh/uv/install.ps1 | iex

# 装 mitmproxy 到独立环境
uv tool install mitmproxy

# 验证
mitmdump --version
```

### 1.2 备选：pip

```powershell
python -m pip install --upgrade mitmproxy
python -m mitmproxy.tools.main --version     # 某些环境 PATH 里没有 mitmdump.exe
```

> **坑**：`pip install mitmproxy` 在 Python 3.14 上可能因为二进制依赖编译失败。
> 遇到就先试 `uv tool install`，它带预编译轮子。

### 1.3 三个可执行文件的分工

| 命令 | 用途 |
|---|---|
| `mitmdump` | 无界面，跑 addon 用这个 |
| `mitmweb` | 带 Web UI（默认 `127.0.0.1:8081`），点着看请求很方便 |
| `mitmproxy` | 终端 TUI，键盘操作 |

日常用 `mitmdump` + 看日志。临时排查用 `mitmweb`。

---

## 2. 首次启动与 CA 生成

```powershell
# 指定端口、指定产物目录（-w 会把流量写成 flow 文件，可选）
mitmdump --listen-port 8899 --set confdir="$PWD\mitm"
```

首次启动会在 `confdir`（默认 `~\.mitmproxy`）生成：

```
mitmproxy-ca.pem            ← 私钥+证书，别外传
mitmproxy-ca-cert.pem       ← 给非 Windows 客户端
mitmproxy-ca-cert.cer       ← 给 Windows，双击安装用这个
mitmproxy-ca-cert.p12       ← 给 iOS/部分客户端
mitmproxy-dhparam.pem       ← DH 参数
```

> **坑（重要）**：mitmproxy 8+ 的证书分发页（`http://mitm.it`）和文档里
> 推荐的是 `.cer`。老教程里写的 `.pem` 在 Windows 证书导入向导里会被拒
> （提示「不是有效的证书文件」）。**用 `mitmproxy-ca-cert.cer`。**

---

## 3. 安装 CA 到受信任根

### 3.1 图形界面（最稳）

```powershell
# 打开证书文件，选「安装证书」
Start-Process "$env:USERPROFILE\.mitmproxy\mitmproxy-ca-cert.cer"
# → 安装证书 → 本地计算机（或当前用户）→ 浏览 → 「受信任的根证书颁发机构」
```

### 3.2 命令行（管理员 PowerShell）

```powershell
$cert = "$env:USERPROFILE\.mitmproxy\mitmproxy-ca-cert.cer"

# 装到当前用户（不需要管理员）
certutil -addstore -user Root $cert

# 或装到本机（需要管理员）
certutil -addstore Root $cert

# 验证装上了
Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -like "*mitmproxy*" }
```

期望输出里出现 `CN=mitmproxy, O=mitmproxy`。

### 3.3 清干净（重装 / 收尾）

```powershell
Get-ChildItem Cert:\CurrentUser\Root |
  Where-Object { $_.Subject -like "*mitmproxy*" } |
  Remove-Item
```

> **坑**：装到 `CurrentUser\Root` 的证书，某些以 SYSTEM 身份跑的服务读不到。
> 如果微信的流量在浏览器里能抓、在微信里抓不到，先试装到 `LocalMachine\Root`。

---

## 4. 系统代理

### 4.1 设置

```powershell
$port = 8899
$reg  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

Set-ItemProperty $reg -Name ProxyEnable -Value 1
Set-ItemProperty $reg -Name ProxyServer -Value "127.0.0.1:$port"
Set-ItemProperty $reg -Name ProxyOverride -Value "<local>;127.*;localhost"
```

### 4.2 验证

```powershell
Get-ItemProperty $reg | Select-Object ProxyEnable, ProxyServer, ProxyOverride
```

### 4.3 撤销（务必记下来）

```powershell
Set-ItemProperty $reg -Name ProxyEnable -Value 0
```

> **坑 1：改了注册表不一定立刻生效。** 已经运行的进程会缓存代理设置，
> 必须重启微信（`Get-Process WeChat, Weixin, WeChatAppEx | Stop-Process`）。
>
> **坑 2：PAC 脚本可能覆盖手填的代理。** 检查 `AutoConfigURL`，
> 有值就先删掉（`Remove-ItemProperty $reg -Name AutoConfigURL`），
> 否则流量会按 PAC 走，绕开 mitmproxy。
>
> **坑 3：系统代理是全局的。** 抓包期间你所有的浏览器流量都会过 mitmproxy。
> 抓完立刻关，别挂着过夜。

### 4.4 不想动系统代理？用透明代理 / 直接指定

只在浏览器里测的话，可以用 `--proxyauth` 之类的方式，
但对微信这种不认启动参数的程序没用——**微信只读系统代理**，所以还是得改注册表。

---

## 5. 上游链路

mitmproxy 默认直连目标（`--mode regular`）。几种常见变体：

### 5.1 直连（默认，最常用）

```powershell
mitmdump --listen-port 8899 -s src\jl_addon.py
```

### 5.2 走二级代理（本地已有 Clash / v2ray 等）

```powershell
mitmdump --listen-port 8899 --mode upstream:http://127.0.0.1:7890 -s src\jl_addon.py
```

> **坑**：上游代理的端口要写对，`7890` 是 Clash 默认，v2ray 常见 `10809`（HTTP）
> 与 `10808`（SOCKS）。写错时现象是「所有请求 502」，不是「连不上」。

### 5.3 反向代理模式（把某个域名整体接过来）

```powershell
# 把 http://127.0.0.1:9000 的请求反过来打到接龙
mitmdump --mode reverse:https://jielong.huolieyun.com@9000 -s src\jl_addon.py
```

这个模式适用于「自己写个客户端直接打本地端口」的场景，
不适合微信（微信写死了域名）。

### 5.4 只抓特定域名（减少噪音）

addon 里已经按 `TARGET_HOST` 过滤了，不需要 `--intercept`。
如果想让 mitmproxy 层面就过滤：

```powershell
mitmdump --listen-port 8899 --allow-hosts "jielong\.huolieyun\.com" -s src\jl_addon.py
```

---

## 6. 跑起来验证

### 6.1 第一步：确认代理链路通

```powershell
# 另开一个窗口
curl.exe -s -x http://127.0.0.1:8899 https://jielong.huolieyun.com/activity/activityDetail -X POST -H "Content-Type: application/json" -d "{}"
```

期望：

```json
{"msg":"token为空","status":901}
```

同时 mitmdump 窗口出现：

```
[..] POST /activity/activityDetail auth=no(0) token=no(0) len=2
[..] <<< 200 /activity/activityDetail :: {"msg":"token为空","status":901}
```

**到这一步，说明代理 + CA + 上游三者全对。** 剩下的只是微信那边。

### 6.2 第二步：让微信走代理

```powershell
# 完全退出微信（托盘图标也要退）
Get-Process WeChat, Weixin, WeChatAppEx, WeChatOCR -ErrorAction SilentlyContinue | Stop-Process -Force

# 重新启动
Start-Process "C:\Program Files\Tencent\WeChat\WeChat.exe"   # 路径按实际改
```

打开接龙小程序，点「获取定位」。mitmdump 应刷出一串 `/activity/*`。

### 6.3 第三步：开启改写

见 `README.md` §3.3。

---

## 7. 排障

| 现象 | 排查顺序 |
|---|---|
| mitmdump 完全没日志 | ① 代理注册表生效了吗（§4.2）② PAC 清了吗 ③ 微信重启了吗 |
| 只有浏览器流量，没有微信流量 | 微信可能走自己的网络栈；试 `--mode transparent` 或装 CA 到 `LocalMachine\Root` |
| `Client TLS handshake failed` | CA 没装对，或被证书固定挡住（见 §7.1） |
| 全部 `502 Bad Gateway` | 上游代理地址/端口错（§5.2） |
| `mitmproxy` 报 cert 解析失败 | 用 `.cer` 不用 `.pem`（§2） |
| 抓到了但 `body` 是乱码 | 请求体可能是 protobuf / gzip；看 `Content-Encoding` 头 |
| `curl` 能通、微信不通 | 微信读的是系统代理，`curl -x` 只影响自己 |
| 改了坐标没反应 | 命中的不是签到接口；对照 `docs/01` §3 的路径表 |

### 7.1 关于证书固定（certificate pinning）

目前**没有遇到**微信对 `jielong.huolieyun.com` 做证书固定——
抓包能正常拿到明文就是这个结论的证据。如果将来遇到：

- 现象是「请求发出去了，但服务端视图里没有」或「TLS 握手失败」；
- 处理方式是 Frida 侧 hook `SSL_write` / `SSL_get_verify_result`，
  但那属于 `docs/02` 的 WMPF 路线，成本高；
- 更简单的判断：先在浏览器里访问同一路径，能抓到就说明没有 pinning，问题在别处。

---

## 8. 收尾清单

抓完必须按顺序做，否则会留下全局代理和一根受信任的根证书：

```powershell
# 1. 关代理
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0

# 2. 停 mitmproxy
Get-Process mitmdump, mitmweb, mitmproxy -ErrorAction SilentlyContinue | Stop-Process -Force

# 3. 删受信任根证书
Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -like "*mitmproxy*" } | Remove-Item

# 4. 确认 sign_body_*.json 没有留在仓库里
Get-ChildItem -Recurse -Filter "sign_body_*.json" | Select-Object FullName
#   ↑ 有的话移到仓库外，或直接删掉；不要 git add

# 5. 重启微信，恢复正常网络
```

> **最后一条最重要**：`sign_body_*.json` 里是完整凭据。
> 它的存在本身就是一个风险点，抓完就该清。
