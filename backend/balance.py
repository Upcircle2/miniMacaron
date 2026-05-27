"""
주식 잔고 조회 (READ-ONLY).

공식 잔고 함수만 selective import:
  해외: inquire_present_balance (TR CTRP6504R) → (df1 종목별, df2 외화별, df3 종합)
  국내: inquire_balance         (TR TTTC8434R) → (df1 종목별, df2 종합)
주문 함수(order/daytime_order/order_resv/order_rvsecncl 등)는 일체 참조·호출하지 않음.
"""
from __future__ import annotations

import sys
import threading
from typing import Literal

import pandas as pd

from backend import auth

# 공식 kis_auth 전역 상태(_base_headers 등)는 스레드 안전하지 않음.
# FastAPI 스레드풀의 동시 요청이 KIS 호출에서 레이스 나지 않도록 직렬화.
_KIS_LOCK = threading.Lock()

# KIS rate-limit(EGW00201) 등 일시 오류 시 공식 함수는 빈 DataFrame을 반환한다.
# 그대로 내보내면 클라이언트가 빈 요약을 받게 되므로, 직전 정상 스냅샷을 재사용.
_LAST_GOOD: dict[str, dict] = {}


def _f(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def fetch_present_balance(
    svr: Literal["prod", "vps"] = "prod",
    wcrc_frcr_dvsn_cd: str = "02",  # 01: 원화, 02: 외화
    natn_cd: str = "000",           # 000: 전체 (840 미국 / 392 일본 / 344 홍콩 / 156 중국)
    tr_mket_cd: str = "00",         # 00: 전체
    inqr_dvsn_cd: str = "00",       # 00: 전체
) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """Keychain 부트스트랩 → 공식 잔고 함수 호출 → (종목별, 외화별, 종합) 반환."""
    ka, trenv = auth.bootstrap(svr=svr)

    # READ-ONLY 가드: 잔고 조회 함수 1개만 import (order* 미참조)
    osf_dir = auth.KIS_PATH / "examples_user" / "overseas_stock"
    if str(osf_dir) not in sys.path:
        sys.path.insert(0, str(osf_dir))
    from overseas_stock_functions import inquire_present_balance  # noqa: E402

    env_dv = "real" if svr == "prod" else "demo"

    with _KIS_LOCK:
        return inquire_present_balance(
            cano=trenv.my_acct,
            acnt_prdt_cd=trenv.my_prod,
            wcrc_frcr_dvsn_cd=wcrc_frcr_dvsn_cd,
            natn_cd=natn_cd,
            tr_mket_cd=tr_mket_cd,
            inqr_dvsn_cd=inqr_dvsn_cd,
            env_dv=env_dv,
        )


def fetch_domestic_balance(
    svr: Literal["prod", "vps"] = "prod",
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """국내주식 잔고 조회 → (df1 종목별, df2 종합요약)."""
    ka, trenv = auth.bootstrap(svr=svr)

    # READ-ONLY 가드: 잔고 조회 함수 1개만 import (order* 미참조)
    dsf_dir = auth.KIS_PATH / "examples_user" / "domestic_stock"
    if str(dsf_dir) not in sys.path:
        sys.path.insert(0, str(dsf_dir))
    from domestic_stock_functions import inquire_balance  # noqa: E402

    env_dv = "real" if svr == "prod" else "demo"

    with _KIS_LOCK:
        return inquire_balance(
            env_dv=env_dv,
            cano=trenv.my_acct,
            acnt_prdt_cd=trenv.my_prod,
            afhr_flpr_yn="N",            # 시간외단일가 미적용
            inqr_dvsn="02",              # 02: 종목별
            unpr_dvsn="01",
            fund_sttl_icld_yn="N",
            fncg_amt_auto_rdpt_yn="N",
            prcs_dvsn="00",              # 00: 전일매매 포함
        )


# ──────────────────────────────────────────────────────────────────────────
# JSON 스냅샷 (대시보드 / FastAPI 공용 — KIS DataFrame → UI용 dict)
# ──────────────────────────────────────────────────────────────────────────
def overseas_snapshot(svr: Literal["prod", "vps"] = "prod") -> dict:
    """해외 잔고를 UI용 dict로: {exrt, summary, holdings}."""
    df1, _df2, df3 = fetch_present_balance(svr=svr)

    holdings = []
    for _, r in df1.iterrows():
        qty = _f(r["cblc_qty13"])
        cur = _f(r["ovrs_now_pric1"])
        pchs = _f(r["frcr_pchs_amt"])
        evl = qty * cur
        pl = evl - pchs
        holdings.append({
            "symbol": str(r["pdno"]),
            "name": str(r["prdt_name"]),
            "qty": qty,
            "avg": _f(r["avg_unpr3"]),
            "cur": cur,
            "pchs_usd": round(pchs, 2),
            "eval_usd": round(evl, 2),
            "pl_usd": round(pl, 2),
            "pl_rate": round(pl / pchs * 100, 2) if pchs else 0.0,
            "excg": str(r["item_lnkg_excg_cd"]),
        })

    summary = {}
    if not df3.empty:
        s = df3.iloc[0]
        summary = {
            "tot_asset_krw": _f(s["tot_asst_amt"]),
            "eval_pl_krw": _f(s["tot_evlu_pfls_amt"]),
            "eval_rate": _f(s["evlu_erng_rt1"]),
            "eval_krw": _f(s["evlu_amt_smtl_amt"]),
            "pchs_krw": _f(s["pchs_amt_smtl_amt"]),
        }

    exrt = _f(df1.iloc[0]["bass_exrt"]) if not df1.empty else 0.0
    result = {"exrt": exrt, "summary": summary, "holdings": holdings}

    # 요약이 비면 KIS 일시 오류(rate-limit 등) → 직전 정상 스냅샷 재사용
    if not summary:
        return _LAST_GOOD.get("overseas", result)
    _LAST_GOOD["overseas"] = result
    return result


def domestic_snapshot(svr: Literal["prod", "vps"] = "prod") -> dict:
    """국내 잔고를 UI용 dict로: {summary, holdings}."""
    df1, df2 = fetch_domestic_balance(svr=svr)

    holdings = []
    for _, r in df1.iterrows():
        holdings.append({
            "symbol": str(r.get("pdno", "")),
            "name": str(r.get("prdt_name", "")),
            "qty": _f(r.get("hldg_qty")),
            "avg": _f(r.get("pchs_avg_pric")),
            "cur": _f(r.get("prpr")),
            "eval_krw": _f(r.get("evlu_amt")),
            "pl_krw": _f(r.get("evlu_pfls_amt")),
            "pl_rate": _f(r.get("evlu_pfls_rt")),
        })

    summary = {}
    if not df2.empty:
        s = df2.iloc[0]
        summary = {
            "tot_eval_krw": _f(s.get("tot_evlu_amt")),
            "nass_krw": _f(s.get("nass_amt")),
            "eval_pl_krw": _f(s.get("evlu_pfls_smtl_amt")),
            "pchs_krw": _f(s.get("pchs_amt_smtl_amt")),
            "dnca_krw": _f(s.get("dnca_tot_amt")),
        }

    result = {"summary": summary, "holdings": holdings}

    # 국내는 보유 0이어도 요약(df2)이 채워짐 → 요약이 비면 KIS 일시 오류로 간주
    if not summary:
        return _LAST_GOOD.get("domestic", result)
    _LAST_GOOD["domestic"] = result
    return result
