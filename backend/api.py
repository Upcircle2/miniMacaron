"""
miniMacaron FastAPI 백엔드 (localhost:8000) — Swift 메뉴바 앱이 붙는 REST 계약.

READ-ONLY: 잔고 조회만 노출. 주문 엔드포인트 없음.
127.0.0.1 바인딩 전제 (외부 비노출) — 실행은 scripts/run_api.py 참고.

엔드포인트:
  GET /health            {status, setup_complete}
  GET /balance/overseas  {exrt, summary, holdings[]}
  GET /balance/domestic  {summary, holdings[]}
"""
from __future__ import annotations

from fastapi import FastAPI, HTTPException

from backend import auth, balance

app = FastAPI(title="miniMacaron", version="0.1.0")


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "setup_complete": auth.is_setup_complete()}


def _snapshot(fn) -> dict:
    try:
        return fn(svr="prod")
    except KeyError as e:  # Keychain 키 누락 = setup 미완료
        raise HTTPException(status_code=412, detail=str(e))
    except Exception as e:  # KIS 통신/기타 오류
        raise HTTPException(status_code=502, detail=f"{type(e).__name__}: {e}")


@app.get("/balance/overseas")
def balance_overseas() -> dict:
    return _snapshot(balance.overseas_snapshot)


@app.get("/balance/domestic")
def balance_domestic() -> dict:
    return _snapshot(balance.domestic_snapshot)
