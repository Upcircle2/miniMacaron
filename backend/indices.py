"""
해외 주요 지수 (나스닥 종합 · S&P500) — 값/등락률/장중 스파크라인 (비-KIS, READ-ONLY).

값·등락률은 항상 표시되도록 다중 소스 폴백:
  Yahoo Finance(풀데이 1분봉 + 값 + 전일종가) → CNBC(값/등락/전일종가, 안정적) → Stooq.
스파크라인은 Yahoo 가 닿으면 풀데이, 아니면 폴링값을 ET 세션(09:30~16:00)에 누적.
지수별 last-good 캐시로 일시 실패 시 깜빡임 방지. 외부 소스 모두 무키.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

# (yahoo_sym, cnbc_sym, stooq_sym, 표시이름)
_INDICES = [("^IXIC", ".IXIC", "^ndq", "나스닥"),
            ("^GSPC", ".SPX", "^spx", "S&P 500")]
# 나스닥 선물 (US 현금장 마감 시간대에 표시). Yahoo NQ=F / CNBC @ND.1.
_FUTURES = ("NQ=F", "@ND.1", "", "나스닥 선물")
_KST = ZoneInfo("Asia/Seoul")
_TTL = 10
_OPEN_MIN = 9 * 60 + 30
_CLOSE_MIN = 16 * 60
_SESSION = _CLOSE_MIN - _OPEN_MIN
_SPARK_POINTS = 80
_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
_ET = ZoneInfo("America/New_York")

_cache: dict = {"ts": 0.0, "data": []}
_last_good: dict[str, dict] = {}
_series: dict[str, dict] = {}      # name -> {"date":, "pts": {et_min: value}}
_yahoo_cooldown_until = 0.0


def _http(url: str, timeout: int = 8) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": _UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def _f(v) -> float | None:
    try:
        return float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return None


def _yahoo(symbol: str) -> tuple[float, float, list[list[float]]]:
    """(현재가, 전일종가, 풀데이 스파크라인[[x,v]]). 실패 시 예외."""
    url = (f"https://query1.finance.yahoo.com/v8/finance/chart/"
           f"{urllib.parse.quote(symbol)}?interval=1m&range=1d")
    res = json.loads(_http(url))["chart"]["result"][0]
    m = res.get("meta", {})
    ts = res.get("timestamp") or []
    closes = (res.get("indicators", {}).get("quote") or [{}])[0].get("close") or []
    pts = [(t, c) for t, c in zip(ts, closes) if c is not None]
    if not pts:
        raise ValueError("no intraday data")
    price = _f(m.get("regularMarketPrice")) or float(pts[-1][1])
    prev = _f(m.get("chartPreviousClose")) or _f(m.get("previousClose")) or float(pts[0][1])
    spark: list[list[float]] = []
    for t, c in pts:
        et = datetime.fromtimestamp(t, _ET)
        x = (et.hour * 60 + et.minute - _OPEN_MIN) / _SESSION
        if 0 <= x <= 1:
            spark.append([round(x, 4), round(float(c), 2)])
    if len(spark) > _SPARK_POINTS:
        step = len(spark) / _SPARK_POINTS
        spark = [spark[int(i * step)] for i in range(_SPARK_POINTS)]
    return price, prev, spark


def _cnbc(symbol: str) -> tuple[float, float]:
    """(현재가, 전일종가) — CNBC QuickQuote (안정적, 키 없음)."""
    url = (f"https://quote.cnbc.com/quote-html-webservice/quote.htm"
           f"?symbols={urllib.parse.quote(symbol)}&output=json&fund=1")
    q = json.loads(_http(url))["QuickQuoteResult"]["QuickQuote"]
    q = q[0] if isinstance(q, list) else q
    price, prev = _f(q.get("last")), _f(q.get("previous_day_closing"))
    if price is None or prev is None:
        raise ValueError("cnbc missing fields")
    return price, prev


def _stooq(stooq_sym: str) -> tuple[float, float]:
    txt = _http(f"https://stooq.com/q/l/?s={urllib.parse.quote(stooq_sym)}&f=sd2t2ohlcvp&h&e=csv", 12)
    p = txt.strip().splitlines()[-1].split(",")
    price, prev = _f(p[6]), _f(p[8])
    if price is None or prev is None:
        raise ValueError("stooq missing fields")
    return price, prev


# 누적 세션 윈도우: (tz, open_min, close_min)
#   현금지수 = ET 정규장 09:30~16:00,  선물 = KST 표시창 05:01~22:30
_SESS_CASH = (_ET, _OPEN_MIN, _CLOSE_MIN)
_SESS_FUT = (_KST, 5 * 60 + 1, 22 * 60 + 30)


def _accumulate_spark(name: str, value: float, sess: tuple) -> list[list[float]]:
    """폴백 스파크라인: 폴링값을 세션(tz, open~close) 분 단위로 누적."""
    tz, o_min, c_min = sess
    now = datetime.now(tz)
    cur_min, date = now.hour * 60 + now.minute, now.strftime("%Y%m%d")
    rec = _series.get(name)
    if rec is None or rec["date"] != date:
        rec = {"date": date, "pts": {}}
        _series[name] = rec
    if o_min <= cur_min <= c_min:
        rec["pts"][cur_min] = value
    span = max(1, c_min - o_min)
    xy = [[(mn - o_min) / span, v] for mn, v in sorted(rec["pts"].items())]
    if len(xy) > _SPARK_POINTS:
        step = len(xy) / _SPARK_POINTS
        xy = [xy[int(i * step)] for i in range(_SPARK_POINTS)]
    return [[round(x, 4), round(v, 2)] for x, v in xy]


def _build_quote(ysym: str, csym: str, ssym: str, name: str, sess: tuple) -> dict:
    """한 종목(지수/선물)의 값·등락률·스파크라인 dict. 실패 시 last-good, 그것도 없으면 예외."""
    global _yahoo_cooldown_until
    try:
        price = prev = None
        spark: list[list[float]] | None = None

        if time.time() >= _yahoo_cooldown_until:   # 1순위 Yahoo (스파크라인까지)
            try:
                price, prev, spark = _yahoo(ysym)
            except Exception:
                _yahoo_cooldown_until = time.time() + 180  # 3분 백오프

        if price is None:                          # 값 폴백: CNBC → Stooq
            for src in (lambda: _cnbc(csym), lambda: _stooq(ssym)):
                try:
                    price, prev = src(); break
                except Exception:
                    continue
        if price is None or prev is None:
            raise ValueError("all sources failed")

        chg = price - prev
        if not spark:
            spark = _accumulate_spark(name, price, sess)
        res = {"key": ysym, "name": name, "value": round(price, 2),
               "change": round(chg, 2), "rate": round(chg / prev * 100, 2) if prev else 0.0,
               "up": chg >= 0, "spark": spark}
        _last_good[name] = res
        return res
    except Exception:
        if name in _last_good:
            return _last_good[name]
        raise


def _show_futures() -> bool:
    """KST 05:01~22:30 → 선물(US 현금장 마감 시간대). 22:31~05:00 → 지수 2개."""
    now = datetime.now(_KST)
    m = now.hour * 60 + now.minute
    return (5 * 60 + 1) <= m <= (22 * 60 + 30)


def get_indices() -> list[dict]:
    """KST 시간대에 따라 [선물 1개] 또는 [나스닥·S&P500] 반환 — 캐시(10s)."""
    if _cache["data"] and time.time() - _cache["ts"] < _TTL:
        return _cache["data"]

    if _show_futures():
        targets, sess = [_FUTURES], _SESS_FUT
    else:
        targets, sess = _INDICES, _SESS_CASH
    out: list[dict] = []
    for ysym, csym, ssym, name in targets:
        try:
            out.append(_build_quote(ysym, csym, ssym, name, sess))
        except Exception:
            continue

    if out:
        _cache["ts"] = time.time()
        _cache["data"] = out
    return out if out else _cache["data"]
