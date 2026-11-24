# 04 · 进度与待办

> 两栏制：左边是「已经能复现的」，右边是「还没搞定的」。
> 任何一条从右栏挪到左栏，都要附上**可复现的证据**（命令 + 输出），不接受「试了一下好像是」。

---

## 一、已验证

| # | 结论 | 证据 |
|---|---|---|
| 1 | 业务域名只有一个：`https://jielong.huolieyun.com` | 抓包 + 反编译均无第二套域名 |
| 2 | `/activity/*` 扁平命名空间存在，`/v1/...` 前缀返回 404 | 见下方 §1.1 的实测记录 |
| 3 | 未鉴权时 `/activity/*` 统一返回 `{"msg":"token为空","status":901}` | 同上 |
| 4 | 鉴权走**请求头**，不走 query | 无 query 也能触发 901；补齐头的路径见待办 #1 |
| 5 | `status:901` 在业务逻辑之前返回，可用于**路径存在性探测** | 存在路径返回 901，不存在返回 404 |
| 6 | 定位校验在**小程序 JS 层**完成，用 haversine 算距离 | `chunk_0.appservice.js` 可读原文，见 `docs/01` §5 |
| 7 | 校验通过后提交的是普通 JSON 字段 `locationData.{name,address,latitude,longitude}` | 反编译 `applyPickedLocation` 原文 |
| 8 | 存在两种限制模式：`limit=1` 自由选点（`distance` 默认 500m）、`limit=2` 指定地点（每点 `range`，常见 50m） | 同上 |
| 9 | 小程序包是加密的（魔数 `V1MMWX`），`wxapkg` 直接解包失败 | 解包脚本报错；改用运行时 `Debugger.getScriptSource` 取源码成功 |
| 10 | 前端还会调 `getLocation` 云函数做**逆地理**（传经纬度换 POI 名/地址） | 反编译原文；这就是 `name`/`address` 必须同步改的原因 |
| 11 | 系统级模拟定位（安卓 App / adb / WinRT / CDP override / fused）全部无效 | `docs/02` §1 的失败表 |
| 12 | `patch wx.getLocation` 返回值能生效，但会被后续 `navigateTo` 吃掉的 | 调用栈证明返回假坐标；现象是静默无反应 |
| 13 | WMPFDebugger + `setData` 路线可成功提交并返回「接龙成功」 | 上一版方案实测 |
| 14 | **addon 的递归改写逻辑正确** | 单测见 §1.2：覆盖 `locationData` / `location[].lat` / `clockLocationInfo` 三种嵌套 |
| 15 | **addon 不会泄漏鉴权头到日志** | 同上单测：五个候选头全部塞值，日志中检索明文命中数为 0 |
| 16 | 改写器的 `title` 只在定位上下文内生效，不污染表单字段标签 | 同上单测（这是踩过的坑，见 §1.3） |
| 17 | addon 一次检测五个候选鉴权头并脱敏输出 | 单测输出：`Authorization=yes(10) token=yes(10) X-Token=yes(3) access-token=no(0) jielong-token=no(0)` |
| 18 | 同秒内的多条签到请求不会互相覆盖 | 单测：连发 3 条同秒请求，落盘得到 3 个文件（`_1` / `_2` 后缀） |
| 19 | 非 JSON 体与 GET 请求原样透传，不被误改 | 单测：`a=1&b=2` 与 GET 体均保持不变 |

### 1.1 探针实测记录

```powershell
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/sign" `
  -H "Content-Type: application/json" -d "{}"
# {"msg":"token为空","status":901}

curl.exe -s -X POST "https://jielong.huolieyun.com/v1/activity/sign" `
  -H "Content-Type: application/json" -d "{}"
# 404
```

addon 侧同时可见：

```
[..] POST /activity/activityDetail Authorization=no(0) token=no(0) X-Token=no(0) ... len=2
[..]     body: {}
[..] <<< 200 /activity/activityDetail :: {"msg":"token为空","status":901}
```

日志行会同时报出五个候选鉴权头的存在性，这是 U2 的取证入口。

### 1.2 addon 单测（`src/jl_addon.py` 的 `_deep_rewrite`）

输入一个混合结构，期望：

| 路径 | 改写后 |
|---|---|
| `form[0].locationData.latitude` | `34.81605` |
| `form[0].locationData.longitude` | `113.53683` |
| `form[0].locationData.name` | `<PLACE_NAME>` |
| `form[0].locationData.address` | `<PLACE_ADDRESS>` |
| `form[0].title`（字段标签「定位」） | **不变** |
| `form[1].value`（姓名等非定位字段） | **不变** |
| `item.location[0].lat` / `.lng` | 改写 |
| `item.location[0].title`（POI 名，在定位上下文内） | 改写 |
| `clockLocationInfo.poiName` | 改写 |
| `locationData.address == ""`（空串） | **保持空串，不填假地址** |
| `id` 等数值字段 | 不变 |

### 1.3 踩坑两则

**① `title` 被误改**

第一版把 `title` 放进 `NAME_KEYS`，结果把表单单元格的**字段标签**
（「定位」「姓名」）全改成了地点名，服务端收到的表单定义直接变形。

修法：`title` 只在 `location` / `locationData` / `clockLocationInfo` / `poi`
这类定位上下文里才改写，由 `in_loc` 标志控制（见 `src/jl_addon.py`
的 `LOC_CTX_KEYS` / `_deep_rewrite`）。

**教训**：小程序里同名 key 在不同层级含义不同，按名字全局匹配一定会踩到。

**② 同秒抓包互相覆盖**

`sign_body_<时间戳>.json` 的时间戳只到秒。连点两次签到、或前端重试时，
两次请求落在同一秒，后一条直接覆盖前一条——**看起来有存证，实际丢了一条**。
这类 bug 在排障时最容易误导人（会以为「只有一次请求」）。

修法：落盘前查重名，冲突就加 `_1` / `_2` 后缀。

**教训**：凡是「按时间命名产物」的地方，都要假设同一时间点会有多条。

---

## 二、待验证 / 未解决

### 🔴 未解决（阻塞项）

| # | 问题 | 为什么卡住 | 需要什么才能解开 |
|---|---|---|---|
| **U1** | **token 的来源** | 目前所有抓到的请求都是 `auth=no token=no`（冷启动探测）。没有一次带鉴权的真实签到抓包，所以不知道 token 从哪来、叫什么、什么格式 | **一次完整的真实签到抓包**：在小程序里正常登录 → 进入活动 → 提交一次签到，让 addon 把 header 打出来 |
| **U2** | 鉴权头的**准确名称** | `Authorization` 还是 `token`，或两者都要。addon 两个都检测，但没数据 | 同 U1 |
| **U3** | 值的**格式** | `Bearer <TOKEN>` / 裸 token / 带签名 | 同 U1 |

> **U1 是本项目唯一的硬缺口。** 在它解开之前，「改写后服务端返回接龙成功」
> 这件事无法自证——因为请求压根没带鉴权，返回的一定是 901。

### 🟡 待验证（有推断，缺证据）

| # | 事项 | 当前推断 | 怎么验 |
|---|---|---|---|
| V1 | 改写后服务端是否接受 | 应该接受（服务端只存 JSON 里的坐标） | 带 token 跑一次，看是否返回 `status:0` |
| V2 | 服务端是否**二次校验**坐标 | 倾向「不校验」——校验代码在客户端，且 `range` 是前端读的 | 故意传一个明显离谱的坐标，看服务端是否拒绝 |
| V3 | `/activity/sign` 的完整请求体结构 | 大概是 `{活动ID, form:[...], ...}` | 一次真实抓包，dump 到 `sign_body_*.json` |
| V4 | 是否存在 `sign` / `timestamp` / `nonce` 防重放 | 倾向「没有」——否则改包会被拒 | 同 V1；若改包后 401/403 就说明有 |
| V5 | token 有效期与刷新时机 | 未知 | 长时间挂机观察 |
| V6 | 是否有「同一活动只能签一次」的服务端约束 | 大概有 | 重复提交看返回码 |
| V7 | `updateSignList` 与 `sign` 的关系（改签 vs 新签） | 未知 | 抓两次对比 |

### 🟢 可优化（不阻塞）

| # | 事项 | 说明 |
|---|---|---|
| O1 | addon 增加 `--set` 风格的配置 | 现在靠环境变量，跨 shell 传递略笨 |
| O2 | 支持 gzip / protobuf 请求体 | 目前只处理明文 JSON；若遇到压缩体会静默跳过 |
| O3 | 增加「dry-run 对比输出」 | 把改写前后的 JSON diff 打出来，便于确认 |
| O4 | 把单测固化成 `tests/test_rewrite.py` | 现在的验证是临时脚本，没入库 |
| O5 | 支持按活动 ID 限定改写范围 | 避免误改其它活动的请求 |
| O6 | `V1MMWX` 包的解密 | 目前绕开（走运行时取源码）；解开可直接静态读全量逻辑 |

---

## 三、下一步（按优先级）

```
1. 【阻塞】拿到一次带鉴权的真实签到抓包
   ├─ 在小程序里正常登录
   ├─ 进入一个「指定地点」类型的接龙
   ├─ 点获取定位（会失败，弹「您还未到定位地点」）
   ├─ 此时 addon 应该已经打出了带 Authorization 的请求
   └─ 把 header 名与格式记下来（值用 <TOKEN> 占位！不要贴真值）

2. 【验证】带 token 重放一次 /activity/sign
   └─ 确认 status:0，且坐标是改写后的值

3. 【验证】故意传离谱坐标，判断服务端有无二次校验（V2）

4. 【收尾】把 U1~U3 从右栏挪到左栏，补进 docs/01 §4

5. 【可选】把单测落到 tests/，让 CI 能跑
```

---

## 四、这张表怎么用

- **加新条目**：先写进「待验证」，附上「怎么验」；验完再挪到「已验证」，
  并把命令与输出补进 §1.1。
- **不要写「应该可以」**：右栏的「推断」列允许写倾向，但左栏只放实测。
- **U 系列**是阻塞项，任何一条没解，README §5 的表格就不该出现 ✅。
