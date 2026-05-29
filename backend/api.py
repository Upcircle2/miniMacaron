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

import hmac

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from backend import auth, balance, indices, ipc

app = FastAPI(title="miniMacaron", version="0.1.0")

# 백엔드↔앱 공유 IPC 토큰 (무인증 localhost 호출 차단).
_TOKEN = ipc.get_or_create_token()


def require_token(authorization: str = Header(default="")) -> None:
    """Authorization: Bearer <token> 검증 (타이밍-세이프)."""
    if not hmac.compare_digest(authorization, f"Bearer {_TOKEN}"):
        raise HTTPException(status_code=401, detail="unauthorized")


@app.get("/health")
def health() -> dict:
    # liveness 용도 — 무인증 유지 (bool 만 노출).
    return {"status": "ok", "setup_complete": auth.is_setup_complete()}


class SetupKeys(BaseModel):
    app_key: str
    app_secret: str
    hts_id: str
    account_no: str


@app.post("/setup", dependencies=[Depends(require_token)])
def setup(keys: SetupKeys) -> dict:
    """실전 필수 키 4종을 Keychain에 저장 (Python keyring = Keychain 단일 소유자).

    키는 loopback(127.0.0.1)으로만 수신. 모의(paper) 키는 실전-only 정책상 받지 않음.
    """
    for field in ("app_key", "app_secret", "hts_id", "account_no"):
        value = getattr(keys, field).strip()
        if not value:
            raise HTTPException(status_code=422, detail=f"{field} 비어있음")
        auth.set_credential(field, value)
    auth.reset_bootstrap()  # 새 키로 재인증되도록 캐시 무효화
    return {"ok": True, "setup_complete": auth.is_setup_complete()}


def _snapshot(fn) -> dict:
    try:
        return fn(svr="prod")
    except KeyError as e:  # Keychain 키 누락 = setup 미완료
        raise HTTPException(status_code=412, detail=str(e))
    except Exception as e:  # KIS 통신/기타 오류
        raise HTTPException(status_code=502, detail=f"{type(e).__name__}: {e}")


@app.get("/balance/overseas", dependencies=[Depends(require_token)])
def balance_overseas() -> dict:
    return _snapshot(balance.overseas_snapshot)


@app.get("/balance/domestic", dependencies=[Depends(require_token)])
def balance_domestic() -> dict:
    return _snapshot(balance.domestic_snapshot)


@app.get("/indices", dependencies=[Depends(require_token)])
def market_indices() -> list[dict]:
    """나스닥 종합 · S&P500 — 값/등락률/장중 스파크라인."""
    try:
        return indices.get_indices()
    except Exception:
        return []
