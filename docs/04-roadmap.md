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
| 20 | **`status:0` 不是成功码**——404 / 根路径 / 方法错都会返回 0 | 实测四种情形，见 §1.4 与 `docs/01` §3.2 |
| 21 | 业务接口只收 POST，GET 返回「哎哟！出错啦！」 | 实测 `GET /activity/activityDetail` |
| 22 | `status:0` 与 `msg` 解耦：`msg` 报错时 `status` 仍为 0 | 同 20 |

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

### 1.4 `status:0` 的四种出现情形（反直觉，实测）

```powershell
# ① 404 的响应体也是 status:0
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/nope" -d "{}"
# {"msg":"","status":0}          HTTP 404

# ② 根路径
curl.exe -s "https://jielong.huolieyun.com/"
# {"msg":null,"status":0}        HTTP 200

# ③ 方法不对
curl.exe -s "https://jielong.huolieyun.com/activity/activityDetail"
# {"msg":"哎哟！出错啦！","status":0}   HTTP 200

# ④ 历史记录
# base.txt: {"msg":"","status":0}
```

四种情形**没有一个是业务成功**。结论：`status:0` = 默认值，不是成功码。
判定成功必须同时看 HTTP 码 + `msg` + 有无 `data`，并等 U1 解开后定标准
（见 §二 U1）。

---

## 二、待验证清单（U1–U6）

> **这一节是给「拿到新证据的人」看的。** 每条都写清三件事：
> 怎么验证、验证后改哪个文档的哪一段、改完这条变成什么。
> 主线一出结果，照着回填即可，不需要重新理解项目。

### 🔴 U1–U6 主表

| # | 待验证的事 | 当前状态 | 怎么验证 | 验证后改哪里 |
|---|---|---|---|---|
| **U1** | **token 从哪来** | 所有抓包都是 `no/no`（冷启动探测），从未见过带鉴权的请求 | ① `mitmdump -s src\jl_addon.py --listen-port 8899`；② 小程序里登录；③ 进一个活动；④ 点「获取定位」（会弹「您还未到定位地点」，但请求已发出）；⑤ 看日志里哪个头变成 `yes(N)` | ✅ 挪到 §一 新增一行<br>✅ `docs/01` §4.1 补「token 由 X 接口签发」<br>✅ `README.md` §5 表最后一行 ❌ → ✅<br>✅ `examples/quickstart.md` §3 去掉 `⚠️` |
| **U2** | 鉴权头的**准确名称** | 未定。addon 同时探 5 个候选 | 同 U1——addon 日志行会直接列出 `Authorization=yes(24) token=no(0) ...`，哪个 `yes` 就是它 | ✅ `docs/01` §4.2 表格第 1 行改成实测值<br>✅ `examples/quickstart.md` §3 的 curl 换掉 `-H`<br>✅ `README.md` §3.2 的示例日志换成真实头名 |
| **U3** | 值的**格式** | 未定：`Bearer <TOKEN>` / 裸 token / 带前缀 | 同 U1，看 `yes(N)` 那个头的值（设 `JL_MASK_AUTH=0` 或看 `sign_body_*.json`）。**记录时只写形态，不写值** | ✅ `docs/01` §4.2 表格第 2 行<br>✅ `examples/quickstart.md` §3 的 `-H "Authorization: <TOKEN>"` 改成真实形态 |
| **U4** | **业务成功码到底是什么** | 已确认**不是** `status:0`（见 §1.4）；真实成功码未知 | 带 token 提交一次成功签到，记录返回体。若返回 `status:0` 且 `msg` 为空、有 `data`，则「0 在某些上下文确为成功」需要重新表述 | ✅ `docs/01` §3.2 补「成功时的实际返回」<br>✅ `README.md` §3.3 的警示框<br>✅ `examples/quickstart.md` §7 返回码表 |
| **U5** | `/activity/activityDetail` 的**请求体字段名** | 推测是 `{"id": "<ACTIVITY_ID>"}`，未验证 | 抓一次真实 detail 请求，看 addon 打出的 `body:` 行 | ✅ `examples/quickstart.md` §4.2 从推测改为实测<br>✅ `docs/01` §3.4 主链路图 |
| **U6** | 是否需要**签名 / 时间戳 / nonce** | 只有弱证据（901 只抱怨 token），不足以定论 | 带上正确 token 后：① 若正常返回 → 不需要；② 若返回「签名错误」类 → 需要，回头找签名算法 | ✅ `examples/quickstart.md` §3 那句「只需要 token」加/去 ⚠️<br>✅ `docs/01` §4.2 表格第 4 行<br>✅ `src/jl_addon.py` 可能要加签名字段处理 |

> **U1 是总闸。** U2–U6 全部依赖它——没有一次带鉴权的抓包，
> 其余五条都无从验证。所以**优先解决 U1，其余会自动连带解开**。

### 🟡 V 系列（U 解开后才谈得上）

| # | 事项 | 当前推断 | 怎么验 |
|---|---|---|---|
| V1 | 服务端是否**二次校验**坐标 | 倾向「不校验」——校验代码在客户端，`range` 是前端读的 | 带 token 后故意传离谱坐标，看是否被拒 |
| V2 | token 有效期与刷新时机 | 未知 | 长时间挂机观察是否突然 901 |
| V3 | 是否有「同一活动只能签一次」约束 | 大概有 | 重复提交同一活动看返回 |
| V4 | `updateSignList` 与 `sign` 的关系（改签 vs 新签） | 未知 | 两种操作各抓一次对比 |
| V5 | 改写后服务端是否接受（端到端） | 应该接受 | U1 解开后跑一次，看是否落库 |


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
1. 【阻塞 · U1】拿到一次带鉴权的真实签到抓包
   ├─ 在小程序里正常登录
   ├─ 进入一个「指定地点」类型的接龙
   ├─ 点获取定位（会失败，弹「您还未到定位地点」）
   ├─ 此时 addon 应该已经打出了带鉴权头的请求
   └─ 记下头名与格式（值用 <TOKEN> 占位！不要贴真值）

2. 【连带】U2 / U3 在拿到上一步日志的瞬间就自动解开
   └─ 日志行会直接显示哪个头是 yes(N)

3. 【U4】带 token 打一次 /activity/sign，确认业务成功码
   └─ 注意：不要用 status:0 当判据，见 §1.4

4. 【U5 / U6】确认请求体字段名、是否需要签名
   └─ 若返回「签名错误」类，U6 结论要翻，回头找算法

5. 【V 系列】服务端二次校验、token 有效期、重复签到约束

6. 【可选】把单测落到 tests/，让 CI 能跑
```

---

## 四、这张表怎么用

- **加新条目**：先写进 §二，附上「怎么验证」和「验证后改哪里」；验完再挪到 §一，
  并把命令与输出补进 §1.1。
- **不要写「应该可以」**：§二的「推断」列允许写倾向，§一只放实测。
- **U 系列是阻塞项**，任何一条没解，README §5 的表格就不该出现 ✅。
- **回填时连带改**：U2 改头名会牵连 `examples/quickstart.md` 和 `README.md` §3.2；
  U4 改成功码会牵连 §1.4 与 `docs/01` §3.2。别只改一处。
- **`status:0` 的教训**：这条最初被当成成功码写进文档，后来用 curl 实测才发现
  404 也返回 0。凡是「没验证过的码」，一律先标 `⚠️`。

