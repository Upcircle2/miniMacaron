# miniMacaron — 한국투자증권 잔고 모니터링 (macOS)

MacaronHTS 서비스 종료(2024-09-30) 이후 macOS에서 한국투자증권 잔고를 확인할 수 있는 **비공식 메뉴바 앱**.

- **Stack**: Python(FastAPI 백엔드 · 공식 KIS OpenAPI 호출) + Swift/SwiftUI(메뉴바 프론트엔드)
- **구조**: `Swift 메뉴바 앱` ⇄ `localhost:8000 FastAPI` ⇄ `한국투자증권 OpenAPI`
- **키 저장**: macOS Keychain (디스크 평문/yaml 저장 안 함)
- **범위**: **READ-ONLY** — 잔고·시세 조회만, 주문/매매 API 일체 미사용

## 기능

- 메뉴바 라벨에 **총자산 · 평가손익 · 수익률** 한눈에 (정확한 금액)
- 팝오버: 상단 **국내 / 해외 토글**
- 종목 표: **현재가 · 평가금액 · 손익(금액) · 수익률(%) · 오늘 등락률(전일 종가 대비) · 기업명**
- **0.5초 자동 갱신** — 현재가·등락률이 거의 실시간으로 갱신
- **손익 금액 $/₩ 통화 전환** (해외 탭)
- **정렬**: 평가금액 / 매입금액 / 수익률 — 같은 탭 재클릭 시 오름↔내림
- **앱 내 Setup 위저드**: 포털 열기 버튼 + 발급한 키를 클립보드에서 한 번에 붙여넣기 → Keychain 저장

## 사전 요구사항

| 항목 | 버전 |
|---|---|
| macOS | 14 (Sonoma) 이상 |
| Python | 3.11 이상 |
| uv | 최신 |
| Xcode (Swift 6 toolchain) | 메뉴바 앱 빌드용 |
| 한국투자증권 OpenAPI | **실전 App Key/Secret** 발급 필요 |

## 설치 & 실행

### 1. KIS Developers 앱키 발급
1. [한국투자증권 OpenAPI 포털](https://apiportal.koreainvestment.com/) 로그인
2. 마이페이지 → KIS Developers → API 신청 → **실전 App Key / App Secret** 발급
3. **HTS ID**, **실전 계좌번호 앞 8자리** 확인
   > (앱 Setup 화면의 "포털 열기" 버튼이 이 페이지를 바로 열어줌)

### 2. 공식 open-trading-api 클론 (백엔드 의존)
```bash
mkdir -p ~/repos
git clone https://github.com/koreainvestment/open-trading-api ~/repos/open-trading-api
cd ~/repos/open-trading-api && uv sync
```
다른 위치에 두려면 `export KIS_API_DIR=/path/to/open-trading-api`.

### 3. 본 프로젝트 의존성
```bash
cd ~/miniMacaron && uv sync
```

### 4. 백엔드 실행 (localhost:8000)
```bash
uv run python scripts/run_api.py
```

### 5. 메뉴바 앱 빌드 & 실행
```bash
cd macapp && ./build.sh && open build/miniMacaron.app
```
- 첫 실행 시 **Setup 위저드**가 뜸 → "포털 열기"로 키 발급 → App Key / App Secret / HTS ID / 계좌번호 8자리를 **📋 버튼으로 붙여넣고** 저장.
- 저장하면 백엔드가 키를 **macOS Keychain(Service `com.minimacaron.kis`)** 에 보관하고 잔고 화면으로 전환.
- 키 수정은 팝오버의 **⚙ 버튼**.

> 로그인·인증·키 발급 클릭은 **사용자가 직접 브라우저에서** 수행. 앱은 자격증명·세션을 다루지 않음.

### (선택) 개발/디버깅 도구
```bash
uv run python scripts/setup_keys.py          # CLI로 키 입력 (GUI 대신)
uv run python scripts/setup_keys.py --check  # 등록 여부 확인 (값은 마스킹)
uv run python scripts/clear_keys.py          # Keychain 키 전체 삭제
uv run python scripts/verify_auth.py         # 실전 OAuth/WS 인증 검증
uv run python scripts/test_balance.py        # 잔고 조회 테스트
uv run python scripts/dashboard.py           # 터미널 대시보드 (앱 없이 잔고 확인)
```

## 보안 모델

| 데이터 | 저장 위치 | 보호 |
|---|---|---|
| App Key / Secret / HTS ID / 계좌번호 | macOS Keychain | OS-level AES 암호화, Touch ID 연동 가능 |
| OAuth 토큰 (1일 캐시) | `~/KIS/config/KIS{YYYYMMDD}` | chmod 600 + 디렉토리 chmod 700 |
| 백엔드 API | `127.0.0.1:8000` (외부 비노출) | 랜덤 토큰 인증 + CORS 없음 |
| `kis_devlp.yaml` | **사용 안 함** (공식 코드 호환용 빈 파일만) | chmod 600 |

보안에 신경 쓴 점:
- **키는 Keychain에만** — 저장소·디스크 평문·API 응답 어디에도 키가 안 나타남 (키를 반환하는 엔드포인트 없음)
- **로컬 백엔드 토큰 인증** — `127.0.0.1` 바인딩 + 공유 토큰(chmod 600)으로 다른 로컬 프로세스의 무인증 접근 차단, CORS 없음으로 브라우저 경로도 차단
- **READ-ONLY 전용** — 주문/매매 API 일체 import·호출 안 함 (참고: KIS OpenAPI엔 출금/이체 API 자체가 없어 키 유출 시에도 현금 인출은 불가)
- App Key/Secret은 **본인 계좌와 1:1 결합** — 절대 타인에게 공유 금지
- 유출 의심 시 즉시 KIS 포털에서 키 재발급 + `scripts/clear_keys.py`로 Keychain 정리

## 작동 원리 — Keychain 부트스트랩

공식 `kis_auth.py`는 import 시점에 `~/KIS/config/kis_devlp.yaml`을 강제 로드한다. 우리는 yaml 의존성을 다음으로 우회:

1. **빈 yaml 파일만 생성** (`open()` 통과용, chmod 600)
2. **`yaml.load` monkey-patch** — import 직전 일시 교체, Keychain에서 읽은 dict 반환
3. `import kis_auth` → 공식 코드가 우리 dict를 받음
4. yaml.load 원복 (다른 호출 영향 없음)

결과: 디스크 평문 키 **0**, 공식 코드 fork **0**. 구현은 `backend/auth.py::bootstrap()`.

## 프로젝트 구조

```
miniMacaron/
├── backend/
│   ├── auth.py          # Keychain wrapper + 공식 kis_auth 부트스트랩(yaml monkey-patch)
│   ├── balance.py       # 잔고 조회(해외/국내) → UI용 JSON + 오늘 등락률 + KIS 호출 throttle
│   ├── quotes.py        # 전일 종가 캐시(등락률 계산용)
│   ├── stream.py        # WebSocket 지연체결가(delayed_ccnl) 모듈
│   ├── ipc.py           # 백엔드↔앱 공유 토큰
│   └── api.py           # FastAPI (/health, /setup, /balance/*)
├── scripts/
│   ├── run_api.py       # 백엔드 실행 (127.0.0.1:8000)
│   ├── setup_keys.py    # 키 입력 CLI (개발용)
│   ├── clear_keys.py    # Keychain 초기화
│   ├── verify_auth.py   # 인증 검증
│   ├── test_balance.py  # 잔고 조회 테스트
│   └── dashboard.py     # 터미널 대시보드
├── macapp/              # Swift 메뉴바 앱
│   ├── Package.swift · Info.plist · build.sh
│   └── Sources/miniMacaron/
│       ├── miniMacaronApp.swift  # MenuBarExtra 진입점
│       ├── ContentView.swift     # 잔고 표 / 토글 / 정렬 / 등락률
│       ├── BalanceModel.swift    # 0.5초 폴링 + 토큰 인증
│       ├── Models.swift          # API 응답 디코딩
│       └── SetupView.swift       # 키 입력 온보딩 위저드
├── pyproject.toml
└── vendor/              # (gitignored) 공식 repo는 외부에 클론
```

## 개발 로드맵

- [x] Phase 1: 환경 셋업 + Keychain 인증
- [x] Phase 2: REST 잔고 조회 (해외 inquire_present_balance / 국내 inquire_balance)
- [x] Phase 3: WebSocket 지연체결가 모듈 (delayed_ccnl) — 무료 3종목 캡 확인, 앱은 0.5초 REST 폴링 채택
- [x] Phase 4: FastAPI 백엔드 (localhost:8000, 토큰 인증)
- [x] Phase 5: SwiftUI macOS 메뉴바 앱 (Setup 온보딩 위저드 포함)

추가 완료: 국내/해외 토글 · 정렬(오름/내림) · 종목 기업명 · 손익 금액·통화($/₩) 전환 · 오늘 등락률(전일종가 대비, 0.5초) · localhost 토큰 인증 · 커밋 이메일 noreply 정리

## 라이선스 / 면책

- 비공식 도구. 한국투자증권과 무관.
- 사용으로 인한 손해에 대해 책임지지 않음.
- MacaronHTS는 한국투자증권의 등록상표였음 — 본 프로젝트명 'miniMacaron'은 단순 오마주.
