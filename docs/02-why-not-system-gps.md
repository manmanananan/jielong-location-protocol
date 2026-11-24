# 02 · 为什么系统级模拟定位无效

> 这一篇是失败路径的记录。里面列的每一条都真的试过并失败了，
> 留在仓库里是为了让下一个人（包括三个月后的我）别再花一遍时间。

---

## 0. 一句话结论

**不要伪造 GPS，要改 JS 层的表单数据。**

小程序的定位校验跑在 JS 里，它自己算距离、自己决定放不放行。
在它下面（系统定位、fused provider、腾讯地图 SDK）做手脚，全部无效；
在它上面（`page.setData()` 直接写结果）做手脚，一次就通。

> **补充（项目最终结论）**：本文最初写的是「改 HTTP 请求」，
> 后来实测发现 HTTP 层走不通——`jielong.huolieyun.com` 被微信
> **域名级代理豁免**，请求根本不经过代理（详见 `docs/07`）。
> 最终成功的是**客户端 JS 层注入**（`docs/06`）。
>
> 但本文的核心判断依然成立：**问题不在 GPS 那一层**。
> 这一点从头到尾没变过。

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
| 8 | **`page.setData()` 直接写表单字段** | 逻辑层 | ✅ **成功（最终方案）** | 绕过整个校验流程，见 §4 与 `docs/06` |
| 9 | HTTP 层改写请求体坐标 | 网络 | ❌ **证伪** | 请求根本不经过代理（域名级豁免），见 `docs/07` |
| 10 | 改包 / patch 小程序 JS | 客户端代码 | ❌ 不可行 | 包加密（`V1MMWX`）解不开；即便解开也会被热更新覆盖，见 §5 |

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

## 4. 最终方案：WMPFDebugger + setData（✅ 已成功）

> **订正**：本节最初标题是「能跑，但不是首选」，当时判断它依赖微信版本、
> 维护成本高，所以优先去赌反代。反代证伪之后，这条路成了唯一可行解，
> **而且一次就跑通了**。
>
> 结论是对的（它确实能跑），但「不是首选」这个判断错了。
> 完整操作步骤见 `docs/06-cdp-injection.md`。

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
    latitude: <TARGET_LAT>, longitude: <TARGET_LON>
  }
});
```

### 4.2 当时为什么没选它（判断错了）

当时的对比表是这样的（**注意最后一列的前提后来被推翻了**）：

| 维度 | WMPFDebugger + setData | mitmproxy 改写（当时以为的更优解） |
|---|---|---|
| 依赖微信版本 | **强**，靠 `addresses.<ver>.json` | 无 |
| 微信升级后 | 大概率失效，等社区更新 | 不受影响 |
| 依赖小程序结构 | **强**，要 `form[i]` 下标、`type===7` | 弱，按字段名匹配 |
| 小程序重载后 | `setData` 是一次性的，要重跑 | 无状态 |
| 需要额外进程 | node + WMPFDebugger + CDP | 只要 mitmdump |
| 需要 patch 客户端 | **要**，frida 改内存 | 不要 |
| 可复现性 | 差，环境一变就废 | 好，一条命令 |

**这张表里的每一行都是对的。** 唯一的问题是：
它比较的是「两个都能用的方案」，而实际上**右列那个压根不能用**（见 `docs/07`）。

于是「维护成本高但能跑」赢了「优雅但不存在」。
这是本项目最大的判断失误——**在验证链路可达之前，就按优劣排序做选择**。

### 4.3 它确实有代价（这些坑是真的）

- **版本地址表**：靠 `addresses.<ver>.json` 找内部函数地址，
  版本号不在表里就直接失败。本机是 `26134`，必须有对应文件。
- **启动顺序**：必须先起调试器、等 `script loaded`、再开小程序。
  反过来 hook 完全不生效（试了 5 次才发现，见 `docs/06` §2）。
- **`--watch` 不能用**：会 detach 刚建立的连接。
- **`Runtime.enable` TIMEOUT**：attach 到 worker target 会超时，
  必须改用 `context.html` 的 iframe context。
- **`page.getLocation` 显示 `[native code]`**：被编译包装，读源码没用，只能读 `page.data`。
- **`wx.getConnectedWifi` fail**：PC 端没有 WiFi API。
- **`setData` 是一次性的**：小程序重载后要重新执行。

**这些代价是真实的，不是借口。** 但在「唯一可行」面前，它们必须被接受。

### 4.4 它还有独立价值

除了签到本身，这条路径还能：

- **读**前端状态（`page.data.form` 的真实结构）——反推请求体字段名的唯一手段；
- 确认某个弹窗是**前端**弹的还是**服务端**返回的——排障的关键分叉；
- 用 `Debugger.getScriptSource` 把 `chunk_0.appservice.js` 捞下来做静态分析
  ——`docs/01` §5 的校验逻辑就是这么来的。

> 也就是说：**即使不签到，这个工具也值得装。**

---

## 5. 为什么不直接改客户端

上一节讲的是「用调试器在运行时改」。还有一个更直觉的做法：
**把小程序包下下来，解开，改 JS，再塞回去。**

这是最容易被提出来的方案，也是最容易白干一整天的方案。三条理由，逐条说。

### 5.1 包是加密的：解包这一步就过不去

实测：PC 微信 4.x 的小程序包，文件头是：

```
56 31 4D 4D 57 58        →  "V1MMWX"
```

标准 `wxapkg` 的结构是「1 字节标记 + 4 字节信息 + 4 字节索引长度 + 索引 + 数据」，
按这个结构写的解包脚本能直接跑通常见的小程序。

但接龙这个包**跑不通**：读出来的文件名是乱码、偏移全是错的、
按偏移切出来的「文件」没有一个能识别。

原因是微信从某个版本起给 `.wxapkg` 整体做了加密，`V1MMWX` 就是加密包的标识
（相对明文包的 `0xBE` 标记）。**解开它需要一个我们目前没有的密钥/算法。**

> 所以「改 JS」这条路，第一步就卡住了。
> 这也是为什么本仓库的 `docs/01` 里，逻辑层源码是**运行时**通过
> `Debugger.getScriptSource` 捞出来的（`chunk_0.appservice.js`，约 316 KB），
> 而不是解包得到的——绕过了加密，但那只能**读**，不能**改回去**。

### 5.2 就算解开了，改完也活不过下一次启动

假设跨过了 5.1（找到解密方式，或者用别的手段替换了包），仍然有四道关：

| 关卡 | 具体表现 |
|---|---|
| 完整性校验 | 小程序包带校验信息，改动后启动时校验失败，走「重新下载」分支 |
| 服务端热更新 | 小程序不是「装一次用一年」的 App，每次启动都会向 `servicewechat.com` 比对版本；本地改过的包版本号对不上就被覆盖 |
| CDN 分发 | 包体来自 CDN，本地文件只是一个缓存副本，清缓存/换设备即失效 |
| 多端不一致 | 手机端、PC 端各自拉包，改了一台不影响另一台 |

关键点在于：**小程序的「安装包」不是权威副本，服务端才是。**
这跟改 Android APK 的处境完全不同——APK 装在本地就是权威的，
小程序每次冷启动都可能被拉回服务端的版本。

### 5.3 这条对比表里，曾经被高亮的那一行是错的

当时做的对比（**注意最后一行**）：

| 方案 | 改什么 | 客户端改动 | 微信升级后 | 小程序更新后 | 换设备 |
|---|---|---|---|---|---|
| 系统定位模拟 | 设备定位源 | 无 | 依旧无效（见 §1） | — | 要重配 |
| 改包 / patch JS | 客户端代码 | **要** | 大概率失效 | **立即失效** | 要重做 |
| 运行时调试器 | 客户端内存 | 要（挂调试器） | 依赖版本地址表 | 需重跑 | 要重做 |
| ~~反代改写~~ | ~~传输层字节~~ | ~~无~~ | ~~不受影响~~ | ~~不受影响~~ | ~~可复用~~ |

**最后那一行在纸面上完美，在现实中不存在。**

反代的推理是这样的：它不关心客户端长什么样，只关心
「离开设备的那个 JSON 里坐标字段叫什么」——而字段名是协议里最稳定的部分。
**这个推理本身没有错**，错的是隐含前提：**那个 JSON 会经过我们**。

它不经过（`docs/07`）。所以「最稳定」这个优点一分都没兑现。

### 5.4 真正该记的教训

这一节原本的结论是「改客户端是一次性的，反代是可持续的」。
现在要改成：

> **可持续的前提是「能介入」。介入不了，可持续性等于零。**

选方案时的正确顺序是：

```
① 先验证「这个位置我够得到吗」（链路可达性）
② 再比较「够得到的那几个里面谁更优雅」
```

我们做反了：先比优雅，再去验证，结果优雅的那个够不到。

这不是「反代不好」，是**顺序错了**。同样的错误换个场景还会犯，
所以把它写成流程而不是感慨。

---

## 6. 为什么「改结果」比「改输入」有效

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
- 所以**在提交之前**把这四个数字改掉，语义上完全等价于「用户自己选中了那个点」。

这就是 `page.setData()` 生效的原因：它直接改「结果」。
而 §3 的 patch 失败，是因为它改的是「输入」——校验前改，会被后续跳转重新取值冲掉。

> **改结果永远比改输入省事。** 这句话在两个层面都成立：
> JS 层（setData vs patch getLocation）、以及本项目层面（CDP vs 反代）。

---

## 7. 层级对照图

```
┌─────────────────────────────────────────────────────┐
│ 小程序 JS（AppService）                              │
│   wx.getLocation → getDistance → showModal          │  ← ① patch 这里：能生效但被跳转吃掉
│   校验通过 → applyPickedLocation → locationData     │  ← ② ✅ setData 这里：最终成功
└─────────────────────────────────────────────────────┘
                        │ HTTPS
                        ▼
┌─────────────────────────────────────────────────────┐
│ jielong.huolieyun.com/activity/sign                 │  ← ③ ❌ mitmproxy 改这里：抓不到，域名豁免
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

## 8. 踩坑速查

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

## 9. 收尾注意（如果动过系统设置）

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

## 10. 一句话总结

> 在错误的层上努力，会得到「看起来生效了但结果不对」这种最贵的失败。

补一句本项目最终学到的：

> **比「选错层」更贵的是「没先确认那一层够不够得到」。**
> 系统定位够不到（腾讯 SDK 自采集）；HTTP 层也够不到（域名豁免）；
> 只有 JS 层够得到——因为它就在我们能注入的那个进程里。

