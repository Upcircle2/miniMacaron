"""
해외주식 실시간 지연체결가 스트림 (READ-ONLY).

공식 delayed_ccnl (TR HDFSCNT0) 1개만 selective import.
  - 미국: 0분 지연(실시간 무료),  아시아: 15분 지연
  - tr_key 형식: 'D' + 거래소(NAS/NYS/AMS/HKS/TSE) + symbol  (예: DNASAMD)
  - 미국장 마감 시 메시지 미수신 (CLAUDE.md §6) → 연결만 유지하고 대기

주문 함수는 일체 참조·호출하지 않음.
"""
from __future__ import annotations

import sys
from typing import Callable

import pandas as pd

from backend import auth

# 잔고 API의 거래소 코드(ovrs_excg_cd / item_lnkg_excg_cd) → WS tr_key 거래소 코드
_EXCG_MAP = {
    "NASD": "NAS", "NYSE": "NYS", "AMEX": "AMS",
    "NAS": "NAS", "NYS": "NYS", "AMS": "AMS",
    "HKS": "HKS", "TSE": "TSE",
}


def build_tr_key(symbol: str, excg_code: str) -> str:
    """'D' + 거래소 + 심볼 → 지연체결가 구독 키."""
    return f"D{_EXCG_MAP.get(excg_code, excg_code)}{symbol}"


def stream_prices(
    holdings: list[tuple[str, str]],
    on_tick: Callable[[pd.DataFrame], None],
    svr: str = "prod",
) -> None:
    """지연체결가 구독 시작 (blocking).

    Args:
        holdings: (symbol, 거래소코드) 리스트. 예: [("AMD", "NAS"), ("DELL", "NYS")]
        on_tick:  체결 1건 도착 시 호출. 인자는 컬럼명이 붙은 DataFrame.
        svr:      "prod" / "vps"
    """
    ka, _ = auth.bootstrap(svr=svr)

    ws_dir = auth.KIS_PATH / "examples_user" / "overseas_stock"
    if str(ws_dir) not in sys.path:
        sys.path.insert(0, str(ws_dir))
    from overseas_stock_functions_ws import delayed_ccnl  # noqa: E402

    keys = [build_tr_key(sym, ex) for sym, ex in holdings]

    kws = ka.KISWebSocket(api_url="/tryitout")
    kws.subscribe(request=delayed_ccnl, data=keys)

    def _on_result(ws, tr_id, result: pd.DataFrame, data_info) -> None:
        on_tick(result)

    kws.start(on_result=_on_result)  # asyncio 이벤트 루프 — Ctrl-C 까지 blocking
