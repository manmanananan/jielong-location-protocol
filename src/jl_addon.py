"""接龙（jielong.huolieyun.com）反向代理抓包 / 定位字段改写 addon。

这是本仓库的核心工具：一个 mitmproxy addon。它不改小程序代码、不注入 JS、
不碰系统定位，只在 HTTP 层看请求、必要时把请求体里的定位字段换掉。

设计取舍（为什么在 HTTP 层做，而不是在 JS 层做）
------------------------------------------------
小程序把「定位是否合规」的判断放在 JS 里跑（见 docs/02），校验通过后它会把
坐标写进表单字段，再随提交请求发上去。所以真正到达服务端的是**请求体里的
一组坐标字段**，而不是设备 GPS 读数。只要在这一层替换，就等价于用户自己
在地图上选中了那个点，前端一行代码都不用动。

用法
----
只观察（默认，不改写）：

    mitmdump -s src/jl_addon.py --listen-port 8899

观察 + 改写：

    $env:JL_REWRITE="1"
    $env:JL_LAT="34.81605"; $env:JL_LON="113.53683"
    $env:JL_NAME="<PLACE_NAME>"; $env:JL_ADDR="<PLACE_ADDRESS>"
    mitmdump -s src/jl_addon.py --listen-port 8899

它做四件事：
  1. 打印所有命中 TARGET_HOST 的请求（方法、路径、鉴权头是否存在、体长度）；
  2. 命中签到类路径时，把完整请求（含头）落盘成 sign_body_<时间戳>.json；
  3. JL_REWRITE=1 时，递归替换请求体里所有像坐标/地址的字段；
  4. 打印响应状态与前 220 字符，便于确认服务端是否接受。

安全纪律（重要）
----------------
* sign_body_*.json 里含 Authorization / token / 手机号 / 姓名等真实凭据，
  属于敏感抓包，已在仓库 .gitignore 中排除。**不要提交、不要贴进 issue。**
* 默认日志只记录「鉴权头存在与否」，不打印其值；确需排障时用
  JL_MASK_AUTH=0 显式关闭脱敏，且只在本机查看。
* 本文件不含、也不应写入任何真实 token / cookie / 手机号。
"""
import json
import os
import time

from mitmproxy import ctx

# ---------------------------------------------------------------- 配置区
# 目标域名。接龙小程序的所有业务接口都走这个 host（见 docs/01）。
TARGET_HOST = os.environ.get("JL_HOST", "jielong.huolieyun.com")

# 产物目录：抓包日志 + 敏感请求体。默认落在当前工作目录下的 mitm-out/。
OUT_DIR = os.environ.get("JL_OUT", os.path.join(os.getcwd(), "mitm-out"))
LOG_PATH = os.path.join(OUT_DIR, "jl_addon.log")

# 是否改写。默认 0 = 纯观察，避免误改。
REWRITE = os.environ.get("JL_REWRITE", "0") == "1"

# 目标点。默认值是「郑州大学(培英路)」这一组实测坐标，仅作占位示例，
# 换成任何地点都能用；真正要改的是这三个常量背后的环境变量。
LAT = float(os.environ.get("JL_LAT", "34.81605"))
LON = float(os.environ.get("JL_LON", "113.53683"))
NAME = os.environ.get("JL_NAME", "<PLACE_NAME>")
ADDR = os.environ.get("JL_ADDR", "<PLACE_ADDRESS>")

# 日志脱敏开关。1 = 只记「有没有」，0 = 明文落盘（仅本机排障）。
MASK_AUTH = os.environ.get("JL_MASK_AUTH", "1") == "1"

# 探哪些头当鉴权。名称大小写不敏感（HTTP 头本来就大小写不敏感），
# 多列几个是因为文档里 U2 还没定论，让日志自己回答。
AUTH_HEADER_NAMES = ("Authorization", "token", "X-Token", "access-token", "jielong-token")

# 命中这些路径片段就认为是一次签到/打卡请求，落盘存证。
SIGN_HINTS = ("/activity/sign", "updatesignlist", "clockin", "daka")

# 需要改写的字段名。小程序不同页面用的键不一样（表单层是 locationData，
# 列表页反过来套 location.lat / location.lng），所以按名字全覆盖。
LAT_KEYS = {"latitude", "lat", "latitudes"}
LON_KEYS = {"longitude", "lng", "lon", "longitudes"}
ADDR_KEYS = {"address", "addr", "locationAddress", "fullAddress", "detailAddress"}
NAME_KEYS = {"name", "poiName", "locationName"}

# title 是个危险键：在 form 单元格里它是「字段标签」（如「定位」「姓名」），
# 在 POI 对象里它才是「地点名」。所以只在定位上下文里才改写它。
# 这条是踩过的坑：早期版本把 title 放进 NAME_KEYS，结果把表单标签全改成了
# 地点名，服务端收到的字段定义直接变形。
TITLE_KEY = "title"
LOC_CTX_KEYS = {"location", "locationData", "clockLocationInfo", "poi", "poiList"}

# 递归深度上限。请求体不深，8 层足够，同时防环。
MAX_DEPTH = 8


# ---------------------------------------------------------------- 基础设施
def log(msg: str) -> None:
    """同时写 stderr 与文件。mitmdump 前台看不到文件时用 tail 查。"""
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        # 日志失败不能影响代理主流程。
        pass


def _auth_state(headers) -> str:
    """报告鉴权头存不存在。

    默认只报「有/无」与长度，不打印值——值等于账号。
    头名一次探多个：`docs/04` 的 U2 就是「到底叫 Authorization 还是 token」，
    让日志自己把这题答了，比事后猜便宜。
    """
    if not MASK_AUTH:
        found = {n: headers.get(n) for n in AUTH_HEADER_NAMES if headers.get(n)}
        return f"auth={found!r}"

    parts = []
    for n in AUTH_HEADER_NAMES:
        v = headers.get(n)
        parts.append(f"{n}={'yes' if v else 'no'}({len(v) if v else 0})")
    return " ".join(parts)


def _deep_rewrite(obj, depth: int = 0, in_loc: bool = False):
    """递归替换请求体里所有像坐标/地址的字段。

    为什么要递归：接龙的表单提交是嵌套结构，
    form[i].locationData.{latitude,longitude,name,address}、
    item.location[0].{lat,lng}、clockLocationInfo 这些都出现过，
    写死一层会漏。按字段名匹配而不是按路径匹配，换页面也不用改代码。

    in_loc 表示「当前是否处在一个定位对象内部」，只用来决定要不要动 title。
    一旦某个键名属于 LOC_CTX_KEYS，往下的子对象就进入定位上下文。
    """
    if depth > MAX_DEPTH:
        return obj
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            key = str(k)
            if key in LAT_KEYS and isinstance(v, (int, float, str)):
                out[k] = LAT
            elif key in LON_KEYS and isinstance(v, (int, float, str)):
                out[k] = LON
            elif key in ADDR_KEYS and isinstance(v, str) and v:
                out[k] = ADDR
            elif key in NAME_KEYS and isinstance(v, str) and 0 < len(v) < 60:
                # 长度上限避免把长文本误判成地点名。
                out[k] = NAME
            elif key == TITLE_KEY and in_loc and isinstance(v, str) and 0 < len(v) < 60:
                out[k] = NAME
            else:
                child_loc = in_loc or key in LOC_CTX_KEYS
                out[k] = _deep_rewrite(v, depth + 1, child_loc)
        return out
    if isinstance(obj, list):
        # 列表沿用父级上下文：location[0] 里的 title 属于定位对象。
        return [_deep_rewrite(x, depth + 1, in_loc) for x in obj]
    return obj


# ---------------------------------------------------------------- mitmproxy 钩子
def request(flow) -> None:
    if TARGET_HOST not in (flow.request.pretty_host or ""):
        return

    path = flow.request.path
    method = flow.request.method
    body = flow.request.get_text(strict=False) or ""

    log(f"{method} {path} {_auth_state(flow.request.headers)} len={len(body)}")
    if body:
        log(f"    body: {body[:400].replace(chr(10), ' ')}")

    # --- 存证：签到类请求整包落盘 ---
    low = path.lower()
    if any(h in low for h in SIGN_HINTS):
        ts = time.strftime("%Y%m%d_%H%M%S")
        dump = {
            "path": path,
            "method": method,
            "headers": dict(flow.request.headers),  # 含凭据，见文件头纪律
            "body": body,
        }
        try:
            os.makedirs(OUT_DIR, exist_ok=True)
            dst = os.path.join(OUT_DIR, f"sign_body_{ts}.json")
            # 同一秒内的多条请求会撞名、后一条盖掉前一条，等于丢证据。
            # 加 -1/-2 后缀区分。
            n = 1
            while os.path.exists(dst):
                dst = os.path.join(OUT_DIR, f"sign_body_{ts}_{n}.json")
                n += 1
            with open(dst, "w", encoding="utf-8") as f:
                json.dump(dump, f, ensure_ascii=False, indent=2)
            log(f"    >>> saved {os.path.basename(dst)}（敏感，勿提交）")
        except Exception as e:
            log(f"    save failed: {e}")

    # --- 改写：只动 POST 的 JSON 体 ---
    if not REWRITE or not body or method.upper() != "POST":
        return
    try:
        data = json.loads(body)
    except Exception:
        # 非 JSON（表单编码、protobuf）不动，交给人看。
        return
    new = _deep_rewrite(data)
    if new != data:
        # separators 去空格：小程序对体积敏感，且避免无意义的 diff 噪声。
        flow.request.set_text(json.dumps(new, ensure_ascii=False, separators=(",", ":")))
        log(f"    >>> REWRITTEN -> ({LAT}, {LON}) {NAME}")


def response(flow) -> None:
    """把响应也打出来。判断改写是否被服务端接受的唯一依据就是这里。"""
    if TARGET_HOST not in (flow.request.pretty_host or ""):
        return
    txt = flow.response.get_text(strict=False) or ""
    log(f"<<< {flow.response.status_code} {flow.request.path[:90]} :: {txt[:220]}")


def done() -> None:
    log("mitmproxy stopped")
