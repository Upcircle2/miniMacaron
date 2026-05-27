"""
miniMacaron 백엔드 서버 실행 (localhost:8000, 외부 비노출).

실행:
  uv run python scripts/run_api.py
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import uvicorn  # noqa: E402

if __name__ == "__main__":
    uvicorn.run("backend.api:app", host="127.0.0.1", port=8000, reload=False)
