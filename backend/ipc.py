"""
로컬 IPC 토큰 — Swift 앱 ↔ Python 백엔드 사이 공유 비밀.

백엔드와 앱만 아는 랜덤 토큰을 요구해, 같은 맥의 임의 프로세스가
무인증으로 localhost API(잔고 조회/키 설정)를 호출하는 것을 막는다(심층방어).

저장: ~/Library/Application Support/miniMacaron/ipc.token (dir 700 / file 600)
  - 환경변수 MINIMACARON_TOKEN 이 있으면 그것을 사용(미래: 앱이 백엔드 spawn 시 주입,
    디스크 미사용으로 강화).
"""
from __future__ import annotations

import os
import secrets
from pathlib import Path

_DIR = Path.home() / "Library" / "Application Support" / "miniMacaron"
_FILE = _DIR / "ipc.token"


def get_or_create_token() -> str:
    """공유 토큰 반환. env > 기존 파일 > 신규 생성 순."""
    env = os.environ.get("MINIMACARON_TOKEN")
    if env:
        return env.strip()

    if _FILE.exists():
        existing = _FILE.read_text(encoding="utf-8").strip()
        if existing:
            return existing

    _DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(_DIR, 0o700)
    token = secrets.token_urlsafe(32)
    _FILE.write_text(token, encoding="utf-8")
    os.chmod(_FILE, 0o600)
    return token
