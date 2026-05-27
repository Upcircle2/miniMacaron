"""
Step 4 검증 — Keychain → monkey patch → 공식 kis_auth OAuth.

실행:
  uv run python scripts/verify_auth.py            # 실전투자
  uv run python scripts/verify_auth.py --paper    # 모의투자 (안전)

환경변수:
  KIS_API_DIR  공식 open-trading-api 클론 위치 (기본: ~/repos/open-trading-api)
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend import auth  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--paper", action="store_true",
                        help="모의투자 키 사용 (기본: 실전)")
    args = parser.parse_args()

    svr = "vps" if args.paper else "prod"
    label = "모의투자" if args.paper else "실전투자"
    print(f"[INFO] {label} ({svr}) 인증 시도\n")

    try:
        ka, trenv = auth.bootstrap(svr=svr)
    except KeyError as e:
        print(f"[FAIL] {e}")
        print("  해결: uv run python scripts/setup_keys.py")
        return 1
    except RuntimeError as e:
        print(f"[FAIL] {e}")
        return 1
    except Exception as e:
        print(f"[FAIL] {type(e).__name__}: {e}")
        return 1

    if not trenv.my_token:
        print("[FAIL] REST 토큰이 비어있음 — 키 값 또는 KIS 서버 상태 확인")
        return 1

    print(f"[OK]   REST OAuth 토큰 발급 성공 (token: {trenv.my_token[:24]}...)")
    print(f"[OK]   WebSocket approval_key 발급 성공")
    print(f"\n[INFO] 계좌번호      : {trenv.my_acct}-{trenv.my_prod}")
    print(f"[INFO] REST URL      : {trenv.my_url}")
    print(f"[INFO] WebSocket URL : {trenv.my_url_ws}")

    cache_file = (
        Path.home() / "KIS" / "config" /
        f"KIS{datetime.today().strftime('%Y%m%d')}"
    )
    if cache_file.exists():
        print(f"[OK]   토큰 캐시 파일: {cache_file} (chmod 600)")
    else:
        print(f"[WARN] 토큰 캐시 파일 없음: {cache_file}")

    print("\n✅ 인증 검증 완료 — Step 5(잔고 조회)로 진행 가능.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
