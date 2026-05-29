"""
해외 주요 지수/선물 미니차트 (비-KIS, READ-ONLY).

**설계 원칙**: 차트는 앱을 켜는 순간 이미 완성돼 있어야 한다(과거 백필). 폴링하며 쌓는
누적 방식은 쓰지 않는다.

데이터 소스(키 없음, 우선순위):
  - 스파크라인 백필 + 값:
      1) Nasdaq.com  (나스닥종합 COMP / 나스닥100 NDX — 차단 없음, 390pt 풀세션)
      2) Yahoo Finance (S&P500 ^GSPC / 나스닥 선물 NQ=F — 풀데이 1분봉)
  - 값/등락률 폴백: CNBC QuickQuote(.IXIC/.SPX/@ND.1) → Stooq
스파크라인은 150초 캐시 + 직전값 유지로 백필 소스 호출을 억제(Yahoo 429 회피).

표시 전환(KST): 05:01~22:30 → 나스닥 선물 1개, 22:31~05:00 → 나스닥종합·S&P500 2개.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

_ET = ZoneInfo("America/New_York")
_KST = ZoneInfo("Asia/Seoul")
_OPEN_MIN = 9 * 60 + 30          # 현금장 09:30 ET
_CLOSE_MIN = 16 * 60            # 현금장 16:00 ET
_FUT_OPEN = 5 * 60 + 1          # 선물 표시창 05:01 KST
_FUT_CLOSE = 22 * 60 + 30       # 선물 표시창 22:30 KST
_SESS_CASH = (_ET, _OPEN_MIN, _CLOSE_MIN)
_SESS_FUT = (_KST, _FUT_OPEN, _FUT_CLOSE)
_SPARK_POINTS = 80
_TTL = 10
_SPARK_TTL = 150
_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# 표시 대상. nasdaq=(sym, assetclass) | yahoo=sym | cnbc=sym | stooq=sym
_CASH = [
    {"name": "나스닥", "sess": _SESS_CASH, "nasdaq": ("COMP", "index"),
     "yahoo": "^IXIC", "cnbc": ".IXIC", "stooq": "^ndq"},
    {"name": "S&P 500", "sess": _SESS_CASH, "nasdaq": None,
     "yahoo": "^GSPC", "cnbc": ".SPX", "stooq": "^spx"},
]
_FUT = [
    {"name": "나스닥 선물", "sess": _SESS_FUT, "nasdaq": None,
     "yahoo": "NQ=F", "cnbc": "@ND.1", "stooq": ""},
]

_cache: dict = {"ts": 0.0, "data": []}
_last_good: dict[str, dict] = {}
_spark_cache: dict[str, tuple[float, list]] = {}   # name -> (ts, spark)
_yahoo_cooldown_until = 0.0


def _http(url: str, headers: dict | None = None, timeout: int = 10) -> str:
    h = {"User-Agent": _UA, "Accept": "*/*"}
    if headers:
        h.update(headers)
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def _f(v) -> float | None:
    try:
        return float(str(v).replace(",", "").replace("$", ""))
    except (TypeError, ValueError):
        return None


def _downsample(xy: list[list[float]]) -> list[list[float]]:
    if len(xy) > _SPARK_POINTS:
        step = len(xy) / _SPARK_POINTS
        xy = [xy[int(i * step)] for i in range(_SPARK_POINTS)]
    return [[round(x, 4), round(v, 2)] for x, v in xy]


def _map_xy(epoch_pts: list[tuple[float, float]], sess: tuple) -> list[list[float]]:
    """[(epoch_sec, value)] → [[x(0~1, 세션 시각), value]] (세션 개시=왼쪽 끝)."""
    tz, o_min, c_min = sess
    span = max(1, c_min - o_min)
    out = []
    for t, v in epoch_pts:
        lt = datetime.fromtimestamp(t, tz)
        x = (lt.hour * 60 + lt.minute - o_min) / span
        if 0 <= x <= 1 and v > 0:
            out.append([x, v])
    return _downsample(out)


# ── 백필 소스 (값 + 풀세션 스파크라인) ────────────────────────────────────────
def _nasdaq(sym: str, ac: str, sess: tuple) -> tuple[float, float, list[list[float]]]:
    """Nasdaq.com 차트 API — 차단 없음, 390pt 풀세션. (현재가, 전일종가, spark)."""
    url = f"https://api.nasdaq.com/api/quote/{urllib.parse.quote(sym)}/chart?assetclass={ac}"
    d = json.loads(_http(url, headers={
        "Accept": "application/json",
        "Origin": "https://www.nasdaq.com",
        "Referer": "https://www.nasdaq.com/",
    }))
    data = d.get("data") or {}
    if (d.get("status") or {}).get("rCode") != 200 or not data.get("chart"):
        raise ValueError("nasdaq.com no data")
    price = _f(data.get("lastSalePrice"))
    prev = _f(data.get("previousClose"))
    pts = [(c["x"] / 1000.0, _f(c.get("y"))) for c in data["chart"]
           if c.get("x") and _f(c.get("y")) is not None]
    if price is None and pts:
        price = pts[-1][1]
    if price is None or prev is None:
        raise ValueError("nasdaq.com missing fields")
    return price, prev, _map_xy(pts, sess)


def _yahoo(sym: str, sess: tuple) -> tuple[float, float, list[list[float]]]:
    """Yahoo 차트 — 풀데이 1분봉. (현재가, 전일종가, spark)."""
    url = (f"https://query1.finance.yahoo.com/v8/finance/chart/"
           f"{urllib.parse.quote(sym)}?interval=1m&range=1d")
    res = json.loads(_http(url))["chart"]["result"][0]
    m = res.get("meta", {})
    ts = res.get("timestamp") or []
    closes = (res.get("indicators", {}).get("quote") or [{}])[0].get("close") or []
    pts = [(t, _f(c)) for t, c in zip(ts, closes) if c is not None]
    if not pts:
        raise ValueError("no intraday data")
    price = _f(m.get("regularMarketPrice")) or pts[-1][1]
    prev = _f(m.get("chartPreviousClose")) or _f(m.get("previousClose")) or pts[0][1]
    return price, prev, _map_xy(pts, sess)


# ── 값 전용 폴백 ──────────────────────────────────────────────────────────────
def _cnbc(sym: str) -> tuple[float, float]:
    url = (f"https://quote.cnbc.com/quote-html-webservice/quote.htm"
           f"?symbols={urllib.parse.quote(sym)}&output=json&fund=1")
    q = json.loads(_http(url))["QuickQuoteResult"]["QuickQuote"]
    q = q[0] if isinstance(q, list) else q
    price, prev = _f(q.get("last")), _f(q.get("previous_day_closing"))
    if price is None or prev is None:
        raise ValueError("cnbc missing fields")
    return price, prev


def _stooq(sym: str) -> tuple[float, float]:
    txt = _http(f"https://stooq.com/q/l/?s={urllib.parse.quote(sym)}&f=sd2t2ohlcvp&h&e=csv", timeout=12)
    p = txt.strip().splitlines()[-1].split(",")
    price, prev = _f(p[6]), _f(p[8])
    if price is None or prev is None:
        raise ValueError("stooq missing fields")
    return price, prev


# ── 조립 ──────────────────────────────────────────────────────────────────────
def _build_quote(t: dict) -> dict:
    """대상 1개 → 값·등락률·풀세션 스파크라인 dict. 실패 시 last-good."""
    global _yahoo_cooldown_until
    name, sess = t["name"], t["sess"]
    try:
        price = prev = None
        spark: list[list[float]] | None = None

        sc = _spark_cache.get(name)
        if sc and time.time() - sc[0] < _SPARK_TTL:
            spark = sc[1]                                   # 캐시 신선 → 백필 소스 미호출

        # 1) Nasdaq.com 백필 (차단 없음 — 나스닥 계열)
        if spark is None and t["nasdaq"]:
            try:
                price, prev, spark = _nasdaq(t["nasdaq"][0], t["nasdaq"][1], sess)
                _spark_cache[name] = (time.time(), spark)
            except Exception:
                pass

        # 2) Yahoo 백필 (S&P500/선물, 또는 Nasdaq.com 실패 시)
        if spark is None and t["yahoo"] and time.time() >= _yahoo_cooldown_until:
            try:
                price, prev, spark = _yahoo(t["yahoo"], sess)
                _spark_cache[name] = (time.time(), spark)
            except Exception:
                _yahoo_cooldown_until = time.time() + 180

        if spark is None and sc:                            # 백필 실패 → 직전 차트 유지
            spark = sc[1]

        # 값 폴백: 백필이 값을 못 줬으면 CNBC → Stooq
        if price is None:
            for src in (lambda: _cnbc(t["cnbc"]), lambda: _stooq(t["stooq"])):
                try:
                    price, prev = src(); break
                except Exception:
                    continue
        if price is None or prev is None:
            raise ValueError("all sources failed")

        chg = price - prev
        res = {"key": t["yahoo"] or name, "name": name, "value": round(price, 2),
               "change": round(chg, 2), "rate": round(chg / prev * 100, 2) if prev else 0.0,
               "up": chg >= 0, "spark": spark or []}        # 백필 없으면 빈 차트(누적 안 함)
        _last_good[name] = res
        return res
    except Exception:
        if name in _last_good:
            return _last_good[name]
        raise


def _show_futures() -> bool:
    """KST 05:01~22:30 → 선물. 22:31~05:00 → 나스닥·S&P500."""
    now = datetime.now(_KST)
    m = now.hour * 60 + now.minute
    return _FUT_OPEN <= m <= _FUT_CLOSE


def get_indices() -> list[dict]:
    """KST 시간대별 [선물] 또는 [나스닥·S&P500] — 캐시(10s)."""
    if _cache["data"] and time.time() - _cache["ts"] < _TTL:
        return _cache["data"]
    targets = _FUT if _show_futures() else _CASH
    out: list[dict] = []
    for t in targets:
        try:
            out.append(_build_quote(t))
        except Exception:
            continue
    if out:
        _cache["ts"] = time.time()
        _cache["data"] = out
    return out if out else _cache["data"]
