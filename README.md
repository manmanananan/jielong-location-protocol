# 接龙（jielong）定位签到：CDP 注入（已成功）+ 反代改写探索（已证伪）

> **最终结论先说**：这条路走通了，走通的是 **CDP 注入到小程序逻辑层改表单字段**，
> 不是 mitmproxy 反向代理。
>
> 反代那条路被**证伪**了（域名级代理豁免，见 `docs/07`），
> 但它的失败过程留在这里——**「为什么抓不到包」本身就是有价值的负结果**，
> 它解释了为什么最终要绕到客户端注入。

---

## 0. 安全纪律（先读这段）

**本仓库只包含工具与协议分析，不包含任何真实凭据。**

- 仓库里**没有**真实 `token`、`cookie`、手机号、姓名、签到记录、活动 ID。
  文档中出现的鉴权值一律写成 `<TOKEN>` / `<COOKIE>` 占位，
  目标坐标一律写成 `<TARGET_LAT>` / `<TARGET_LON>`。
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

本仓库记录了一次完整的尝试，最终有**一条成功路径**和**一条证伪路径**：

| 路线 | 状态 | 在哪 |
|---|---|---|
| **CDP 注入逻辑层改表单** | ✅ **已成功**（服务端落库，三重证据） | `docs/06` |
| mitmproxy 反代改写请求体 | ❌ **已证伪**（域名级代理豁免） | `docs/07` + `src/jl_addon.py` |
| 系统级模拟定位 | ❌ 已排除 | `docs/02` §1 |
| 改小程序包 / patch JS | ❌ 已排除 | `docs/02` §5 |

**主路径是 CDP 注入**。反代那套工具（`src/jl_addon.py`、`scripts/setup.ps1`）
保留在仓库里，但**它不是解法**，是失败过程的产物。
保留原因写在 `docs/07` 末尾：它证明了「流量根本到不了代理」，这个结论比工具本身有用。

**它不是什么**：不改小程序包、不伪造 GPS、不动系统定位、不需要 root 或越狱。

### 1.1 成功证据（三重）

| # | 证据 | 位置 |
|---|---|---|
| 1 | 小程序「接龙成功」页面 | 仓库外 `D:\deepseek\jielong\` 下的成功页截图 |
| 2 | 完成情况计数 `52/57` → `53/57`，目标项打勾，按钮变「已接龙」 | 同上，列表页截图 |
| 3 | CDP 读逻辑层列表数据，`hasMe: true` | 同上，`cdp_verify.js` |

> 这三份证据都在仓库外（`D:\deepseek\jielong\` 根目录，主线在用），
> **不随仓库分发**——它们含真实姓名、课程名与活动信息。
> 仓库里只记录**结论与计数变化**，不留原始截图。


---

## 2. 原理

### 2.1 校验发生在 JS，提交也由 JS 发起

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

所以**服务端能看到的只有这组数字**。

### 2.2 两条改法，一条通一条不通

既然「服务端只认这组数字」，那就有两个位置可以动手：

| 位置 | 做法 | 结果 |
|---|---|---|
| **离开设备之后**（HTTP 层） | 代理抓包、改写请求体 | ❌ **不通**：流量根本不走代理，见 §2.3 |
| **离开设备之前**（JS 层） | CDP 注入，直接 `setData` 写表单字段 | ✅ **通**：等价于用户自己选点，见 `docs/06` |

本仓库最初赌的是第一条（理由：客户端零改动、不怕更新），
实测发现第一条从根上不成立——**不是「改了没用」，是「压根抓不到」**。

于是回到第二条，它一次就成功了。

> 教训：选方案时，「理论上更优雅」不能替代「先验证链路是否可达」。
> 我们花了整晚把代理链路、CA、证书固定全部排查完，
> 最后发现问题根本不是这些——是**这个域名被豁免了**（§2.3）。

### 2.3 反代为什么失败：域名级代理豁免

这是本项目最重要的负结果，单独说清楚。

**曾经确认成立的部分**：WMPF 确实走系统代理。抓包可见
`servicewechat.com` / `wxs.qq.com` / `apis.map.qq.com` 全部以
`CONNECT [pass]` 经过 8899 端口——**说明代理配置本身是对的，CA 也是对的。**

**关键发现**：在同一时间窗内（25 秒），`jielong.huolieyun.com`
（`39.104.28.144:443`）出现了 **54 条直连连接**，一条都没经过代理。
同时核查 `WeChatAppEx.exe` 的全部 Established 连接：
**6 条全指向 8899，非 8899 的为 0 条。**

两条数据放在一起，结论只能是：

> **微信对 `jielong.huolieyun.com` 做了域名级代理豁免**——
> 这个域名的流量绕开 WinINET 设置，直接建 TCP 连接。

**这个精度很重要，别写成别的**：

| 错误说法 | 为什么错 |
|---|---|
| 「WMPF 不读 WinINET 代理」 | ❌ 错。它读了——`servicewechat.com` 就是走代理的 |
| 「mitmproxy 没配对」 | ❌ 错。配置对，别的域名都抓到了 |
| 「有证书固定」 | ❌ 错。是**根本没到 TLS 阶段**，连握手都没发生 |
| **「特定域名绕过代理直连」** | ✅ 对。有 54:0 的直连/代理比值作证 |

所以这不是「反代改包被服务端拒绝」，而是**反代的输入端就是空的**：
addon 永远收不到这个域名的请求，`JL_REWRITE=1` 自然毫无作用。

> 完整的排查过程（含怎么发现的、试过哪些错方向）见 `docs/07`。

### 2.4 最终路径：CDP 注入

```
微信小程序 (WMPF/CEF, Chromium 132)
   │
   ├─ 渲染层 context   (有 window / Component，没有 getCurrentPages)
   └─ 逻辑层 context   (有 getCurrentPages / Page / App，没有 window)  ← 目标
                          │
                          │  Runtime.evaluate
                          ▼
                    page.setData({
                      "form[i].value":        "<TARGET_NAME>",
                      "form[i].showText":     true,
                      "form[i].locationData": { name, address, latitude, longitude }
                    })
                          │
                          │  等价于 applyPickedLocation() 的产物
                          ▼
                    page.submit()  →  服务端落库 → 「接龙成功」
```

**这条路径完全绕开 HTTP 层**，因此：

- 不需要 token、不需要抓包、不需要装 CA、不需要改系统代理；
- 坐标从 `form[i].location[0]` 里**读**，不是自己编（见 `docs/06` §4）。

详细步骤、启动顺序、踩坑表在 `docs/06-cdp-injection.md`。

---

## 3. 怎么用

本仓库现在有**两套**东西，请按目的选：

| 你想做的事 | 去哪 |
|---|---|
| **实际完成一次签到** | `docs/06-cdp-injection.md`（CDP 注入，唯一验证成功的方法） |
| 理解「为什么抓不到包」 | `docs/07-why-mitm-failed.md` |
| 亲手复现那个结论 | 本文下面 §3.2 的代理流程 |

### 3.1 环境

| 项 | 版本 / 路径（实测） |
|---|---|
| 系统 | Windows 10/11 |
| PC 微信 | 4.2.0.53（4.x 均可） |
| 小程序 | 接龙 `wxdbe4c8e7bc3fb688` |
| 调试器 | [WMPFDebugger](https://github.com/evi0s/WMPFDebugger)，需含 `addresses.26134.json` |
| Node | 18+（跑 CDP 脚本用） |
| mitmproxy | 仅反代探索需要：`uv tool install mitmproxy` |

> **WMPFDebugger 的版本地址表是关键**：它靠 `addresses.<版本号>.json`
> 定位微信内部函数。本机 WMPF 是 `26134`，表里必须有这个文件。
> 缺了就跑不起来，微信一升级就要等社区补表——这是这条路线的主要维护成本。

### 3.2 反代流程（仅用于复现负结果）

> 这一节**不会帮你签到**。它的价值是让你亲眼看到「请求不经过代理」。

一键装 + 起代理 + 装 CA：

```powershell
pwsh -File scripts\setup.ps1 -Port 8899
```

参数化说明见 `scripts/setup.ps1` 头部注释（`-Port` / `-OutDir` / `-SkipCa`）。

#### 只观察

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
> `access-token` / `jielong-token`），哪个变成 `yes(N)` 就说明是它。
> 不过——**这条线索后来没用了**，因为 CDP 路线不需要 token。

> **⚠️ 关键**：如果你在真机上跑这一节，会发现**签到那一下没有日志**。
> 那不是你配错了，是 §2.3 说的域名豁免。
> 判断方法：同时抓 `servicewechat.com` 有日志、`jielong` 没有 → 就是豁免。

参数化说明见 `scripts/setup.ps1` 头部注释（`-Port` / `-OutDir` / `-SkipCa`）。

#### 改写（无效，仅作演示）

```powershell
$env:JL_REWRITE="1"
$env:JL_LAT="<TARGET_LAT>"
$env:JL_LON="<TARGET_LON>"
$env:JL_NAME="<PLACE_NAME>"
$env:JL_ADDR="<PLACE_ADDRESS>"
mitmdump -s src\jl_addon.py --listen-port 8899
```

**这段设置不会有任何效果**——因为请求压根不会到达 addon。
留着它是为了说明：addon 的改写逻辑本身是对的（有单测，见 `docs/04` §1.2），
**卡点在链路，不在代码**。这个区分很重要，否则会一直在改 addon 上浪费时间。

### 3.3 环境变量全表

| 变量 | 默认 | 作用 |
|---|---|---|
| `JL_HOST` | `jielong.huolieyun.com` | 目标域名，换小程序时改这里 |
| `JL_REWRITE` | `0` | `1` = 开启坐标改写（本路线已证伪，仅演示） |
| `JL_LAT` / `JL_LON` | 无（默认 `0.0`） | 目标坐标，**必须显式提供** |
| `JL_NAME` / `JL_ADDR` | `<PLACE_NAME>` / `<PLACE_ADDRESS>` | 目标地点名与地址 |
| `JL_OUT` | `.\mitm-out` | 日志与 `sign_body_*.json` 的落盘目录 |
| `JL_MASK_AUTH` | `1` | `0` = 日志里打印鉴权头明文（仅本机排障） |

> **坐标没有默认值**：仓库里不留任何真实坐标。
> 若 `JL_REWRITE=1` 却没设 `JL_LAT`/`JL_LON`，addon 会打印警告并改写为 `(0,0)`；
> 如果设了非法值（比如直接粘了占位符 `<TARGET_LAT>`），会**立刻报错退出**，
> 而不是静默改成一个错坐标。

---

## 4. 仓库结构

```
repo/
├── README.md                     ← 你在这里
├── .gitignore                    ← 排除 sign_body_*.json / mitm/ / *.log 等凭据文件
├── .gitattributes                ← 固定换行，避免 CRLF 噪声
├── docs/
│   ├── 06-cdp-injection.md       ★ 主路径：CDP 注入，已成功，含踩坑表
│   ├── 07-why-mitm-failed.md     ★ 负结果：域名级代理豁免，反代为何证伪
│   ├── 01-jielong-api.md         ← 接口清单、探测记录、status 字段语义
│   ├── 02-why-not-system-gps.md  ← 系统级模拟为何无效；为何不改客户端
│   ├── 03-mitm-setup.md          ← mitmproxy 安装 / CA / 系统代理（复现负结果用）
│   ├── 04-roadmap.md             ← 已验证 vs 遗留问题（U1–U6 已归档）
│   └── 05-fallback-tool.md       ← 【大纲】桌面定位工具兜底路线
├── examples/
│   └── quickstart.md             ← 三分钟看懂接口：curl 实测基准 + 实测/推测对照
├── src/
│   └── jl_addon.py               ← mitmproxy addon（已证伪路线的产物，代码本身有单测）
└── scripts/
    └── setup.ps1                 ← 一键装 mitmproxy、起代理、装 CA
```

> 阅读顺序建议：**`docs/06` → `docs/07` → 其余**。
> 06 是结论，07 是「为什么另一条路不行」。其余是过程材料。

---

## 5. 已验证到什么程度

> 这一节只放**实测过**的。U 系列已归档（见 `docs/04` §二）。

### 5.1 主路径（CDP 注入）

| 能力 | 状态 |
|---|---|
| **CDP 注入后服务端落库，小程序显示「接龙成功」** | ✅ **已成功**（截图 + 计数变化 + CDP 读回） |
| 完成计数从 `52/57` 变为 `53/57` | ✅ 已验证（`verify1.png`） |
| 目标项打勾、按钮变「已接龙」 | ✅ 已验证（同上） |
| `page.submit()` 与手动点按钮两条都通 | ✅ 已验证 |
| 启动顺序反了会导致 hook 不生效 | ✅ 已验证（试了 5 次） |
| `--watch` 会因 9421 占用反复退出 | ✅ 已验证（源码注释亦证实） |

### 5.2 负结果（反代）

| 能力 | 状态 |
|---|---|
| WMPF 走系统代理（`servicewechat.com` 等 `CONNECT [pass]`） | ✅ 已验证 |
| **`jielong.huolieyun.com` 被域名级豁免，直连不走代理** | ✅ **已验证并证伪该路线** |
| 25 秒内 54 条直连 + WeChatAppEx 6 条 Established 全指向 8899 | ✅ 实测数据 |

### 5.3 遗留（已不影响结论）

| 事项 | 状态 |
|---|---|
| U1 token 来源 | ⬜ **已归档**——CDP 路线不需要 token |
| U2–U6 鉴权细节 | ⬜ **已归档**——同上 |
| addon 改写逻辑本身正确 | ✅ 有单测（`docs/04` §1.2），但用不上 |

> **这些不是「项目缺口」，是「放弃路线上的未完成项」。**
> 别把 U1 当成待办——那条路已经不走。

---

## 6. 踩坑速查

### 6.1 CDP 注入（主路径）

| 现象 | 原因 / 处理 |
|---|---|
| **hook 完全不生效，CDP 连上但读不到小程序** | **启动顺序反了**：必须先起 WMPFDebugger、等 `[frida] script loaded, WMPF version: 26134, pid: NNNN` 出现，**再**打开小程序 |
| 调试器反复退出，报 `EADDRINUSE 9421` | 加了 `--watch`。**不要加**——watch 会 detach 刚建立的连接（源码 `index.ts:366` 注释原话） |
| `Target.getTargets` 里找不到小程序 | 小程序还没打开，或 AppID 匹配写错 |
| 找到 target 但 `Runtime.evaluate` 报 `window is not defined` | attach 到了渲染层。逻辑层判定：`typeof getCurrentPages === "function"` 且 `typeof window === "undefined"` |
| 逐个 context evaluate 全都不是 `function` | 等 2 秒再收 `executionContextCreated` 事件；`Runtime.enable` 必须在 attach **之后** |
| `form` 索引写错，改了没反应 | **不要猜索引**，先 dump：`getCurrentPages()[1].data.form.forEach((f,i)=>console.log(i,f.type,f.title))`，`type===7` 才是定位字段 |
| 改了字段但提交后被拒 | 坐标没同步改 `name`/`address`，或坐标是编的。**坐标要从 `form[i].location[0]` 读，不要自己编** |
| WMPF 进程在但不起作用 | **僵尸壳**：`ThreadCount=0` 的 `WeChatAppEx.exe` 会让微信以为宿主还在，不再 spawn 新的。必须杀掉 |

### 6.2 环境 / 系统层

| 现象 | 原因 / 处理 |
|---|---|
| `certutil -addstore` / `X509Store.Add()` **卡死不动** | `#32770`「安全警告」模态框在等点按钮。**按钮是 Pane 不是 Button**，UIAutomation 的 `ClickablePoint` / `InvokePattern` 全废。用 **Alt+Y** 打掉 |
| 杀光微信后重开，怕要手机扫码 | **不需要**。约 30 秒恢复，出现本地账号选择页，点「进入微信」即可 |
| `mitmdump` 报证书 `pem` 解析失败 | mitmproxy 8+ 不再用 `.pem`，改用 `mitmproxy-ca-cert.cer` |

### 6.3 反代探索期（已证伪，仅供对照）

| 现象 | 原因 / 处理 |
|---|---|
| **其它域名有日志，签到那一下没有** | 这就是**域名豁免**（`docs/07`）。不是配置问题 |
| 终端一条日志都没有 | 系统代理没生效，或走了 PAC；看 `docs/03` |
| 改写了但返回还是「您还未到定位地点」 | 那是**前端**弹的，说明请求根本没发出去 |
| `sign_body_*.json` 一堆但没内容 | 命中了探测请求；真正的签到体在 `POST /activity/sign` |
| 同一次签到落了多个 `sign_body_*.json` | 正常——前端会重试，addon 用 `_1`/`_2` 后缀区分 |


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
