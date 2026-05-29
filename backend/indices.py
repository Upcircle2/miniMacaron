"""
해외 주요 지수/선물 미니차트 (비-KIS, READ-ONLY).

**설계 원칙**: 차트는 앱을 켜는 순간 이미 완성돼 있어야 한다(과거 백필). 폴링하며 쌓는
누적 방식은 쓰지 않는다.

데이터 소스(키 없음, 차단/레이트리밋 없음):
  - 스파크라인(풀세션 백필) = Nasdaq.com chart API
      · 나스닥종합 COMP(지수, 정규장) · S&P500 SPY(ETF, 정규장) · 나스닥 선물창 QQQ(ETF, 장외 포함)
  - 값/등락률 = CNBC QuickQuote(.IXIC/.SPX/@ND.1, 정확한 지수·선물 숫자) → Stooq 폴백
  ※ Yahoo는 IP 차단(429)이 잦아 제거. 차트는 Nasdaq.com(ETF 장외시세 포함)이 안정적.
스파크라인은 150초 캐시 + 직전값 유지. 차트 모양=Nasdaq.com, 표시 숫자=CNBC(둘 다 같은 지수 추종).

표시 전환(KST): 05:01~22:30 → 나스닥 선물(QQQ 차트) 1개, 22:31~05:00 → 나스닥종합·S&P500 2개.
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
_TTL = 5      # 값(숫자) 캐시 — 5초
_SPARK_TTL = 60   # 차트(스파크) 캐시 — 60초 (1분봉이라 더 빨라도 새 데이터 없음)
_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# 표시 대상. chart=(Nasdaq.com sym, assetclass) → 스파크 모양 / cnbc → 표시 숫자 / stooq → 값 폴백
_CASH = [
    # 차트는 좌우 일관성 위해 둘 다 ETF(QQQ/SPY) — 지수(COMP)는 Nasdaq.com 장중 데이터가 빈약.
    # 값은 CNBC 지수 그대로(.IXIC 나스닥종합 / .SPX S&P500). QQQ=나스닥100, 장중 모양 거의 동일.
    {"name": "나스닥", "sess": _SESS_CASH, "chart": ("QQQ", "etf"),
     "cnbc": ".IXIC", "stooq": "^ndq"},
    {"name": "S&P 500", "sess": _SESS_CASH, "chart": ("SPY", "etf"),
     "cnbc": ".SPX", "stooq": "^spx"},
]
_FUT = [
    {"name": "나스닥 선물", "sess": _SESS_FUT, "chart": ("QQQ", "etf"),
     "cnbc": "@ND.1", "stooq": ""},
]

_cache: dict = {"ts": 0.0, "data": []}
_last_good: dict[str, dict] = {}
_spark_cache: dict[str, tuple[float, list]] = {}   # name -> (ts, spark)


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


def _series_xy(epoch_pts: list[tuple[float, float]]) -> list[list[float]]:
    """[(epoch_sec, value)] → [[x, value]]. 시각 필터 없이 보유 데이터 전부 사용.
    프론트가 균등 분포로 그리므로 x 는 표시용(인덱스 비율)일 뿐. 값 양수만, 시간순."""
    pts = sorted((t, v) for t, v in epoch_pts if v and v > 0)
    vals = [v for _, v in pts]
    if len(vals) > _SPARK_POINTS:
        step = len(vals) / _SPARK_POINTS
        vals = [vals[int(i * step)] for i in range(_SPARK_POINTS)]
    n = len(vals)
    return [[round(i / (n - 1), 4) if n > 1 else 0.0, round(v, 2)]
            for i, v in enumerate(vals)]


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
    return price, prev, _series_xy(pts)


# ── 값 전용 (정확한 지수·선물 숫자) ──────────────────────────────────────────
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
    """대상 1개 → 값(CNBC)·풀세션 스파크라인(Nasdaq.com) dict. 실패 시 last-good."""
    name, sess = t["name"], t["sess"]
    try:
        # 차트(스파크): Nasdaq.com — 150초 캐시 + 직전값 유지
        spark: list[list[float]] | None = None
        sc = _spark_cache.get(name)
        if sc and time.time() - sc[0] < _SPARK_TTL:
            spark = sc[1]
        else:
            try:
                _, _, spark = _nasdaq(t["chart"][0], t["chart"][1], sess)
                _spark_cache[name] = (time.time(), spark)
            except Exception:
                spark = sc[1] if sc else None               # 실패 시 직전 차트 유지

        # 값/등락률: CNBC(정확한 지수·선물 숫자) → Stooq
        price = prev = None
        for src in (lambda: _cnbc(t["cnbc"]), lambda: _stooq(t["stooq"])):
            try:
                price, prev = src(); break
            except Exception:
                continue
        if price is None or prev is None:
            raise ValueError("value sources failed")

        chg = price - prev
        res = {"key": name, "name": name, "value": round(price, 2),
               "change": round(chg, 2), "rate": round(chg / prev * 100, 2) if prev else 0.0,
               "up": chg >= 0, "spark": spark or []}
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
