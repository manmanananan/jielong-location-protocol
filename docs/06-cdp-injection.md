# 06 · CDP 注入：唯一验证成功的方法

> **状态：✅ 已成功，服务端落库。**
>
> 这是本仓库的**主路径**。它绕开了整个 HTTP 层——不抓包、不需要 token、
> 不装 CA、不改系统代理。
>
> 成功证据（三重）见 `README.md` §1.1。

---

## 0. 一句话原理

**不伪造 GPS，直接在小程序逻辑层把「用户已选好点」这个状态写进表单。**

小程序的定位校验跑在 JS 里，它自己算距离、自己决定放不放行。
校验通过之后，它会生成一组普通 JSON 字段（`locationData`）随提交发出。
我们用 CDP 直接把这组字段写进 `page.data`，
**等价于用户自己在地图上选中了那个点**，后面的提交流程一行代码都不用改。

> 这也解释了为什么它比改 GPS 有效：改 GPS 是改「输入」，
> 而校验逻辑会在后续页面跳转里重新取一次位置把结果吃掉；
> 改 `setData` 是直接改「结果」，没有后续环节能把它冲掉。

---

## 1. 环境

| 项 | 值 |
|---|---|
| 系统 | Windows 10/11 |
| PC 微信 | 4.2.0.53（4.x） |
| WMPF runtime | `%APPDATA%\Tencent\xwechat\XPlugin\Plugins\RadiumWMPF\26134\extracted\runtime\` |
| `WeChatAppEx.exe` | 2.5.8.26134（Chromium 132.0.6834.210） |
| 调试器 | [WMPFDebugger](https://github.com/evi0s/WMPFDebugger) |
| Node | 18+ |
| 端口 | debug `9421` → CDP `62000` |

> **版本号要对上**：WMPFDebugger 靠 `addresses.<版本号>.json` 定位微信内部函数。
> 本机 WMPF 是 `26134`，所以需要 `src/addresses.26134.json`。
> 缺这个文件就跑不起来——这是这条路线最主要的维护成本。

---

## 2. 启动顺序（最容易错的一步）

```powershell
# ① 先起调试器
cd <WMPFDEBUGGER_DIR>
npx tsx src/index.ts --auto-detect

# ② 等这一行出现（必须等，不能抢跑）
#    [frida] script loaded, WMPF version: 26134, pid: NNNN
#    输出: debug port 9421 -> CDP port 62000

# ③ 确认调试器就绪之后，才打开小程序
#    （微信里点开「接龙」，进入目标活动页）
```

### ⚠️ 顺序反了会怎样

**hook 完全不生效。** 表现是：CDP 能连上、`Target.getTargets` 也能看到 target，
但读不到小程序逻辑层的数据，或者读到的全是渲染层。

这个坑**试了 5 次才发现**。原因：frida 的 hook 只在 attach 之后
**新创建**的 WMPF 场景上生效；如果小程序已经在跑，它 attach 到的是一个
「事后」的进程，注入点早就过去了。

> 一句话记牢：**先起调试器，等 `script loaded`，再开小程序。**

### ⚠️ 不要加 `--watch`

加了会因 `9421` 端口被占用（`EADDRINUSE`）反复退出。

源码 `src/index.ts` 第 366–367 行的注释写得很明白：

```
// watch 会 detach 掉刚建立的小程序连接（hook 只在 attach 后的新场景生效），
// 所以默认关闭。需要时用 --watch 显式开启。
```

也就是说 `--watch` 的设计目的（进程重启后自动重连）与我们的用法
（attach 一次、保持会话）冲突。**默认不加就对。**

---

## 3. 连 CDP，找逻辑层

### 3.1 流程

```
ws://127.0.0.1:62000
  │
  ├─ Target.getTargets
  │    找 type === "page" 且 url 含 AppID 的 target
  │
  ├─ Target.attachToTarget { targetId, flatten: true }
  │    → 拿到 sessionId
  │
  ├─ Runtime.enable          ← 必须在 attach 之后，否则收不到 executionContextCreated
  │
  ├─ 等 2 秒，收集 Runtime.executionContextCreated 事件
  │
  └─ 逐个 evaluate "typeof getCurrentPages"
        → 返回 "function" 的那个就是逻辑层
```

### 3.2 判定逻辑层的标志

```
逻辑层：typeof getCurrentPages === "function"  且  typeof window === "undefined"
渲染层：有 window、有 Component，没有 getCurrentPages
```

**不要用「哪个 context 先出现」或「context 名字」来猜**——顺序不稳定。
只认这一个判据。

### 3.3 最小验证脚本

```js
const WebSocket = require("ws");
const APPID = "wxdbe4c8e7bc3fb688";
let id = 1;
const pending = new Map();
const ctxs = [];

function rpc(ws, method, params, sessionId, timeout) {
  const i = id++;
  const msg = { id: i, method, params: params || {} };
  if (sessionId) msg.sessionId = sessionId;
  return new Promise((res, rej) => {
    pending.set(i, res);
    ws.send(JSON.stringify(msg));
    setTimeout(() => {
      if (pending.has(i)) { pending.delete(i); rej(new Error("timeout")); }
    }, timeout || 15000);
  });
}

async function ev(ws, sid, cid, expr) {
  const r = await rpc(ws, "Runtime.evaluate",
    { expression: expr, contextId: cid, returnByValue: true, awaitPromise: true }, sid);
  if (r.result && r.result.exceptionDetails)
    return { err: JSON.stringify(r.result.exceptionDetails).slice(0, 300) };
  return { val: r.result && r.result.result ? r.result.result.value : undefined };
}

(async () => {
  const ws = new WebSocket("ws://127.0.0.1:62000");
  ws.on("message", d => {
    let m; try { m = JSON.parse(d.toString()); } catch { return; }
    if (m.id && pending.has(m.id)) { const f = pending.get(m.id); pending.delete(m.id); f(m); return; }
    if (m.method === "Runtime.executionContextCreated")
      ctxs.push({ sid: m.sessionId, c: m.params.context });
  });
  await new Promise((r, j) => { ws.on("open", r); ws.on("error", j); });

  // 1. 找 target
  const tg = await rpc(ws, "Target.getTargets");
  const page = (tg.result.targetInfos || [])
    .find(t => t.type === "page" && t.url.includes(APPID));
  if (!page) throw new Error("找不到小程序 target，先确认小程序已打开");

  // 2. attach + enable
  const at = await rpc(ws, "Target.attachToTarget", { targetId: page.targetId, flatten: true });
  const sid = at.result.sessionId;
  await rpc(ws, "Runtime.enable", {}, sid);
  await new Promise(r => setTimeout(r, 2000));   // 必须等事件收集

  // 3. 找逻辑层
  let cid = null;
  for (const x of ctxs.filter(c => c.sid === sid)) {
    const r = await ev(ws, sid, x.c.id, "typeof getCurrentPages");
    if (r.val === "function") { cid = x.c.id; break; }
  }
  if (!cid) throw new Error("没找到逻辑层 context");

  console.log("logic context =", cid);
  const r = await ev(ws, sid, cid, "getCurrentPages().map(p => p.route).join(',')");
  console.log("pages:", r.val || r.err);
  process.exit(0);
})().catch(e => { console.error("FATAL", e.message); process.exit(1); });
```

---

## 4. 定位字段：先 dump，不要猜

### 4.1 `form` 的索引是变动的

页面 `data.form` 是个数组，每一项是表单单元格。定位字段是 `type === 7` 的那一项。

**索引不固定**（本例是 `form[1]`，但换个接龙就不一定）。**不要写死，先 dump：**

```js
getCurrentPages()[1].data.form.forEach(function (f, i) {
  console.log(i, f.type, f.title, JSON.stringify(f.location || null));
});
```

输出形如：

```
0  1  "姓名"     null
1  7  "定位"     [{"name":"<PLACE_NAME>","address":"<PLACE_ADDRESS>","latitude":<TARGET_LAT>,"longitude":<TARGET_LON>,"range":50}]
2  1  "备注"     null
```

`type === 7` 就是它，用它的下标。

### 4.2 坐标要从表单里读，不要自己编

**这条是原则，不是建议。**

`form[i].location[0]` 里已经有创建人设定的**目标点**——那是这个接龙允许签到的位置。
直接读它、再写回去，坐标天然是合法的。

```
var t = form[i].location[0];
// t = { name, address, latitude, longitude, range }
```

自己编一个坐标的后果：
- 落在这个 `range`（本例 50 米）之外 → **服务端或前端拒绝**；
- 即使碰巧落在范围内，`name`/`address` 与坐标对不上 → 数据不一致。

> 本例的成功正是因为：**坐标读自 `location[0]`，不是算出来的**。

### 4.3 要写哪几个字段

只改 `latitude`/`longitude` 不够。前端展示与服务端存储需要四个字段一致：

```js
var patch = {};
patch["form[" + i + "].value"]        = t.name;      // 显示文本
patch["form[" + i + "].showText"]     = true;        // 让输入框显示值
patch["form[" + i + "].locationData"] = {
  name:      t.name,
  address:   t.address,
  latitude:  t.latitude,
  longitude: t.longitude
};
page.setData(patch);
```

---

## 5. 提交

两条路都验证过：

### 5.1 调页面方法（推荐，可脚本化）

```js
page.submit();
```

### 5.2 点 GUI 按钮

保持 CDP 连接，直接在微信窗口里点「提交」。
setData 的结果在页面状态里，手动提交一样生效。

> 两条都通，说明**写入点是对的**——不依赖某一种提交方式。

---

## 6. 成功判据

别看 `status` 字段（见 `docs/01` §3.2，`status:0` 是默认值不是成功码）。
看这三样：

| 判据 | 怎么看 |
|---|---|
| **UI 变化** | 页面跳「接龙成功」；列表按钮从「接龙」变「已接龙」 |
| **计数变化** | 完成情况 `52/57` → `53/57` |
| **数据回读** | CDP 读列表页，目标项 `hasMe: true` |

三者一致才算成功。本例三者都拿到了。

---

## 7. 踩坑速查

| 现象 | 原因 / 处理 |
|---|---|
| **hook 完全不生效** | 启动顺序反了。必须：起调试器 → 等 `[frida] script loaded, WMPF version: 26134, pid: NNNN` → **再**开小程序 |
| 调试器反复退出，`EADDRINUSE 9421` | 加了 `--watch`，去掉 |
| `Target.getTargets` 找不到小程序 | 小程序没开，或 AppID 写错 |
| `Runtime.evaluate` 报 `window is not defined` | attach 到了渲染层，用 §3.2 的判据重找 |
| 所有 context 都不是 `function` | `Runtime.enable` 在 attach 之前调了；或没等够 2 秒 |
| `form` 索引改错，无反应 | 没 dump 就猜索引。先跑 §4.1 |
| 改了但提交被拒 / 仍提示未到地点 | 坐标编的，不在 `range` 内；或没同步改 `name`/`address` |
| 微信升级后跑不起来 | `addresses.<新版本>.json` 缺失，等社区补表 |
| 小程序重载后 setData 失效 | 正常——setData 是一次性的，重载后要重新执行 |

---

## 8. 与反代路线的对比（为什么最终选它）

| 维度 | CDP 注入 | 反代改写 |
|---|---|---|
| 能否成功 | ✅ 已成功落库 | ❌ 已证伪（`docs/07`） |
| 需要 token | **不需要** | 需要（且没抓到） |
| 需要抓包 / CA | 不需要 | 需要 |
| 需要改系统代理 | 不需要 | 需要 |
| 依赖微信版本 | **强**（`addresses.<ver>.json`） | 无 |
| 依赖小程序结构 | 中（`form` 索引、`type===7`） | 弱（字段名） |
| 微信升级后 | 可能要等社区补表 | 不受影响 |
| 失败可观测性 | 较好（能读 `page.data` 自证） | 极差（请求根本不出现） |

**反代在纸面上每一项都更优**——除了「它根本不通」。
这是本项目最大的一课：**先验证链路可达，再谈架构优雅。**
