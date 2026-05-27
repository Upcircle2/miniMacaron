"""Keychain의 모든 miniMacaron 키 삭제."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend import auth  # noqa: E402


def main() -> int:
    print(f"Service: {auth.SERVICE}")
    print(f"삭제 대상 키: {list(auth.KEYS)}")
    confirm = input("\n정말 모든 키를 삭제하시겠습니까? (yes/no): ").strip().lower()
    if confirm != "yes":
        print("취소.")
        return 0
    n = auth.clear_all_credentials()
    print(f"\n✅ {n}개 키 삭제 완료.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
