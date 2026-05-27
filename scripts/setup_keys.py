"""
CLI 키 입력 도구 — Swift Setup UI의 백엔드 역할 (개발/테스트용).

사용:
  uv run python scripts/setup_keys.py            # 인터랙티브 입력
  uv run python scripts/setup_keys.py --check    # 등록 여부만 확인
"""
from __future__ import annotations

import argparse
import getpass
import sys
from pathlib import Path

# 프로젝트 루트를 path에 추가 (backend 모듈 import용)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend import auth  # noqa: E402


PROMPTS: list[tuple[str, str, bool]] = [
    # (key, label, is_secret)
    ("app_key",          "실전 App Key                    ", False),
    ("app_secret",       "실전 App Secret (입력 안 보임)  ", True),
    ("paper_app_key",    "모의 App Key                    ", False),
    ("paper_app_secret", "모의 App Secret (입력 안 보임)  ", True),
    ("hts_id",           "HTS ID                          ", False),
    ("account_no",       "실전 계좌번호 (앞 8자리)        ", False),
    ("paper_account_no", "모의 계좌번호 (앞 8자리)        ", False),
]


def interactive_setup() -> int:
    print("=" * 60)
    print(" miniMacaron — 키 등록 (macOS Keychain 저장)")
    print("=" * 60)
    print(" Service:  com.minimacaron.kis")
    print(" 입력값은 OS-level 암호화로 안전하게 보관됩니다.")
    print(" 변경/삭제: scripts/clear_keys.py")
    print("=" * 60)
    print()

    for key, label, is_secret in PROMPTS:
        prompt = f"{label}: "
        v = getpass.getpass(prompt) if is_secret else input(prompt).strip()
        if not v:
            print(f"\n[FAIL] '{key}' 비어있음. 중단.")
            return 1
        auth.set_credential(key, v)
        print(f"  [OK] {key} 저장됨")

    print("\n✅ 모든 키 등록 완료.")
    print("   다음 단계: uv run python scripts/verify_auth.py --paper")
    return 0


def check() -> int:
    try:
        creds = auth.get_credentials()
    except KeyError as e:
        print(f"[FAIL] {e}")
        return 1

    print("Keychain에 등록된 키:")
    for k in auth.KEYS:
        v = creds[k]
        masked = (
            f"***{v[-4:]}" if "secret" in k.lower() or "key" in k.lower()
            else v
        )
        print(f"  {k:20s} = {masked}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--check", action="store_true",
                   help="등록 여부만 확인 (값은 마스킹)")
    args = p.parse_args()
    return check() if args.check else interactive_setup()


if __name__ == "__main__":
    raise SystemExit(main())
