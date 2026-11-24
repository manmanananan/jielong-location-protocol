# 02 · 为什么系统级模拟定位无效

> 这一篇是失败路径的记录。里面列的每一条都真的试过并失败了，
> 留在仓库里是为了让下一个人（包括三个月后的我）别再花一遍时间。

---

## 0. 一句话结论

**不要伪造 GPS，要改 HTTP 请求。**

小程序的定位校验跑在 JS 里，它自己算距离、自己决定放不放行。
在它下面（系统定位、fused provider、腾讯地图 SDK）做手脚，全部无效；
在它上面（请求体）做手脚，一次就通。

---

## 1. 失败的方案全表

> 验证环境：Windows 10 + PC 微信 4.2.0.53；安卓侧参考同版本微信。
> 判定标准：小程序「获取定位」是否返回目标坐标。

| # | 方案 | 层级 | 结果 | 原因 |
|---|---|---|---|---|
| 1 | 安卓模拟定位 App（FakeTraveler / MockLock / GeoJoystick） | App | ❌ 全部无效 | 小程序不走 `LocationManager`，压根不读 mock provider |
| 2 | `adb shell cmd location` 设测试 provider | 系统 | ❌ 无效 | 同上 |
| 3 | `appops set com.tencent.mm FINE_LOCATION ignore` | 系统 | ❌ 无效 | 微信有自采集通道，权限被拒也照样返回真实位置 |
| 4 | Windows「默认位置」注册表 `DefaultLocation` | 系统 | ❌ 无效 | WMPF 不读 WinRT 定位 API |
| 5 | Frida hook WinRT `Geolocator` | 运行时 | ❌ 零命中 | 定位来自腾讯自己的桥接层，不经过 `Geolocator` |
| 6 | CDP `Emulation.setGeolocationOverride` | 浏览器 | ❌ 无效 | 只改 `navigator.geolocation`，`wx.getLocation` 走的是另一条原生通道 |
| 7 | patch `wx.getLocation` 返回值 | 逻辑层 | ⚠️ 部分成功 | 返回值确实变假了（调用栈可证），但**后续跳转把结果吃掉了**，见 §3 |
| 8 | `page.setData()` 直接写表单字段 | 逻辑层 | ✅ **成功** | 绕过了整个校验流程，见 §4 |
| 9 | **HTTP 层改写请求体坐标** | 网络 | ✅ **成功（本仓库方案）** | 服务端只认 JSON 里的数字，见 §5 |

---

## 2. 根因：定位来自腾讯地图 SDK，不在系统层

微信小程序（PC 端与安卓端行为一致）调用 `wx.getLocation` 之后，
底层走的是**腾讯地图定位 SDK**：

```
wx.getLocation({type:"gcj02", isHighAccuracy:true})
   │
   ▼
WMPF / WeChat 原生桥接
   │
   ▼
腾讯定位 SDK
   ├─ 采集 WiFi BSSID 列表
   ├─ 采集基站 CID / LAC
   ├─ 采集 GNSS
   └─ 打包上报腾讯服务器 → 服务端算位置 → 回传
   │
   ▼
返回 {latitude, longitude, accuracy, ...}
```

安卓侧对应的类是 `com.tencent.map.geolocation.sapp.TencentLocationManager`。

**关键点：位置是「算」出来的，不是「读」出来的。**
它把 WiFi/基站指纹发到腾讯服务器，服务器查库反算出坐标。
系统层的 mock provider 塞进去的是一个假坐标，但 SDK 根本不看这个 provider
——它自己采集、自己上报。这一层在外面，进不去。

### 2.1 叠加因素：fused provider 会剥离 mock

即使在某些机型上把 App 层的假位置塞进去了，还有第二道：

小米 HyperOS 的 fused provider（`com.xiaomi.metoknlp`）会**主动识别并剥离**
标记为 mock 的定位结果。所以哪怕伪造成功，到微信手里也已经是真实位置了。

这也是为什么「安卓模拟定位 App」这类工具在微信上从来不好使——
它们改的是 `LocationManager` 的 provider，而微信压根不读。

### 2.2 PC 端的特殊性

PC 微信的小程序跑在 WMPF（Chromium 132 / CEF）里，看起来像浏览器，
但它**不是**浏览器：

- 有 `window`、有 `document`、有 `navigator`，所以 `Emulation.setGeolocationOverride` 看起来该生效；
- 但 `wx.getLocation` 不走 `navigator.geolocation`，走的是 CEF 的原生 extension 桥，
  由 WMPF runtime 直接调腾讯的定位能力；
- 所以 override 改了 `navigator.geolocation`，对 `wx.getLocation` 一点影响都没有。

**Windows 的「默认位置」同理**：那是 WinRT `Geolocator` 的数据源，
WMPF 不读它。

---

## 3. 走过的弯路：patch `wx.getLocation` 为什么不够

反编译出来的校验代码是这样的（原文见 `docs/01` §5）：

```js
o = await wx.getLocation({type:"gcj02", isHighAccuracy:true})
c = o.latitude; s = o.longitude

if (2 == i.limit) {                    // 指定地点模式
  u = normalizeLocations(i.location, i.range)
  for (g of u) {
    if (await getDistance(c, s, g.latitude, g.longitude) <= +(g.range || 500)) {
      l = true; break                  // 在范围内 → 放行
    }
  }
  if (!l) { wx.showModal({title:"您还未到定位地点"}); return }
}

// 放行之后 ↓↓↓ 这里才是坑
wx.navigateTo({ url: "/pages/fullFormSub/locationPicker/index?lat=..&lng=.." })
// 用户在列表里选点 → eventChannel "locationSelected" → applyPickedLocation()
```

**坑在这里：校验通过之后，它会 `navigateTo` 跳到一个新的「定位选择页」，
那个页面会重新调一次 `wx.getLocation`。**

前一次 patch 的返回值到了新页面就失效了，所以现象是：

> 点一下「获取定位」→ loading 转一圈 → 然后什么都不发生。

不报错、不弹窗、页面不动。这是最迷惑人的一种失败。

> 反过来说，`wx.getLocation` 的 patch **其实是生效的**——
> 在 patch 里打 `new Error().stack` 能证明返回的是假坐标，调用栈也对。
> 它只是被后面的页面跳转流程吃掉了。这一点当时判断错了，浪费了不少时间。

---

## 4. 另一条路线：WMPFDebugger + setData（能跑，但不是首选）

上一版方案走的是这条路，**确实成功了**：定位字段校验通过、表单提交、
服务端返回「接龙成功」。

### 4.1 它怎么做的

PC 微信 4.x 的小程序跑在 WMPF 里，`WMPFDebugger` 通过 patch CDP 过滤器
强制打开 LanDebug 模式，把标准 CDP 协议暴露出来：

```
WeChatAppEx.exe (WMPF)
  └─ AppIndex 页面  https://servicewechat.com/<APPID>/<ver>/page-frame.html
       ├─ mainContext   iframe (context.html)   ← 渲染层
       ├─ appContext    iframe (context.html)   ← 渲染层
       └─ 逻辑层：window === undefined，但有 getCurrentPages / Page / App
```

判定逻辑层的标志：`typeof getCurrentPages === "function"` 且 `typeof window === "undefined"`。

拿到逻辑层 context 之后，绕过校验、直接写表单：

```js
var p = getCurrentPages()[1];        // pages/fullForm/index
var f = p.data.form;                 // 数组，type === 7 是定位字段
p.setData({
  ["form[" + i + "].value"]:        "<PLACE_NAME>",
  ["form[" + i + "].showText"]:     true,
  ["form[" + i + "].locationData"]: {
    name: "<PLACE_NAME>", address: "<PLACE_ADDRESS>",
    latitude: 34.81605, longitude: 113.53683
  }
});
```

### 4.2 为什么它不是首选

| 维度 | WMPFDebugger + setData | mitmproxy 改写（本仓库） |
|---|---|---|
| 依赖微信版本 | **强**，靠 `addresses.<ver>.json` 版本地址表定位内部函数 | 无 |
| 微信升级后 | 大概率失效，等社区更新 | 不受影响 |
| 依赖小程序结构 | **强**，要 `form[i]` 的下标、`type===7`、`locationData` 键名 | 弱，按字段名匹配 |
| 小程序重载后 | patch 全丢，`setData` 是一次性的，要重跑 | 无状态，一直有效 |
| 需要额外进程 | 要 node + WMPFDebugger + CDP 连接（debug 9421 → CDP 62000） | 只要 mitmdump |
| 需要 patch 客户端 | **要**，`frida/hook.js` 改内存 | 不要 |
| 失败时的表现 | 静默无反应，难判断卡在哪 | 日志逐条，能直接看到请求与响应 |
| 可复现性 | 差，环境一变就废 | 好，一条命令 |
| 单点可控性 | 只能改这一台 PC | 同一套 addon 可挂任意设备 |

再叠加几个具体的坑：

- **版本地址表**：`WMPFDebugger` 用 `addresses.<ver>.json` 找内部函数地址，
  微信一升级、版本号不在表里就直接失败。得先跑 `--auto-detect` 看能不能认出来。
- **`Runtime.enable` TIMEOUT**：attach 到 worker target 会超时，必须改用
  `context.html` 的 iframe context。
- **`page.getLocation` 显示 `[native code]`**：方法被编译包装，读源码没用，只能读 `page.data`。
- **`wx.getConnectedWifi` fail**：PC 端没有 WiFi API，靠 WiFi 辅助定位的路子走不通——
  这也从侧面印证了 §2 的结论：PC 端的小程序定位是另一条通道。

### 4.3 什么情况下还值得用它

- 需要**读**前端状态（比如 `page.data.form` 的真实结构，用来反推请求体字段名）；
- 需要确认某个弹窗是**前端**弹的还是**服务端**返回的（这是排障的关键分叉）；
- 需要 `Debugger.getScriptSource` 把 `chunk_0.appservice.js` 捞下来做静态分析
  ——本仓库 `docs/01` 的校验逻辑就是这么来的。

**但「日常签到」这件事，用它性价比很低。**

---

## 5. 为什么 HTTP 层改写是对的

回到 §3 那段代码的最后一行：

```js
applyPickedLocation(e) {
  this.triggerEvent("change", {
    value: n,
    locationData: { name: ..., address: ..., latitude: t.lat, longitude: t.lng }
  })
}
```

**服务端能看到的，只有 `locationData` 里的四个值。**

- 校验在客户端做（`getDistance` 是本地算的，不是服务端算的）；
- 提交时传的是普通 JSON 数字；
- 所以在这四个数字离开设备之前改掉，语义上完全等价于「用户自己选中了那个点」。

前端一行代码都不用动，因为它拿到的一直是「已经被选中」的状态。

这也解释了为什么 §3 的 patch 会失败而这条路能成功：
**patch 是在「校验前」改输入，setData/改包是在「校验后」改结果。**
改结果永远比改输入省事。

---

## 6. 层级对照图

```
┌─────────────────────────────────────────────────────┐
│ 小程序 JS（AppService）                              │
│   wx.getLocation → getDistance → showModal          │  ← ① patch 这里：能生效但被跳转吃掉
│   校验通过 → applyPickedLocation → locationData     │  ← ② setData 这里：能成功，但依赖微信版本
└─────────────────────────────────────────────────────┘
                        │ HTTPS
                        ▼
┌─────────────────────────────────────────────────────┐
│ jielong.huolieyun.com/activity/sign                 │  ← ③ mitmproxy 改这里：本仓库方案
└─────────────────────────────────────────────────────┘
                        ▲
                        │ 越往下越"底层"，越往下越没用
┌─────────────────────────────────────────────────────┐
│ WMPF 桥接 / 腾讯定位 SDK                              │  ← 全都没用（PC 端）
└─────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────┐
│ 系统定位服务（LocationManager / WinRT / fused）      │  ← 全都没用
└─────────────────────────────────────────────────────┘
```

---

## 7. 踩坑速查

| 现象 | 原因 |
|---|---|
| 点定位转一圈，什么都没发生 | 校验过了，但 `locationPicker` 新页面重新取位置，patch 丢了 |
| 弹「您还未到定位地点」 | 假坐标与目标的距离 > `range`（本例 50 米），或没进 `limit==2` 分支 |
| 报 `window is not defined` | 在逻辑层 context 里用了 `window`，改 `globalThis` |
| `Runtime.enable TIMEOUT` | attach 到了 worker target，改用 `context.html` 的 iframe context |
| `page.getLocation` 显示 `[native code]` | 被编译包装，读源码没用，改读 `page.data` |
| `wx.getConnectedWifi` fail | PC 端没有 WiFi API |
| 改了坐标但显示的地名不对 | 只改了 `latitude/longitude`，没同步改 `name`/`address`；前端还会调 `getLocation` 云函数反查 POI |
| 改写后服务端仍是「未到地点」 | 说明服务端有二次校验，或改写命中了错误的接口（见 `docs/04`） |

---

## 8. 收尾注意（如果动过系统设置）

这一版**没有**动系统定位，所以正常情况无需清理。但如果你沿着旧路线
改过注册表，务必按顺序还原——**并且注意：**

> **不要在动手之后才导备份。** 本次的 `lfsvc.reg` / `location.reg`
> 是**改完之后**导出的，里面本身就带着假坐标，回导等于又把假位置写回去。

需要检查的四个位置：

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location\DefaultLocation
HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration      (Latitude / Longitude)
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-...}  (DefaultLocationLat/Lon)
HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors             (DisableWindowsLocationProvider)
```

删策略键需要管理员权限。**备份必须在动手之前做。**

---

## 9. 一句话总结

> 在错误的层上努力，会得到「看起来生效了但结果不对」这种最贵的失败。
