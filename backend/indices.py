"""
해외 주요 지수 (나스닥 종합 · S&P500) — 값/등락률/장중 스파크라인 (비-KIS, READ-ONLY).

KIS 지수분봉은 최근 ~100분 제약이 있어, 외부 무료 소스를 사용:
  1순위 Yahoo Finance 차트(/v8/finance/chart) — 풀데이 1분봉 + 현재가 + 전일종가
       (단, 데이터센터 IP는 429로 막힐 수 있음 → 실패 시 쿨다운 후 폴백)
  폴백   Stooq 시세(/q/l, 키 없음) — 현재가 + 전일종가. 스파크라인은 폴링값을 세션 누적.

스파크라인 x축 = ET 정규장 09:30(0)~16:00(1). 지수별 last-good 로 일시 실패 시 깜빡임 방지.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

# (yahoo_sym, stooq_sym, 표시이름)
_INDICES = [("^IXIC", "^ndq", "나스닥"), ("^GSPC", "^spx", "S&P 500")]
_TTL = 10
_OPEN_MIN = 9 * 60 + 30
_CLOSE_MIN = 16 * 60
_SESSION = _CLOSE_MIN - _OPEN_MIN
_SPARK_POINTS = 80
_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
_ET = ZoneInfo("America/New_York")

_cache: dict = {"ts": 0.0, "data": []}
_last_good: dict[str, dict] = {}   # name -> result (깜빡임 방지)
_series: dict[str, dict] = {}      # name -> {"date":, "pts": {et_min: value}} (누적 폴백)
_yahoo_cooldown_until = 0.0        # Yahoo 차단 시 재시도 쿨다운


def _http(url: str, timeout: int = 8) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": _UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def _yahoo(symbol: str) -> tuple[float, float, list[list[float]]]:
    """(현재가, 전일종가, 풀데이 스파크라인[[x,v]]). 실패 시 예외.

    x축은 timestamp 를 ET 시각(09:30~16:00)으로 변환해 매핑 — meta.currentTradingPeriod
    구조에 의존하지 않아 지수별로 견고함.
    """
    url = (f"https://query1.finance.yahoo.com/v8/finance/chart/"
           f"{urllib.parse.quote(symbol)}?interval=1m&range=1d")
    res = json.loads(_http(url))["chart"]["result"][0]
    m = res.get("meta", {})
    ts = res.get("timestamp") or []
    quote = (res.get("indicators", {}).get("quote") or [{}])[0]
    closes = quote.get("close") or []
    pts = [(t, c) for t, c in zip(ts, closes) if c is not None]
    if not pts:
        raise ValueError("no intraday data")

    price = m.get("regularMarketPrice")
    price = float(price) if price is not None else float(pts[-1][1])
    prev = m.get("chartPreviousClose")
    if prev is None:
        prev = m.get("previousClose")
    prev = float(prev) if prev is not None else float(pts[0][1])

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


def _stooq(stooq_sym: str) -> tuple[float, float]:
    """(현재가, 전일종가) — Stooq /q/l (키 없음)."""
    txt = _http(f"https://stooq.com/q/l/?s={urllib.parse.quote(stooq_sym)}&f=sd2t2ohlcvp&h&e=csv")
    parts = txt.strip().splitlines()[-1].split(",")
    return float(parts[6]), float(parts[8])  # close(현재가), prevclose


def _accumulate_spark(name: str, value: float) -> list[list[float]]:
    """폴백: 폴링값을 ET 세션 분 단위로 누적해 스파크라인 생성."""
    now = datetime.now(_ET)
    et_min, date = now.hour * 60 + now.minute, now.strftime("%Y%m%d")
    rec = _series.get(name)
    if rec is None or rec["date"] != date:
        rec = {"date": date, "pts": {}}
        _series[name] = rec
    if _OPEN_MIN <= et_min <= _CLOSE_MIN:
        rec["pts"][et_min] = value
    xy = [[(mn - _OPEN_MIN) / _SESSION, v] for mn, v in sorted(rec["pts"].items())]
    if len(xy) > _SPARK_POINTS:
        step = len(xy) / _SPARK_POINTS
        xy = [xy[int(i * step)] for i in range(_SPARK_POINTS)]
    return [[round(x, 4), round(v, 2)] for x, v in xy]


def get_indices() -> list[dict]:
    """[{key, name, value, change, rate, up, spark[[x,v]]}] — 캐시(10s) 후 재사용."""
    global _yahoo_cooldown_until
    if _cache["data"] and time.time() - _cache["ts"] < _TTL:
        return _cache["data"]

    out: list[dict] = []
    for ysym, ssym, name in _INDICES:
        try:
            price = prev = None
            spark: list[list[float]] | None = None
            if time.time() >= _yahoo_cooldown_until:
                try:
                    price, prev, spark = _yahoo(ysym)
                except Exception:
                    _yahoo_cooldown_until = time.time() + 300  # 5분 백오프
            if price is None:
                price, prev = _stooq(ssym)

            chg = price - prev
            rate = (chg / prev * 100) if prev else 0.0
            if not spark:  # Yahoo 미사용/실패 → 누적 스파크라인
                spark = _accumulate_spark(name, price)

            res = {"key": ysym, "name": name, "value": round(price, 2),
                   "change": round(chg, 2), "rate": round(rate, 2),
                   "up": chg >= 0, "spark": spark}
            _last_good[name] = res
            out.append(res)
        except Exception:
            if name in _last_good:   # 일시 실패 시 직전값 유지(깜빡임 방지)
                out.append(_last_good[name])

    if out:
        _cache["ts"] = time.time()
        _cache["data"] = out
    return out if out else _cache["data"]
