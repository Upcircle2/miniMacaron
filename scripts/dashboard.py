"""
miniMacaron 터미널 대시보드 (Phase 5 Swift 앱 전 임시 러너).

기본: REST 폴링 — inquire_present_balance 를 주기적으로 다시 불러 16종목 전부 갱신.
옵션: --ws — 해외 지연체결가 WebSocket 틱 수신 (단, 무료 피드 연결당 3종목 하드캡).

실행:
  uv run python scripts/dashboard.py                 # 30초 폴링 (Ctrl-C 종료)
  uv run python scripts/dashboard.py --interval 10    # 10초 폴링
  uv run python scripts/dashboard.py --once           # 1회 스냅샷
  uv run python scripts/dashboard.py --ws             # WS 틱 모드 (≤3종목 실시간)
"""
from __future__ import annotations

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend import balance, stream  # noqa: E402

_STATE: dict[str, dict] = {}      # symbol -> dict(name, qty, avg, cur, pchs_usd, excg)
_SUMMARY: dict[str, float] = {}
_LIVE: set[str] = set()           # WS 틱이 들어온 종목
_EXRT: float = 0.0


def _f(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def load_snapshot() -> None:
    """잔고 조회 → _STATE / _SUMMARY 갱신 (현재가 포함, 전 종목)."""
    global _EXRT
    df1, _df2, df3 = balance.fetch_present_balance(svr="prod")
    for _, r in df1.iterrows():
        sym = str(r["pdno"])
        _STATE[sym] = {
            "name": str(r["prdt_name"]),
            "qty": _f(r["cblc_qty13"]),
            "avg": _f(r["avg_unpr3"]),
            "cur": _f(r["ovrs_now_pric1"]),
            "pchs_usd": _f(r["frcr_pchs_amt"]),
            "excg": str(r["item_lnkg_excg_cd"]),
        }
    if not df3.empty:
        s = df3.iloc[0]
        _SUMMARY.update(
            tot_asst=_f(s["tot_asst_amt"]), pl=_f(s["tot_evlu_pfls_amt"]),
            rate=_f(s["evlu_erng_rt1"]), eval=_f(s["evlu_amt_smtl_amt"]),
            pchs=_f(s["pchs_amt_smtl_amt"]),
        )
    _EXRT = _f(df1.iloc[0]["bass_exrt"]) if not df1.empty else 0.0


def draw(note: str) -> None:
    print("\033[H\033[J", end="")
    now = datetime.now().strftime("%H:%M:%S")
    print(f"┌─ miniMacaron · 해외 잔고 ─ {now} ─ 환율 {_EXRT:,.2f} ─ {note}")
    print(f"│ 총자산 ₩{_SUMMARY.get('tot_asst',0):,.0f}   "
          f"평가손익 ₩{_SUMMARY.get('pl',0):,.0f} ({_SUMMARY.get('rate',0):+.2f}%)   "
          f"평가 ₩{_SUMMARY.get('eval',0):,.0f} / 매입 ₩{_SUMMARY.get('pchs',0):,.0f}")
    print("├" + "─" * 80)
    print(f"│ {'종목':<6}{'수량':>7}{'평단':>10}{'현재':>10}{'평가$':>12}{'손익$':>11}{'손익%':>9}  ")
    print("├" + "─" * 80)
    tot_pl = 0.0
    for sym, d in sorted(_STATE.items(), key=lambda kv: -kv[1]["qty"] * kv[1]["cur"]):
        evl = d["qty"] * d["cur"]
        pl = evl - d["pchs_usd"]
        plr = (pl / d["pchs_usd"] * 100) if d["pchs_usd"] else 0.0
        tot_pl += pl
        c = "\033[31m" if pl < 0 else "\033[32m"
        live = "●" if sym in _LIVE else " "
        print(f"│ {sym:<6}{d['qty']:>7.0f}{d['avg']:>10.2f}{d['cur']:>10.2f}"
              f"{evl:>12.2f}{c}{pl:>11.2f}{plr:>8.1f}%\033[0m {live}")
    print("└" + "─" * 80)
    print(f"  USD 평가손익 합계 ${tot_pl:,.2f}   (Ctrl-C 종료)")


def run_poll(interval: int) -> None:
    while True:
        load_snapshot()
        draw(f"REST 폴링 {interval}s · 전 종목 갱신")
        time.sleep(interval)


def run_ws() -> None:
    holdings = [(sym, d["excg"]) for sym, d in _STATE.items()]
    draw("WS 연결 중...")
    _last = [0.0]

    def on_tick(df: pd.DataFrame) -> None:
        for _, r in df.iterrows():
            sym = str(r.get("SYMB", "")).strip()
            if sym in _STATE:
                _STATE[sym]["cur"] = _f(r.get("LAST"))
                _LIVE.add(sym)
        if time.time() - _last[0] > 0.3:
            draw("WS 틱 수신 (●=실시간, 무료 캡 3종목)")
            _last[0] = time.time()

    stream.stream_prices(holdings, on_tick=on_tick, svr="prod")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true", help="1회 스냅샷 후 종료")
    parser.add_argument("--ws", action="store_true", help="WS 틱 모드 (≤3종목)")
    parser.add_argument("--interval", type=int, default=30, help="폴링 주기(초)")
    args = parser.parse_args()

    print("[INFO] 잔고 조회 중...")
    load_snapshot()

    try:
        if args.once:
            draw("스냅샷")
        elif args.ws:
            run_ws()
        else:
            run_poll(args.interval)
    except KeyboardInterrupt:
        print("\n[INFO] 종료.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
