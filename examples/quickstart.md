# Quickstart · 三分钟看懂这个接口

> **⚠️ 先读这段（项目最终结论）**
>
> 本文是**反代路线**的上手材料。那条路线后来被**证伪**了——
> `jielong.huolieyun.com` 被微信域名级代理豁免，请求不经过代理（`docs/07`）。
>
> **真要完成签到，请看 `docs/06-cdp-injection.md`，不要看本文。**
>
> 那为什么还留着？因为这里的接口分析**本身仍然有效**：
> 路径存在性、`status:901`、`status:0` 不是成功码——这些结论跟走哪条路无关，
> 而且它们是**独立复现**出来的（不需要登录态、不需要代理）。
> 如果你只是想搞懂这个后端长什么样，本文是最快的入口。

---

> 本文只做一件事：用 curl 让你**亲手**看到「不带 token 被拒」和
> 「token 从哪进」。不讲原理（原理在 `README.md` §2 和 `docs/02`）。
>
> **先看 §6 的「实测 vs 推测」表**——本文只有一小部分是真验证过的，
> 其余都标了 `⚠️ 待验证`。别把推测当结论用。

---

## 0. 三分钟版

```powershell
# ① 不带任何鉴权头 → 被拒（实测）
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/activityDetail" `
  -H "Content-Type: application/json" -d "{}"
# {"msg":"token为空","status":901}

# ② 带上 token → 正常返回（⚠️ 待验证，见 §3）
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/activityDetail" `
  -H "Content-Type: application/json" `
  -H "Authorization: <TOKEN>" `
  -d "{\"id\":\"<ACTIVITY_ID>\"}"
```

① 是**实测结果**，你可以直接复现。
② 是**预期结果**，`<TOKEN>` 的位置是按常见约定填的，尚未被真实抓包证实。

---

## 1. 前置条件

- 能上网即可。**这一步不需要装 mitmproxy，也不需要开代理。**
- Windows 上用 `curl.exe`，不要用 `curl`——PowerShell 里 `curl` 是
  `Invoke-WebRequest` 的别名，参数语法完全不一样。

```powershell
# 确认拿到的是真 curl
curl.exe --version
# curl 8.x.x (...)
```

---

## 2. 实测基准：不带 token

这是本仓库**唯一一条可以无条件复现**的接口事实。

```powershell
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/activityDetail" `
  -H "Content-Type: application/json" -d "{}"
```

输出：

```json
{"msg":"token为空","status":901}
```

### 这条结果同时证明了四件事

| 结论 | 怎么推出来的 |
|---|---|
| 路径存在 | 不存在的路径返回 404（见 §5），这里返回了业务 JSON |
| 路由通、域名对 | 返回体是业务结构，不是网关错误页 |
| 鉴权在业务之前 | body 是空 `{}` 却先报 token，说明它压根没走到参数校验 |
| 服务端说中文 | `msg` 是中文文案，说明是自有后端，不是通用网关 |

### 顺带得到一个探测手法

因为「鉴权先于参数校验」，可以用 901 当**路径存在性探针**：

```
POST /activity/<随便什么>
  → 901  = 路径存在
  → 404  = 路径不存在
```

`docs/01` §3 那张接口表就是这么探出来的。

---

## 3. 带 token：预期结果（⚠️ 待验证）

```powershell
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/activityDetail" `
  -H "Content-Type: application/json" `
  -H "Authorization: <TOKEN>" `
  -d "{\"id\":\"<ACTIVITY_ID>\"}"
```

**预期**返回类似：

```json
{"msg":"","status":0,"data":{ ... }}
```

但**注意：`status:0` 不代表成功**——见 §7。这一节的重点是「token 往哪填」，
不是「填对了会看到什么号」。

### 为什么这一节标 `⚠️`

| 不知道的事 | 后果 |
|---|---|
| 头名是 `Authorization` 还是 `token` | 填错就是 901，和没填一样 |
| 值的格式（`Bearer <TOKEN>` / 裸 token） | 填错同上 |
| token 从哪个接口拿 | 你手上可能根本没有可用的 `<TOKEN>` |
| `activityDetail` 的真实请求体 | `{"id": ...}` 是推测的字段名 |
| 成功后返回什么码 | **不等于 `status:0`**，见 §7 |

`docs/04-roadmap.md` 的 U1–U6 曾是这几条的编号。**⚠️ 现已全部归档**——
反代路线已证伪，这些「HTTP 层的问题」随之失效（CDP 路线不经过 HTTP 层）。
所以这一节的内容只能当「怎么试」看，不能当「怎么用」看。
**真要签到，去看 `docs/06-cdp-injection.md`。**

### 为什么仍然相信「只需要 token」

有一个间接证据：901 的文案是 `token为空`——它只抱怨 token 缺失，
没提签名、时间戳、nonce 中的任何一个。

**但这是弱证据。** 服务端完全可能「先查 token，再验签名」：
token 缺失时它压根走不到验签名那一步，所以看不到相关报错。
这类「先 A 后 B」的校验顺序会制造「B 不存在」的错觉。

所以准确的说法是：

> **当前没有证据表明需要签名/时间戳，但也没有证据表明不需要。**

这一句如果被后续抓包证伪（比如带上 token 后返回「签名错误」），
需要回来改三处：本节、`docs/01` §4.2 的表格、`docs/04` §二。
（不过反代路线已证伪，这条大概率不会被证伪了。）

---

## 4. 最小可用 JSON 请求体

### 4.1 已实测：`{}` 是合法请求体

空对象 `{}` 能被服务端正常解析——它返回的是 901 而不是 400/解析错误，
说明 JSON 本身没问题，只是缺鉴权。

所以**调试链路时用 `{}` 最省事**：它把变量降到最少，只测「通不通」。

### 4.2 ⚠️ 待验证：真正查详情要什么

`activityDetail` 顾名思义要指定一个活动。推测的最小体：

```json
{"id": "<ACTIVITY_ID>"}
```

但这个字段名**没有验证过**。同类小程序常见写法还有：

| 可能的字段 | 说明 |
|---|---|
| `id` | 最常见 |
| `activityId` | 语义更明确 |
| `activity_id` | 下划线风格 |
| `key` | 接龙的 CLI 工具里出现过「活动 Key」的概念 |

`docs/01` §3 的接口清单里，所有路径都是 `/activity/xxx` 的扁平风格，
没有版本前缀、没有复数资源名，属于偏 PHP/Java 老式写法，
**这类后端用 `id` 的概率最高，但不能当结论。**

### 4.3 怎么自己确认（主线抓包时顺手做）

```powershell
# 起代理后正常点一次活动，看 addon 打出来的 body
mitmdump -s src\jl_addon.py --listen-port 8899
# [..] POST /activity/activityDetail ... len=37
# [..]     body: {"id":"12345"}          ← 这一行就是答案
```

addon 会把 body 前 400 字符打出来，字段名一目了然。

---

## 5. 对照：不存在的路径长什么样

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" -X POST "https://jielong.huolieyun.com/v1/activity/activityDetail" `
  -H "Content-Type: application/json" -d "{}"
# 404
```

对比一下就很清楚：

| 请求 | 返回 | 含义 |
|---|---|---|
| `POST /activity/activityDetail` + `{}` | `{"msg":"token为空","status":901}` | 路径存在，缺鉴权 |
| `POST /v1/activity/activityDetail` + `{}` | HTTP `404` | 路径不存在 |
| `POST /activity/sign` + `{}` | `{"msg":"token为空","status":901}` | 路径存在，缺鉴权 |
| `POST /activity/getSignListMore` + `{}` | `{"msg":"token为空","status":901}` | 路径存在，缺鉴权 |

完整的六条路径见 `docs/01` §3.1。

---

## 6. 实测 vs 推测（重要）

**这一张表是本文最该看的部分。** 上面所有内容都归到这里：

### ✅ 已实测确认

| 事实 | 证据 |
|---|---|
| 域名是 `https://jielong.huolieyun.com` | 抓包 |
| `POST /activity/activityDetail` 存在 | 返回 901 而非 404 |
| `/activity/sign`、`/updateSignList`、`/getSignListMore`、`/delSignOrder`、`/signDel` 存在 | 同上，逐条测过 |
| `/v1/...` 前缀不存在 | 返回 404 |
| 空对象 `{}` 是合法请求体 | 返回 901 而非解析错误 |
| 未鉴权统一返回 `{"msg":"token为空","status":901}` | 六条路径全部一致 |
| 鉴权在参数校验之前执行 | 空体也先报 token |
| 鉴权走请求头，不走 query | 无 query 也触发 901 |
| **`status:0` 不是成功码**（404/根路径/方法错都是 0） | §7 的三条对照实测 |
| 只有 POST 能打业务接口，GET 返回「哎哟！出错啦！」 | 实测 |

### ⚠️ 待验证（不要当结论用）

| 推测 | 编号 | 为什么只是推测 |
|---|---|---|
| 带 `<TOKEN>` 后返回成功 | V1 | 没有带 token 的抓包 |
| 头名是 `Authorization` | U2 | 没数据；addon 同时探 5 个候选头名 |
| 值格式是 `Bearer <TOKEN>` | U3 | 同上 |
| **只需要 token，不需要签名/时间戳** | V4 | 只有「901 没提签名」这一条弱证据 |
| `activityDetail` 的字段名是 `id` | V3 | 完全没验证 |
| 成功码是什么 | V1 | **已确认不是 `status:0`**，具体是哪个未知 |

### 这张表怎么用

- 写代码/写文档时，**只引用上半张**。
- 下半张每验证一条，就把它搬到上半张，并更新 `docs/04` §一。
- 如果你发现本文某条「待验证」其实是错的，**改它，不要绕过它**。

---

## 7. 返回码速查（含一处反直觉发现）

| 返回 | HTTP | 真实含义 | 已确认？ |
|---|---|---|---|
| `{"status":901,"msg":"token为空"}` | 200 | 没带鉴权头 | ✅ 实测 |
| —— | 404 | 路径不存在 | ✅ 实测 |
| `{"status":0,"msg":""}` | **404** | **路由未命中** | ✅ 实测 |
| `{"status":0,"msg":null}` | 200 | 根路径兜底 | ✅ 实测 |
| `{"status":0,"msg":"哎哟！出错啦！"}` | 200 | 方法不对（GET 打 POST 接口） | ✅ 实测 |
| `{"status":0,"msg":"","data":{...}}` | 200 | **业务成功？** | ⚠️ 纯推测 |

### ⚠️ `status:0` 不是成功码

这是实测推出来的、和直觉相反的一条：

```powershell
# 404 的响应体竟然是 status:0
curl.exe -s -X POST "https://jielong.huolieyun.com/activity/nope" -d "{}"
# {"msg":"","status":0}      ← HTTP 是 404

# 方法不对也返回 status:0，但 msg 明说错了
curl.exe -s "https://jielong.huolieyun.com/activity/activityDetail"
# {"msg":"哎哟！出错啦！","status":0}
```

四种不同情形共享 `status:0`，唯一共同点是**它们都不是业务成功**。
所以它更像后端的**默认值**，跟 `msg` 是解耦的。

**实践含义：**
- 判断「改写有没有被接受」，**不能只看 `status:0`**。
- 必须同时看 HTTP 码、`msg` 文本、以及有没有 `data` 字段。
- 真正的业务成功码要等 U1 解开后用真实抓包确定。

更多见 `docs/01` §3.2。

---

## 8. 下一步

- 想看**为什么**要在 HTTP 层改、为什么不直接改客户端：`docs/02` §5–§6
- 想真的跑起来抓包：`docs/03`，或直接 `pwsh -File scripts\setup.ps1 -Port 8899`
- 想知道还差哪些事实：`docs/04-roadmap.md` §二（已归档）
