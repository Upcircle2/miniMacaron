# CLAUDE.md — miniMacaron 프로젝트 컨텍스트

> Claude Code가 이 디렉토리에서 시작 시 자동 로드. 매 세션 이 컨텍스트를 따를 것.
> User-level CLAUDE.md (Karpathy 가이드라인 + 사용자 페르소나)는 이미 로드됨 — 중복 금지, **프로젝트 specific만** 박아둠.

---

## 1. 프로젝트 정체성

**miniMacaron** — macOS에서 한국투자증권 잔고를 모니터링하는 비공식 메뉴바 앱.

**배경**: 한국투자증권 공식 mac HTS인 **MacaronHTS가 2024-09-30 서비스 종료**. 그 이후 mac에서 잔고 확인 방법이 모바일 앱뿐. 이 프로젝트가 그 공백을 메움.

**목적**: 학습 + 이력서용 + 본인 사용. **GitHub 공개 예정** (각자 키 발급 모델).

---

## 2. 핵심 아키텍처 결정 (변경 금지 — 이미 토론 끝)

### Stack: 하이브리드 (Python 백엔드 + Swift 프론트)

- **Backend**: Python 3.11+ / FastAPI(Phase 4부터) / 공식 KIS open-trading-api 활용
- **Frontend**: Swift / SwiftUI / macOS 14+ 메뉴바 (`MenuBarExtra`) 앱
- **IPC**: 두 프로세스는 localhost HTTP/WebSocket으로 통신
- **검토했던 다른 옵션** (이미 기각, 다시 제안 금지):
  - Python 풀스택(rumps): macOS 네이티브 룩 70%
  - Swift 풀포팅: AES/asyncio/OAuth 직접 구현 1500줄+, 완주 가능성 ↓
  - 공식 SDK가 Python 전용이라 Swift 단독 = 공식 코드 활용 불가

### 키 저장: macOS Keychain 일원화 (yaml 파일 사용 금지)

| 항목 | 값 |
|---|---|
| Service | `com.minimacaron.kis` |
| Accounts | `app_key`, `app_secret`, `paper_app_key`, `paper_app_secret`, `hts_id`, `account_no`, `paper_account_no` |
| Python | `keyring` 패키지 |
| Swift | `Security.framework` (같은 항목 공유 가능) |

### 공식 kis_auth.py 통합 방식 (yaml monkey-patch)

공식 코드는 import 시점에 `~/KIS/config/kis_devlp.yaml`을 강제 `yaml.load()`. 우리는:

1. 빈 yaml 파일만 생성 (open() 통과용, chmod 600)
2. `yaml.load`를 임시 monkey-patch → Keychain dict 반환
3. `import kis_auth` → 공식 코드가 우리 dict 받음
4. yaml.load 원상복구 (다른 호출 영향 X)

**결과: 디스크 평문 키 0, 공식 코드 fork 0.** 구현은 `backend/auth.py::bootstrap()`.

### 범위: READ-ONLY (절대 위반 금지)

- 잔고 조회 / 시세 조회만
- 주문 API 절대 import도 하지 마세요: `order`, `daytime_order`, `order_resv`, `order_rvsecncl`, `order_rvsecncl` 등
- 사용자가 fork해서 실수로 매매 안 하도록 README에 명시 + 코드에 import 자체 안 함

---

## 3. 현재 진척 (2026-05-27 기준)

### ✅ Phase 1: 환경 셋업 + Keychain 인증 (완료)

```
backend/__init__.py
backend/auth.py            184줄  Keychain wrapper + yaml monkey-patch + bootstrap()
scripts/setup_keys.py       84줄  7개 키 CLI 입력
scripts/verify_auth.py      70줄  REST OAuth + WS approval_key 검증
scripts/clear_keys.py       25줄  Keychain 초기화
README.md, .gitignore, pyproject.toml
```

의존성: `requests`, `pyyaml`, `websockets`, `pycryptodome`, `pandas`, `keyring`

### 🔄 Phase 2: REST 잔고 조회 (다음 작업)

- 핵심 API: **`inquire_present_balance`** (TR `CTRP6504R`)
- 스크린샷의 모든 필드(평가손익/평가금액/매입금액/총자산/총예수금) 한 번에 반환
- 반환: `(df1, df2, df3)` — df1: 종목별, df2: 외화별, df3: 종합 요약
- 작성 예정: `backend/balance.py`, `scripts/test_balance.py`

### ⬜ Phase 3: WebSocket 실시간 체결가

- 함수: **`delayed_ccnl`** (무료, 15분 지연. 실시간 `HDFSCNT0`는 별도 유료 신청)
- 데이터 키 형식: `D{거래소}{symbol}` (예: `DNASAMD`, `DNYSDELL`)
- 거래소 코드: `NAS`, `NYS`, `AMS`, `HKS`, `TSE`
- 16종목 → 1세션으로 가능 (40 hard limit)

### ⬜ Phase 4~6

- Phase 4: FastAPI 백엔드 (REST + WS relay), localhost:8000
- Phase 5: SwiftUI macOS 메뉴바 앱 (Setup 화면 포함)
- Phase 6: 환손익 분해 / 다크모드 / launchd 데몬화 / `.dmg` 패키징 / `gitleaks` pre-commit

---

## 4. 코드 컨벤션 (프로젝트 specific)

- Python: `from __future__ import annotations`, type hints 필수, `pathlib.Path` 사용 (string path 금지)
- 모든 스크립트는 다음 패턴으로 `backend` import:
  ```python
  import sys
  from pathlib import Path
  sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
  from backend import auth
  ```
- docstring 한국어 OK, 변수·함수명 영어
- 모듈 1개 200줄 넘으면 분리
- 의존성 추가는 `pyproject.toml`에 명시 후 `uv sync` (즉흥 `pip install` 금지)

---

## 5. NEVER 리스트 (보안 — 즉시 차단)

- ❌ `kis_devlp.yaml`에 실제 키 쓰기 → Keychain만
- ❌ 주문/매매 API 호출 (READ-ONLY 위반)
- ❌ 키/토큰 print·log (마스킹 `***xxxx` 필수)
- ❌ 토큰 캐시 파일(`KIS20*`), `.venv/`, `vendor/` 커밋
- ❌ 공식 repo를 vendor/로 git submodule (현재 외부 클론 + `KIS_API_DIR` env var 방식)
- ❌ kis_auth.py 직접 수정·fork (monkey-patch로만 우회)

---

## 6. KIS API 함정 (모르면 즉사)

| 함정 | 내용 |
|---|---|
| Rate limit | 실전 REST 초당 ~20건, 모의 초당 2건. **토큰 발급은 분당 1회** (`EGW00201`) |
| 토큰 캐시 | `~/KIS/config/KIS{YYYYMMDD}` 1일 캐싱. 6시간 내 재발급 = 동일 토큰 |
| TR_ID 변환 | 실전 `T`/`J`/`C` → 모의 `V` 자동 변환 (kis_auth가 처리) |
| WS approval_key | REST 토큰과 별개. `ka.auth_ws()` 별도 호출 필수 |
| WS 구독 한도 | **해외 무료 지연체결가(HDFSCNT0)는 연결당 3종목 하드캡** (2026-05-27 실측, 4번째부터 `MAX SUBSCRIBE OVER` OPSP0008). 국내 실시간 41건과 다름. → 16종목 모니터는 REST 폴링(inquire_present_balance가 전 종목 현재가 반환)으로, WS는 ≤3종목 틱 전용 |
| WS 체결통보 | AES-CBC base64 암호화. `pycryptodome` 필요. 공식 코드가 자동 복호화 |
| PingPong | 서버가 주기적 PING. 60초 무응답 시 끊김. `KISWebSocket` 자동 처리 |
| 해외 실시간 | 미국 기본은 15분 지연(`delayed_ccnl`). 실시간(`HDFSCNT0`)은 별도 유료 |
| 장 마감 | WS가 데이터 안 보냄. 마지막 가격 freeze 처리 필요 |
| 거래소 코드 | NAS/NYS/AMS/HKS/TSE. 잔고 API 파라미터(`NASD` 등)와 다름 — 헷갈리지 말 것 |

---

## 7. 외부 레퍼런스

- 공식 KIS open-trading-api: https://github.com/koreainvestment/open-trading-api
- API 포털: https://apiportal.koreainvestment.com/
- 핵심 파일:
  - `examples_user/kis_auth.py`
  - `examples_user/overseas_stock/overseas_stock_functions.py` (REST)
  - `examples_user/overseas_stock/overseas_stock_functions_ws.py` (WebSocket)
- 환경변수 `KIS_API_DIR`로 공식 repo 위치 지정 (기본 `~/repos/open-trading-api`)

---

## 8. 다음 세션 시작 절차 (필수)

1. 이 `CLAUDE.md` 읽기 (자동)
2. `README.md` 훑기 (사용자 관점 설치/사용법)
3. `backend/auth.py` 읽기 (yaml monkey-patch 메커니즘 이해)
4. 사용자에게 현 상태 확인:
   - "Phase 1 검증(`uv run python scripts/verify_auth.py --paper`) 통과했나요?"
5. 통과 시 → Phase 2 (`backend/balance.py`) 작업 계획 제시 후 승인 받고 시작
6. 미통과 시 → 에러 로그 받아서 디버깅

---

## 9. 핵심 사용자 결정 사항 (요약 — 다시 묻지 마세요)

| 결정 | 값 | 결정 시점 |
|---|---|---|
| 데이터 소스 | 공식 KIS Developers OpenAPI | 초기 |
| 통신 방식 | REST(잔고) + WebSocket(시세) 병행 | 사용자 선택 |
| Stack | 하이브리드(Python 백엔드 + Swift 프론트) | 사용자 선택 |
| UI | 메뉴바 상주(MenuBarExtra) + 팝오버 | 사용자 선택 |
| 추가 기능 | 환율(USD/KRW) + 환손익 분리 표시 | 사용자 선택 |
| 키 저장 | macOS Keychain 일원화, yaml 폐기 | 사용자 선택 |
| 키 입력 UI | Swift 메뉴바 앱 안 Setup 화면 (CLI는 임시) | 사용자 선택 |
| 배포 | GitHub 공개, 각자 키 발급 모델 | 사용자 선택 |

---

## 10. 이전 세션 핸드오프 (Claude Cowork → Code, 2026-05-27)

Cowork에서 Phase 1까지 완료. Code로 이전 이유:
- 셸 직접 사용 (Cowork bash는 샌드박스)
- 반복 디버깅 속도
- Git/Xcode 직접 다루기
- Korean 폴더명/정규화 이슈 회피

Cowork 세션은 더 이상 참조하지 마세요. 이 CLAUDE.md + 코드 자체가 ground truth.
