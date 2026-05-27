"""
Phase 2 검증 — 실전 해외주식 체결기준현재잔고 조회.

실행:
  uv run python scripts/test_balance.py           # 외화 기준 (기본)
  uv run python scripts/test_balance.py --won      # 원화 기준 (wcrc_frcr_dvsn_cd=01)
  uv run python scripts/test_balance.py --paper     # 모의투자 (사용 안 하지만 옵션 유지)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend import balance  # noqa: E402


def _show(title: str, df: pd.DataFrame) -> None:
    print(f"\n{'='*70}\n{title}  (rows={len(df)}, cols={len(df.columns)})\n{'='*70}")
    if df.empty:
        print("  (비어있음)")
        return
    print("columns:", list(df.columns))
    print(df.to_string(index=False))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--won", action="store_true", help="원화 기준 (기본: 외화)")
    parser.add_argument("--paper", action="store_true", help="모의투자")
    args = parser.parse_args()

    svr = "vps" if args.paper else "prod"
    wcrc = "01" if args.won else "02"
    label = "모의" if args.paper else "실전"
    print(f"[INFO] {label} 해외 잔고 조회 (wcrc_frcr_dvsn_cd={wcrc}, natn_cd=000 전체)")

    pd.set_option("display.max_columns", None)
    pd.set_option("display.width", 200)

    try:
        df1, df2, df3 = balance.fetch_present_balance(svr=svr, wcrc_frcr_dvsn_cd=wcrc)
    except Exception as e:
        print(f"[FAIL] {type(e).__name__}: {e}")
        return 1

    _show("output1 — 종목별 잔고", df1)
    _show("output2 — 외화별 잔고", df2)
    _show("output3 — 종합 요약", df3)

    print("\n✅ 잔고 조회 완료.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
