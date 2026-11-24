# 接龙（jielong）定位签到：接口逆向与反代改写

> 一个 mitmproxy addon + 一份协议分析笔记。目标是把微信小程序「接龙」的定位签到
> 从「改设备定位」这条死路上挪开，改成在 HTTP 层改写请求体里的定位字段。

---

## 0. 安全纪律（先读这段）

**本仓库只包含工具与协议分析，不包含任何真实凭据。**

- 仓库里**没有**真实 `token`、`cookie`、手机号、姓名、签到记录、活动 ID。
  文档中出现的鉴权值一律写成 `<TOKEN>` / `<COOKIE>` 占位。
- `sign_body_*.json` 是 addon 抓下来的完整签到请求，**头部带 Authorization/token，
  体内带手机号与真实姓名**，属于敏感数据。它已被 `.gitignore` 排除（`sign_body_*.json`、
  `sign_body_*`），并且默认写到仓库外的 `mitm-out/` 目录。
- 如果你 fork 之后跑出了 `sign_body_*.json`，**不要 `git add -f`，不要贴进 issue，
  不要发到群里**。它等价于把你的账号交出去。
- 日志默认对鉴权头脱敏（只记「有/无」与长度）。要看明文得自己设 `JL_MASK_AUTH=0`，
  且只在本机看。
- 抓包只应针对**你自己有权限的账号与活动**。把它用在别人的接龙上，后果自负。

---

## 1. 这是什么

微信小程序「接龙」（AppID `wxdbe4c8e7bc3fb688`，接口域名 `jielong.huolieyun.com`）
的定位签到，要求用户处在创建人设定的地点范围内（`range`，常见 50 米）才能提交。

本仓库做两件事：

1. **协议分析**：把这个小程序的接口清单、鉴权方式、返回码语义摸清楚（`docs/01`）。
2. **工具**：用一个 mitmproxy addon 在反向代理层递归改写请求体中的
   `latitude` / `longitude` / `name` / `address` 字段（`src/jl_addon.py`）。

**它不是什么**：不是外挂、不改小程序包、不注入 JS、不动系统定位、不需要 root 或越狱。

---

## 2. 原理

### 2.1 校验发生在 JS，提交发生在 HTTP

反编译 `chunk_0.appservice.js` 后能直接读到校验逻辑（原文见 `docs/02` 的摘录）：

```js
// 逻辑层：定位合规性判断
o = await wx.getLocation({type:"gcj02", isHighAccuracy:true, highAccuracyExpireTime:5000})
c = o.latitude; s = o.longitude

if (2 == i.limit) {                              // limit=2 → 指定地点模式
  u = normalizeLocations(i.location, i.range)
  for (g of u) {
    d = getDistance(c, s, g.latitude, g.longitude)   // 球面距离，半径 6371e3
    if (d <= +(g.range || 500)) { l = true; break }
  }
  if (!l) {
    wx.showModal({title:"您还未到定位地点", ...})   // 卡这里
    return
  }
}
// 通过后 → navigateTo locationPicker → 用户选点 → applyPickedLocation()
// → triggerEvent("change", {value, locationData:{name,address,latitude,longitude}})
```

关键点在最后一行：**校验通过之后，真正被写进表单、随后被提交的，
是一组普通 JSON 字段，不是 GPS 读数。**

```
applyPickedLocation(e) {
  var t = e.location || {}
  var n = e.fullAddress || e.name || e.title || e.address || ""
  this.triggerEvent("change", {
    value: n,
    locationData: {
      name:     e.name || e.title || n,
      address:  e.detailAddress || e.address || e.fullAddress || "",
      latitude: t.lat,
      longitude: t.lng
    }
  })
}
```

所以**服务端能看到的只有这组数字**。在它们离开设备之前把值换掉，
在语义上就等于「用户自己在地图上选中了那个点」，前端一行代码都不用改。

### 2.2 为什么不在 JS 层改（这是上一版方案）

上一版走 WMPFDebugger + CDP + `page.setData()`，能成功，但代价高：
要 patch 微信客户端、要维护版本地址表、小程序一重载 patch 就丢。
完整复盘见 `docs/02-why-not-system-gps.md` 的「另一条路线」一节。

HTTP 层改写没有这些问题：进程重启即可复现，与微信版本无关，
与小程序版本无关（只要字段名不变）。

### 2.3 流量走向

```
微信小程序 (WMPF/CEF)
   │  https://jielong.huolieyun.com/activity/sign
   ▼
[系统代理 127.0.0.1:8899]      ← mitmproxy 在这里
   │  TLS 由 mitmproxy 用自签 CA 终止，明文交给 addon
   ▼
src/jl_addon.py  request(flow)
   │  JL_REWRITE=1 → 递归替换坐标字段 → 重新序列化回请求体
   ▼
[上游 jielong.huolieyun.com:443]   ← 真实服务端
   │
   ▼
response(flow) 打印 status + body 前 220 字符（判断是否被接受）
```

---

## 3. 怎么用

### 3.1 环境

| 项 | 版本 / 路径（实测） |
|---|---|
| 系统 | Windows 10/11 |
| Python | 3.10+（3.14 亦可） |
| mitmproxy | `uv tool install mitmproxy` 或 `pip install mitmproxy` |
| PC 微信 | 4.2.0.53（4.x 均可） |
| 小程序 | 接龙 `wxdbe4c8e7bc3fb688` |

一键装 + 起代理 + 装 CA：

```powershell
pwsh -File scripts\setup.ps1 -Port 8899
```

参数化说明见 `scripts/setup.ps1` 头部注释（`-Port` / `-OutDir` / `-SkipCa`）。

### 3.2 只观察（推荐第一步）

```powershell
mitmdump -s src\jl_addon.py --listen-port 8899
```

然后在微信里打开接龙，点一次「获取定位」。终端应出现：

```
[01:57:30] POST /activity/activityDetail Authorization=no(0) token=no(0) X-Token=no(0) ... len=2
[01:57:30]     body: {}
[01:57:30] <<< 200 /activity/activityDetail :: {"msg":"token为空","status":901}
```

看到 `status:901` 说明代理链路通了、域名命中了，只是这次请求没带鉴权
（小程序冷启动时的探测请求就是这样，正常）。**这一步不用改任何东西。**

> addon 会一次探多个候选头名（`Authorization` / `token` / `X-Token` /
> `access-token` / `jielong-token`），所以这条日志本身就在回答
> 「鉴权头到底叫什么」这个未解决项——见 `docs/04` 的 U2。

### 3.3 改写并签到

```powershell
$env:JL_REWRITE="1"
$env:JL_LAT="34.81605"
$env:JL_LON="113.53683"
$env:JL_NAME="<PLACE_NAME>"
$env:JL_ADDR="<PLACE_ADDRESS>"
mitmdump -s src\jl_addon.py --listen-port 8899
```

输出里出现这两行即代表改写生效：

```
[..] POST /activity/sign ... len=482
[..]     >>> REWRITTEN -> (34.81605, 113.53683) <PLACE_NAME>
[..] <<< 200 /activity/sign :: {"msg":"...","status":0}
```

`status:0` = 服务端接受。`status:901` = 还没带上 token（见 `docs/04` 的未解决项）。

### 3.4 环境变量全表

| 变量 | 默认 | 作用 |
|---|---|---|
| `JL_HOST` | `jielong.huolieyun.com` | 目标域名，换小程序时改这里 |
| `JL_REWRITE` | `0` | `1` = 开启坐标改写 |
| `JL_LAT` / `JL_LON` | `34.81605` / `113.53683` | 目标坐标（示例值） |
| `JL_NAME` / `JL_ADDR` | `<PLACE_NAME>` / `<PLACE_ADDRESS>` | 目标地点名与地址 |
| `JL_OUT` | `.\mitm-out` | 日志与 `sign_body_*.json` 的落盘目录 |
| `JL_MASK_AUTH` | `1` | `0` = 日志里打印鉴权头明文（仅本机排障） |

---

## 4. 仓库结构

```
repo/
├── README.md                     ← 你在这里
├── .gitignore                    ← 排除 sign_body_*.json / mitm/ / *.log 等凭据文件
├── src/
│   └── jl_addon.py               ← 核心：mitmproxy 抓包 + 递归改写定位字段
├── docs/
│   ├── 01-jielong-api.md         ← 接口清单、探测记录、返回码语义
│   ├── 02-why-not-system-gps.md  ← 为什么系统级模拟无效；WMPF 路线的复盘
│   ├── 03-mitm-setup.md          ← mitmproxy 安装 / CA / 系统代理 / 上游链路
│   └── 04-roadmap.md             ← 已验证 vs 待验证（含未解决项）
└── scripts/
    └── setup.ps1                 ← 一键装 mitmproxy、起代理、装 CA
```

---

## 5. 已验证到什么程度

| 能力 | 状态 |
|---|---|
| 抓到 `jielong.huolieyun.com` 明文请求 | ✅ 已验证 |
| 确认 `/activity/*` 系列路径存在、未鉴权返回 901 | ✅ 已验证 |
| 确认 `/v1/...` 前缀不存在（404） | ✅ 已验证 |
| 确认定位校验在 JS 层、提交体是普通 JSON 字段 | ✅ 已验证（反编译可读） |
| addon 能递归改写嵌套定位字段 | ✅ 已验证（单测，见 `docs/04` §1.2） |
| addon 不会把鉴权头写进日志 | ✅ 已验证（同上） |
| addon 不误改非定位字段 / 非 JSON 体 / GET 请求 | ✅ 已验证（同上） |
| 改写后服务端返回「接龙成功」 | ⚠️ 待验证（缺一次带鉴权的抓包） |
| **token 的来源与头名** | ❌ **未解决** |

最后一项是整个方案唯一的硬缺口，单列在 `docs/04-roadmap.md` 的 U1–U3。

---

## 6. 踩坑速查

| 现象 | 原因 / 处理 |
|---|---|
| 终端一条日志都没有 | 系统代理没生效，或走了 PAC；看 `docs/03` 的代理检查段 |
| 只有 `status:901` 没有别的请求 | 小程序没登录 / 冷启动探测；先在小程序里正常进入活动 |
| 出现 `TLS handshake failed` | CA 没装到「受信任的根证书颁发机构」，或被微信的证书固定挡住 |
| `mitmdump` 报证书 `pem` 解析失败 | mitmproxy 8+ 不再用 `.pem`，改用 `mitmproxy-ca-cert.cer` |
| 改写了但返回还是「您还未到定位地点」 | 这是**前端**弹的，说明请求根本没发出去；说明改写点选错了接口 |
| `sign_body_*.json` 一堆但没内容 | 命中了探测请求；真正的签到体在 `POST /activity/sign` |
| 同一次签到落了多个 `sign_body_*.json` | 正常——前端会重试，addon 用 `_1`/`_2` 后缀区分，不会互相覆盖 |
| 微信升级后抓不到 | PC 微信 4.x 的小程序容器会变，先确认域名还对不对 |
| 抓到了 `huolieyun.com` 但字段名不同 | 打印 `body` 前 400 字符，照着改 `src/jl_addon.py` 的 `*_KEYS` |

---

## 7. 免责声明

本项目是**协议分析与代理工具**，用于学习 HTTP 中间人、小程序接口结构与
前端校验的实现方式。

- 只应对**你自己的账号、你自己的接龙、或明确授权的测试环境**使用。
- 伪造签到数据可能违反活动规则、平台服务条款，情节严重时涉及法律问题；
  这部分风险由使用者承担，本仓库作者不承担任何责任。
- 仓库不含任何真实凭据，也不提供绕过他人账号鉴权的能力。
- 如果你在真实场景里需要「远程签到」，正确做法是向活动创建人说明情况，
  而不是改包。

---

## 8. 许可

MIT。转载或二次开发请保留本节的免责声明。
