# 01 · 接龙接口清单与探测记录

> 目标：小程序「接龙」，AppID `wxdbe4c8e7bc3fb688`，接口域名 `https://jielong.huolieyun.com`
> 记录时间：本次会话的代理实测 + 反编译静态分析
> 鉴权值在本文中一律写作 `<TOKEN>` / `<COOKIE>`，未记录任何真实值

---

## 1. 结论先行

1. 域名唯一：**`https://jielong.huolieyun.com`**（`huolieyun.com` = 火力云）。
   抓包与反编译里都没出现第二套业务域名。
2. 业务接口全在 **`/activity/*`** 下。`/v1/...` 前缀**不存在**（返回 404），
   说明这不是一套版本化 REST 网关，而是路径直挂的 PHP/Java 风格接口。
3. 未带鉴权时，`/activity/*` 统一返回：

   ```json
   {"msg":"token为空","status":901}
   ```

   `status:901` 是**本项目最重要的一个信号**：它同时证明了
   ① 路径存在、② 路由通、③ 鉴权在业务逻辑之前、④ 代理链路正确。
4. 鉴权走**请求头**，不走 query。但具体头名（`Authorization` 还是 `token`）
   **尚未确认** —— 见 `docs/04-roadmap.md` 的未解决项。
5. 小程序包是加密的（魔数 `V1MMWX`），`wxapkg` 直接解包**失败**。
   逻辑层源码只能通过运行时 CDP 的 `Debugger.getScriptSource` 拿到。

---

## 2. 环境事实

| 项 | 值 |
|---|---|
| 小程序 AppID | `wxdbe4c8e7bc3fb688`（接龙，版本号 v1185 量级） |
| 客户端 | PC 微信 4.x（实测 4.2.0.53 / Windows 10） |
| 容器 | WMPF：`WeChatAppEx.exe`，Chromium 132 / CEF |
| 逻辑层入口 | `https://servicewechat.com/<APPID>/<ver>/page-frame.html` |
| 逻辑层源码 | `chunk_0.appservice.js` ≈ 316 KB（`src_chunk_0_appservice_js_200.js`） |
| 包格式 | `.wxapkg`，魔数 `V1MMWX`（**加密，直接解包失败**） |
| 传输 | HTTPS，证书为服务端正式证书；mitmproxy 用自签 CA 终止 |

---

## 3. 接口清单

### 3.1 探针结果（未鉴权）

所有探针都是 `POST` + 空 JSON 体 `{}`，从代理层发出，不带任何登录态。

| # | 方法 | 路径 | 观察到的响应 | 判定 |
|---|---|---|---|---|
| 1 | POST | `/activity/activityDetail` | `{"msg":"token为空","status":901}` | ✅ 存在 |
| 2 | POST | `/activity/sign` | `{"msg":"token为空","status":901}` | ✅ 存在 |
| 3 | POST | `/activity/updateSignList` | `{"msg":"token为空","status":901}` | ✅ 存在 |
| 4 | POST | `/activity/getSignListMore` | `{"msg":"token为空","status":901}` | ✅ 存在 |
| 5 | POST | `/activity/delSignOrder` | `{"msg":"token为空","status":901}` | ✅ 存在 |
| 6 | POST | `/activity/signDel` | `{"msg":"token为空","status":901}` | ✅ 存在 |
| 7 | POST | `/v1/activity/activityDetail` 等 | `404` + `{"msg":"","status":0}` | ❌ 不存在 |

> 表 5、6 两个删除类接口是本轮顺手探到的，**不属于签到主链路**，
> 记录在此仅用于说明「`/activity/*` 是一个扁平命名空间，命名无统一规范」。
> 未对任何删除接口做写操作测试。

### 3.2 `status` 字段的真实语义（重要，别误读）

**`status:0` 不是成功码。** 这是本项目最容易踩的坑，单独列出。

实测 `status:0` 出现在四种互不相同的情形里：

| 请求 | HTTP | 响应体 | 实际含义 |
|---|---|---|---|
| `POST /activity/nonexistent` | **404** | `{"msg":"","status":0}` | 路由未命中 |
| `GET /` | 200 | `{"msg":null,"status":0}` | 根路径兜底 |
| `GET /activity/activityDetail` | 200 | `{"msg":"哎哟！出错啦！","status":0}` | 方法不对（该接口只收 POST） |
| —— | —— | `{"msg":"","status":0}` | `base.txt` 里的一条历史记录 |

四种情形唯一的共同点是：**它们都不是业务成功**。

结论：`status:0` 更像这个后端的**默认/未设置值**，而不是「成功」。
它和 `msg` 是解耦的——`msg` 里明明写着「出错啦」，`status` 依然是 0。

**所以不能用 `status:0` 判断签到是否成功。**

目前唯一能可靠判定的是 `status:901`（缺鉴权），因为它是**唯一一个
能被独立复现、且语义单一**的码。业务成功码要等 U1 解开后由真实抓包确定，
在那之前任何「`status:0` = 成功」的说法都是猜测。

### 3.3 `status:901` 当路径探针

`status:901` 一律在参数校验之前返回，说明服务端是「先查 token，再验参数」。
反过来利用这一点可以做**路径存在性探测**：

```
POST /activity/<随便什么>    → 若返回 901，路径存在
                             → 若返回 404，路径不存在
```

这条判据已验证（对照组：`/activity/nonexistentProbe123` 返回 404，
六条真实路径全部返回 901）。

> 注意探针要**同时看 HTTP 码和 body**：只看 body 会被 `status:0` 骗到，
> 只看 HTTP 码会漏掉「路径存在但方法不对」的情况。

这条判据在 `docs/04` 里被记为「已验证的探测手法」。

### 3.4 签到主链路（推测，待抓包确认）

```
① 进入活动   POST /activity/activityDetail   body: {} 或 {id}
                  ↓ 拿活动结构（含表单定义、定位限制 limit/range/location）
② 提交签到   POST /activity/sign             body: {活动ID, form:[...], ...}
                  ↓ 服务端校验 → 落库
③ 拉列表     POST /activity/getSignListMore  body: {活动ID, 分页参数}
④ 更新/改签  POST /activity/updateSignList
```

②的 body 是本仓库 addon 的主要改写目标。

---

## 4. 鉴权

### 4.1 已确认

- 鉴权信息在**请求头**里。抓包时 `/activity/activityDetail` 的
  `Authorization=no(0) token=no(0)`（addon 脱敏输出）对应服务端 `token为空`，
  说明头一旦缺失就是 901。
- 小程序用 `wx.cloud.callFunction` 走了一部分云函数
  （`daka` / `form` / `jielongAction` / `jielongRecord` / `getLocation`），
  这部分**不经过 `huolieyun.com`**，是腾讯云开发的独立通道。
  也就是说这个项目是**混合架构**：业务主链路走自建域名，辅助能力走云函数。

### 4.2 未确认（重要）

| 问题 | 现状 | 影响 |
|---|---|---|
| 头名到底是 `Authorization` 还是 `token` | **未确认** | 复现时需要逐个试 |
| 值的格式（`Bearer <TOKEN>`？裸 token？签名？） | **未确认** | 决定能否手工重放 |
| token 由哪个接口签发、有效期多久 | **未确认** | 决定脚本是否需要定时刷新 |
| 是否还有 `sign` / `timestamp` / `nonce` 等防重放头 | **未确认** | 若有，改写方案要连带处理签名 |

`src/jl_addon.py` 的 `_auth_state()` 一次探五个候选头名
（`Authorization` / `token` / `X-Token` / `access-token` / `jielong-token`），
并只输出 `yes(长度)` / `no(0)`。一旦主线抓到带鉴权的请求，
日志行会直接显示是哪一个头有值——**这就是 U2 的解法**，不需要事后猜。

---

## 5. 反编译得到的定位校验逻辑

从 `chunk_0.appservice.js` 里抠出来的原文（去掉 webpack 包装）：

```js
// ① 选点时的距离约束（limit=1：自由选点，限制离当前位置多远）
if (1 != r.limit) { ... }
c = await wx.getLocation({type:"gcj02", isHighAccuracy:!0, highAccuracyExpireTime:5e3})
if (await a.getDistance(c.latitude, c.longitude, i, o) > (r.distance || 500)) {
  wx.showModal({
    title: "温馨提示",
    content: "您不能选择距离「当前位置」太远的定位，请控制在「" + (r.distance||500) + "米」以内。",
    confirmText: "重新选择"
  })
}

// ② 提交时的范围校验（limit=2：指定地点）
c = o.latitude; s = o.longitude
if (2 == i.limit) {
  u = normalizeLocations(i.location, i.range)
  l = (0 === u.length)
  for (g of u) {
    if (await r.getDistance(c, s, g.latitude, g.longitude) <= +(g.range || 500)) {
      l = true; break
    }
  }
  if (!l) {
    wx.showModal({
      title: "您还未到定位地点",
      content: "创建人设置了需在「指定地点」才能定位，您还没到哦~若已到地点，请试试开 Wi-Fi定位。...",
      confirmText: "查看范围"
    })
    return
  }
}
```

距离算法是标准 haversine，地球半径 `6371e3` 米：

```js
getDistance: function(e, a, i, r) {           // (lat1, lon1, lat2, lon2)
  var R = 6371e3
  var o = e * Math.PI / 180, c = i * Math.PI / 180
  var s = (i - e) * Math.PI / 180, u = (r - a) * Math.PI / 180
  var l = Math.sin(s/2)**2 + Math.cos(o) * Math.cos(c) * Math.sin(u/2)**2
  return 2 * Math.atan2(Math.sqrt(l), Math.sqrt(1-l)) * R
}
```

两种限制模式：

| `limit` | 语义 | 校验 |
|---|---|---|
| `1` | 自由选点 | 距**当前位置**不超过 `distance`（默认 500 米） |
| `2` | 指定地点 | 距**任一指定点**不超过该点的 `range`（常见 50 米） |
| 其它 | 不限 | 直接放行 |

---

## 6. 请求体里的定位字段（改写目标）

`locationData` 是小程序表单层的标准字段名。反编译里 `applyPickedLocation` 的原文：

```js
applyPickedLocation: function(e) {
  if (e) {
    var t = e.location || {}
    var n = e.fullAddress || e.name || e.title || e.address || ""
    this.triggerEvent("change", {
      value: n,
      locationData: {
        name:      e.name || e.title || n,
        address:   e.detailAddress || e.address || e.fullAddress || "",
        latitude:  t.lat,
        longitude: t.lng
      }
    })
  }
}
```

注意这里有个**命名不一致**的坑：表单层叫 `latitude` / `longitude`，
但 `locationPicker` 传过来的是 `location.lat` / `location.lng`。
所以改写器必须两种都认（`src/jl_addon.py` 的 `LAT_KEYS` / `LON_KEYS`）。

实测出现过、需要覆盖的路径：

```
form[i].value                       "<PLACE_NAME>"  (字符串，等于 name)
form[i].showText                    true
form[i].locationData.name           <PLACE_NAME>
form[i].locationData.address        <PLACE_ADDRESS>
form[i].locationData.latitude       <TARGET_LAT>
form[i].locationData.longitude      <TARGET_LON>
item.location[0].lat / .lng         (locationPicker 侧)
clockLocationInfo.{lat,lng,...}     (打卡页)
```

---

## 7. 云函数面（不走域名，供参考）

反编译里出现的云函数与 action：

| 云函数 | action | 用途 |
|---|---|---|
| `daka` | `getDate` | 打卡日历（按年月拉打卡记录） |
| `form` | `getBukaNumber` | 报名/补卡数量统计 |
| `jielongAction` | `checkSeatStatus` | 座位占用检查 |
| `jielongRecord` | —（未取到 action 字面量） | 报名记录 |
| `getLocation` | — | **逆地理：传经纬度，返回 POI 名与地址** |

最后一行值得单独说：

```js
c = await wx.cloud.callFunction({name:"getLocation", data:{longitude:s, latitude:c}})
p = c.result
if (p && p.result && p.result.length > 0) {
  f = p.result[0]; x = f.title; m = f.address; w = f.location
  r.triggerEvent("change", {
    value: x,
    locationData: { longitude: w&&w.lng||s, latitude: w&&w.lat||c, address: m }
  })
}
```

**这意味着即使改了 `latitude`/`longitude`，如果 `name`/`address` 不同步改，
前端展示和服务端存的会是两套矛盾的数据。** addon 同时改四个字段就是这个原因。

---

## 8. 复现命令

```powershell
# 1. 起代理（只观察）
mitmdump -s src\jl_addon.py --listen-port 8899

# 2. 单条探针（验证路径是否存在）
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/sign" `
  -H "Content-Type: application/json" -d "{}"
# → {"msg":"token为空","status":901}

# 3. 带占位鉴权（等主线确认头名后替换）
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/sign" `
  -H "Content-Type: application/json" `
  -H "Authorization: <TOKEN>" `
  -d '{"id":"<ACTIVITY_ID>"}'
```

---

## 9. 待补的洞

- [ ] 鉴权的**头名**与**值格式**（`Authorization: Bearer <TOKEN>` / `token: <TOKEN>` / 其它）
- [ ] token 的签发接口与刷新时机
- [ ] 是否存在 `sign` / `timestamp` 类防重放参数
- [ ] `/activity/sign` 的完整请求体结构（需要一次真实抓包）
- [ ] 服务端是否**二次校验**坐标（例如与活动地点做距离比对）—— 目前只能确认它接受 JSON 里的坐标
- [ ] 小程序包 `V1MMWX` 的解密方式（目前绕开，走运行时拿源码）
