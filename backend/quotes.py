"""
전일 종가 캐시 — 오늘 등락률 계산용 (READ-ONLY).

등락률 = (현재가 − 전일종가) / 전일종가 × 100.
현재가는 잔고 API가 0.5초마다 주므로, 장중 고정값인 '전일종가'만 가끔 조회해 캐시한다.
  - 해외: price() (HHDFS00000300) 의 base.  배치 없음 → 스냅샷당 최대 N개만 채움(스태거드).
  - 국내: intstock_multprice() (FHKST11300006) 의 inter2_prdy_clpr.  한 콜 최대 30종목.

주문 함수는 일체 import·참조하지 않음.
"""
from __future__ import annotations

import sys
import time

from backend import auth

_TTL = 3 * 3600                       # 전일종가는 장중 고정 → 수시간 캐시 (장 롤오버 대비)
_MAX_FILL_PER_CALL = 1               # 해외: 스냅샷당 신규 조회 1개 (가장 완만 — 램프 EGW 최소화)
_prev_close: dict[str, tuple[float, float]] = {}   # symbol -> (ts, prev_close)


def _fresh(symbol: str) -> float | None:
    rec = _prev_close.get(symbol)
    if rec and (time.time() - rec[0]) < _TTL:
        return rec[1]
    return None


def _f(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


# ── 해외 ──────────────────────────────────────────────────────────────────
def overseas_prev_close_map(holdings: list[tuple[str, str]]) -> dict[str, float]:
    """holdings: [(symbol, excd)]. 캐시된 전일종가 맵 + 미보유분은 스냅샷당 ≤N개만 신규 조회."""
    from backend import balance  # 지연 import (순환 회피)

    osf_dir = auth.KIS_PATH / "examples_user" / "overseas_stock"
    if str(osf_dir) not in sys.path:
        sys.path.insert(0, str(osf_dir))

    result: dict[str, float] = {}
    fills = 0
    price = None
    for sym, excd in holdings:
        pc = _fresh(sym)
        if pc is None and fills < _MAX_FILL_PER_CALL:
            if price is None:
                from overseas_stock_functions import price as _price  # READ-ONLY
                price = _price
            try:
                with balance.kis_guard():  # 콜 단위 락 + throttle → 잔고 폴링과 인터리브
                    df = price("", excd, sym)
                if df is not None and not df.empty:
                    base = _f(df.iloc[0]["base"])
                    if base > 0:
                        _prev_close[sym] = (time.time(), base)
                        pc = base
                        fills += 1
            except Exception:
                pass
        if pc is not None:
            result[sym] = pc
    return result


# ── 국내 ──────────────────────────────────────────────────────────────────
def domestic_prev_close_map(symbols: list[str]) -> dict[str, float]:
    """symbols: [6자리 종목코드]. 캐시 + 미보유분을 intstock_multprice(≤30) 한 콜로 채움."""
    from backend import balance

    result = {s: pc for s in symbols if (pc := _fresh(s)) is not None}
    missing = [s for s in symbols if s not in result][:30]
    if not missing:
        return result

    dsf_dir = auth.KIS_PATH / "examples_user" / "domestic_stock"
    if str(dsf_dir) not in sys.path:
        sys.path.insert(0, str(dsf_dir))
    from domestic_stock_functions import intstock_multprice  # READ-ONLY

    kwargs: dict[str, str] = {}
    for i, s in enumerate(missing, 1):
        kwargs[f"fid_cond_mrkt_div_code_{i}"] = "J"
        kwargs[f"fid_input_iscd_{i}"] = s
    try:
        with balance.kis_guard():
            df = intstock_multprice(**kwargs)
        if df is not None and not df.empty:
            for _, r in df.iterrows():
                sym = str(r.get("inter_shrn_iscd", "")).strip()
                pc = _f(r.get("inter2_prdy_clpr"))
                if sym and pc > 0:
                    _prev_close[sym] = (time.time(), pc)
                    result[sym] = pc
    except Exception:
        pass
    return result
