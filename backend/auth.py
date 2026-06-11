"""
Keychain 기반 KIS 인증 어댑터.

키는 macOS Keychain에 저장:
  Service:  com.minimacaron.kis
  Accounts: app_key, app_secret, paper_app_key, paper_app_secret,
            hts_id, account_no, paper_account_no

bootstrap() 호출 시:
  1. Keychain에서 키 로드
  2. yaml.load monkey-patch (import 1회용)
  3. 공식 kis_auth import
  4. ka.auth() + ka.auth_ws() 호출
  5. (ka 모듈, trenv namedtuple) 반환
"""
from __future__ import annotations

import os
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Literal

import keyring
import requests.adapters
import yaml

# ──────────────────────────────────────────────────────────────────────────
# requests 기본 타임아웃 강제 (공식 KIS 코드는 requests.get/post 에 timeout 미지정 →
# KIS가 응답을 멈추면 SSL read 가 영원히 블록 → _KIS_LOCK 점유 → 스레드풀 고갈 →
# 백엔드 전체 행. 공식 코드 fork 없이 HTTPAdapter.send 에 기본 타임아웃을 주입한다.)
# ──────────────────────────────────────────────────────────────────────────
_HTTP_TIMEOUT = (5, 8)  # (connect, read) 초. 정상 KIS 응답 <2s 라 넉넉, 행은 ≤8s 후 끊김.


def _install_requests_timeout() -> None:
    adapter = requests.adapters.HTTPAdapter
    if getattr(adapter, "_minimacaron_timeout_patched", False):
        return
    _orig_send = adapter.send

    def _send(self, request, **kwargs):  # noqa: ANN001
        if kwargs.get("timeout") is None:
            kwargs["timeout"] = _HTTP_TIMEOUT
        return _orig_send(self, request, **kwargs)

    adapter.send = _send
    adapter._minimacaron_timeout_patched = True


_install_requests_timeout()

# ──────────────────────────────────────────────────────────────────────────
# 상수
# ──────────────────────────────────────────────────────────────────────────
SERVICE = "com.minimacaron.kis"

# Keychain에 저장 가능한 전체 키 목록
KEYS: tuple[str, ...] = (
    "app_key",
    "app_secret",
    "paper_app_key",
    "paper_app_secret",
    "hts_id",
    "account_no",
    "paper_account_no",
)

# 실전(prod) 동작에 반드시 필요한 키. paper_* 는 모의투자 전용이라 optional.
REQUIRED_KEYS: tuple[str, ...] = (
    "app_key",
    "app_secret",
    "hts_id",
    "account_no",
)

_DEFAULT_KIS_PATH = Path.home() / "repos" / "open-trading-api"
KIS_PATH = Path(os.environ.get("KIS_API_DIR", _DEFAULT_KIS_PATH))

KIS_CONFIG_DIR = Path.home() / "KIS" / "config"
KIS_YAML_PATH = KIS_CONFIG_DIR / "kis_devlp.yaml"


# ──────────────────────────────────────────────────────────────────────────
# Keychain CRUD
# ──────────────────────────────────────────────────────────────────────────
def get_credentials() -> dict[str, str]:
    """Keychain에서 키 로드. 실전 필수 키 누락 시 KeyError.

    paper_* 키는 optional — 있으면 포함, 없으면 생략.
    """
    creds: dict[str, str] = {}
    for k in KEYS:
        v = keyring.get_password(SERVICE, k)
        if v is not None:
            creds[k] = v
    missing = [k for k in REQUIRED_KEYS if k not in creds]
    if missing:
        raise KeyError(
            f"Keychain에 실전 필수 키 없음: {missing}. "
            f"`uv run python scripts/setup_keys.py` 실행 필요."
        )
    return creds


def set_credential(key: str, value: str) -> None:
    if key not in KEYS:
        raise ValueError(f"알 수 없는 키: {key}. 허용: {KEYS}")
    keyring.set_password(SERVICE, key, value)


def clear_all_credentials() -> int:
    """모든 키 삭제. 삭제된 개수 반환."""
    count = 0
    for k in KEYS:
        try:
            keyring.delete_password(SERVICE, k)
            count += 1
        except keyring.errors.PasswordDeleteError:
            pass
    return count


def is_setup_complete() -> bool:
    """모든 필수 키가 Keychain에 있는지 확인."""
    try:
        get_credentials()
        return True
    except KeyError:
        return False


# ──────────────────────────────────────────────────────────────────────────
# 공식 kis_auth 부트스트랩
# ──────────────────────────────────────────────────────────────────────────
def _build_cfg_dict(creds: dict[str, str]) -> dict:
    """공식 kis_auth가 기대하는 _cfg dict 포맷."""
    return {
        "my_app": creds["app_key"],
        "my_sec": creds["app_secret"],
        "paper_app": creds.get("paper_app_key", ""),
        "paper_sec": creds.get("paper_app_secret", ""),
        "my_htsid": creds["hts_id"],
        "my_acct_stock": creds["account_no"],
        "my_acct_future": creds["account_no"],
        "my_paper_stock": creds.get("paper_account_no", ""),
        "my_paper_future": creds.get("paper_account_no", ""),
        "my_prod": "01",
        "prod": "https://openapi.koreainvestment.com:9443",
        "ops": "ws://ops.koreainvestment.com:21000",
        "vps": "https://openapivts.koreainvestment.com:29443",
        "vops": "ws://ops.koreainvestment.com:31000",
        "my_token": "",
        "my_agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/120.0.0.0 Safari/537.36"
        ),
    }


def _ensure_kis_config_dir() -> None:
    """~/KIS/config 디렉토리 + 빈 yaml 파일 생성 (보안 권한 설정)."""
    KIS_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(KIS_CONFIG_DIR, 0o700)
    # 공식 kis_auth가 open()으로 존재 확인 → 빈 파일이라도 필요
    if not KIS_YAML_PATH.exists():
        KIS_YAML_PATH.touch()
    os.chmod(KIS_YAML_PATH, 0o600)


@contextmanager
def _patched_yaml_load(cfg_dict: dict):
    """yaml.load를 cfg_dict 반환 함수로 일시 교체."""
    original = yaml.load

    def _stub(stream, *args, **kwargs):
        return cfg_dict

    yaml.load = _stub
    try:
        yield
    finally:
        yaml.load = original


# bootstrap 1회 캐시 — 매 요청마다 재실행하면 전역 yaml monkey-patch / auth_ws 가
# FastAPI 스레드풀 동시요청에서 레이스를 일으킴. 1회만 수행하고 (ka, trenv) 재사용.
_BOOTSTRAP_LOCK = threading.Lock()
_BOOTSTRAP_CACHE: dict[str, tuple] = {}
# 부트스트랩 실패 직후 쿨다운 — KIS 토큰 발급은 '분당 1회' 제한(EGW00133)이라, 첫 실패 후
# 0.5초 폴링이 매번 발급을 재시도하면 rate-limit 에 영구 고착된다. 실패하면 잠시 쉬었다 재시도.
_BOOTSTRAP_RETRY_COOLDOWN = 20.0
_bootstrap_fail_until = [0.0]


def reset_bootstrap() -> None:
    """키 변경(POST /setup) 후 캐시 무효화 — 다음 bootstrap 이 새 키로 재인증."""
    with _BOOTSTRAP_LOCK:
        _BOOTSTRAP_CACHE.clear()
        _bootstrap_fail_until[0] = 0.0


def bootstrap(svr: Literal["prod", "vps"] = "prod"):
    """Keychain → kis_auth OAuth. import/monkey-patch 는 1회, 토큰은 매 호출 재검증.

    캐시 히트 시 ka.auth() 로 토큰을 재검증한다(유효하면 캐시 재사용, 만료(EGW00123)면 재발급).
    kis_auth.reAuth 는 _last_auth_time 24h 기준이라 '캐시된 오래된 토큰'엔 안 맞아 직접 갱신.
    최초 실행이 토큰 발급 제한(분당1회)에 걸리면 쿨다운 후 자동 복구.
    """
    with _BOOTSTRAP_LOCK:
        if svr in _BOOTSTRAP_CACHE:
            ka, _ = _BOOTSTRAP_CACHE[svr]
            _refresh_token(ka, svr)
            _BOOTSTRAP_CACHE[svr] = (ka, ka.getTREnv())
            return _BOOTSTRAP_CACHE[svr]
        # 미캐시(최초/이전 실패). 직전 실패 쿨다운 중이면 발급 재시도 없이 즉시 명확한 에러.
        if time.monotonic() < _bootstrap_fail_until[0]:
            raise RuntimeError(
                "KIS 인증 재시도 대기 중 — 토큰 발급 분당 1회 제한(EGW00133). "
                "새 기기 최초 실행 시 1~2분 내 자동 복구됩니다."
            )
        try:
            result = _do_bootstrap(svr)
        except Exception:
            _bootstrap_fail_until[0] = time.monotonic() + _BOOTSTRAP_RETRY_COOLDOWN
            raise
        _BOOTSTRAP_CACHE[svr] = result
        return result


def _patch_trenv_token(ka) -> None:
    """upstream kis_auth 버그 우회: changeTREnv 가 TRENV.my_token 을 빈 값으로 두는 문제
    (kis_auth.py:179). 캐시에서 실제 토큰을 읽어 namedtuple 교체.

    auth 실패 시 getTREnv() 가 빈 튜플일 수 있다 → getattr 로 안전 접근하고, 토큰을 끝내
    얻지 못하면 정체불명의 AttributeError 대신 명확한 인증 실패 에러를 던진다."""
    env = ka.getTREnv()
    if getattr(env, "my_token", None):
        return
    tok = ka.read_token()
    if not tok:
        raise RuntimeError(
            "KIS 토큰 발급/로드 실패 — 키가 올바른지 확인하세요. 새 기기 최초 실행이면 "
            "토큰 발급 분당 1회 제한(EGW00133)일 수 있어 잠시 후 자동 복구됩니다."
        )
    if hasattr(env, "_replace"):
        ka._TRENV = env._replace(my_token=tok)


def _refresh_token(ka, svr: str) -> None:
    """토큰 재검증 — ka.auth() 가 토큰 캐시 valid-date 를 확인해 유효 시 재사용, 만료 시 재발급."""
    ka.auth(svr=svr, product="01")
    _patch_trenv_token(ka)


def _do_bootstrap(svr: Literal["prod", "vps"] = "prod"):
    """실제 부트스트랩 (캐시 미스 시 1회)."""
    if not KIS_PATH.exists():
        raise RuntimeError(
            f"공식 KIS repo가 없습니다: {KIS_PATH}\n"
            f"  mkdir -p {KIS_PATH.parent}\n"
            f"  git clone https://github.com/koreainvestment/open-trading-api {KIS_PATH}"
        )

    creds = get_credentials()
    cfg = _build_cfg_dict(creds)
    _ensure_kis_config_dir()

    sys.path.insert(0, str(KIS_PATH / "examples_user"))

    with _patched_yaml_load(cfg):
        import kis_auth as ka  # noqa: E402  (monkey patch 후 import 필수)

    ka.auth(svr=svr, product="01")
    ka.auth_ws(svr=svr, product="01")
    _patch_trenv_token(ka)  # upstream changeTREnv 버그 우회 (kis_auth.py:179)

    # 토큰 캐시 파일도 chmod 600
    from datetime import datetime
    cache_file = KIS_CONFIG_DIR / f"KIS{datetime.today().strftime('%Y%m%d')}"
    if cache_file.exists():
        os.chmod(cache_file, 0o600)

    return ka, ka.getTREnv()
