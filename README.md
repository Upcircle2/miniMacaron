# miniMacaron — 한국투자증권 잔고 모니터링 (macOS)

MacaronHTS 서비스 종료(2024-09-30) 이후 macOS에서 한국투자증권 잔고를 확인할 수 있는 비공식 메뉴바 앱.

**Stack**: Python (FastAPI 백엔드, KIS OpenAPI 호출) + Swift / SwiftUI (메뉴바 프론트엔드)
**키 저장**: macOS Keychain (yaml 파일 사용 안 함)

## 기능

- 평가손익 / 평가금액 / 매입금액 / 총자산 / 총예수금 표시
- 보유 종목별 평가손익·수익률·현재가 (WebSocket 실시간 체결가 스트림)
- USD/KRW 환율 + 환손익 분리 표시
- macOS 메뉴바 상주 + 팝오버 형태
- **앱 첫 실행 시 GUI에서 키 입력** → Keychain에 안전 저장

## 사전 요구사항

| 항목 | 버전 |
|---|---|
| macOS | 14 (Sonoma) 이상 |
| Python | 3.11 이상 |
| uv | 최신 |
| Xcode | 15 이상 (Phase 5에서 필요) |
| 한국투자증권 OpenAPI | 실전 + 모의 앱키 발급 필요 |

## 설치

### 1. KIS Developers 앱키 발급

1. [한국투자증권 OpenAPI 포털](https://apiportal.koreainvestment.com/) 가입
2. 마이페이지 → APP Key 발급 (**실전 + 모의 둘 다**)
3. HTS ID 메모

### 2. 공식 open-trading-api 클론 (백엔드 의존)

```bash
mkdir -p ~/repos
git clone https://github.com/koreainvestment/open-trading-api ~/repos/open-trading-api
cd ~/repos/open-trading-api
uv sync
```

다른 위치에 클론하려면:
```bash
export KIS_API_DIR=/path/to/open-trading-api
```

### 3. 본 프로젝트 의존성 설치

```bash
cd ~/miniMacaron
uv sync
```

### 4. 키 등록 (CLI — Swift 앱 출시 전 임시)

```bash
uv run python scripts/setup_keys.py
```

다음 7개 항목을 순서대로 입력:
- 실전 App Key / App Secret
- 모의 App Key / App Secret
- HTS ID
- 실전 계좌번호 (앞 8자리)
- 모의 계좌번호 (앞 8자리)

모두 macOS **Keychain (Service: `com.minimacaron.kis`)** 에 저장. yaml 파일 사용 안 함.

키 변경/삭제:
```bash
uv run python scripts/setup_keys.py --check     # 등록 여부 확인
uv run python scripts/clear_keys.py             # 전체 삭제
```

> **Swift 앱(Phase 5) 출시 후엔 GUI Setup 화면에서 같은 작업 수행.** CLI는 개발/디버깅용으로 남김.

### 5. 인증 동작 확인

```bash
# 모의투자로 먼저 (안전)
uv run python scripts/verify_auth.py --paper

# 실전투자
uv run python scripts/verify_auth.py
```

성공 시:
```
[INFO] 모의투자 (vps) 인증 시도

[OK]   REST OAuth 토큰 발급 성공 (token: eyJ0eXAiOiJKV1QiLCJh...)
[OK]   WebSocket approval_key 발급 성공

[INFO] 계좌번호      : 50123456-01
[INFO] REST URL      : https://openapivts.koreainvestment.com:29443
[INFO] WebSocket URL : ws://ops.koreainvestment.com:31000
[OK]   토큰 캐시 파일: /Users/xxx/KIS/config/KIS20260527 (chmod 600)

✅ 인증 검증 완료 — Step 5(잔고 조회)로 진행 가능.
```

## 보안 모델

| 데이터 | 저장 위치 | 보호 |
|---|---|---|
| App Key / Secret / HTS ID / 계좌번호 | macOS Keychain | OS-level AES 암호화, Touch ID 연동 가능 |
| OAuth 토큰 (1일 캐시) | `~/KIS/config/KIS{YYYYMMDD}` | chmod 600 + 디렉토리 chmod 700 |
| 백엔드 API | `127.0.0.1:8000` (외부 비노출) | 랜덤 토큰 인증 + CORS 없음 |
| `kis_devlp.yaml` | **사용 안 함** (공식 코드 호환용 빈 파일만 존재) | chmod 600 |

보안에 신경 쓴 점:
- **키는 Keychain에만** — 저장소·디스크 평문·API 응답 어디에도 키가 나타나지 않음 (키를 반환하는 엔드포인트 없음)
- **로컬 백엔드 토큰 인증** — `127.0.0.1` 바인딩 + 공유 토큰(chmod 600)으로 다른 로컬 프로세스의 무인증 접근 차단, CORS 없음으로 브라우저 경로도 차단
- **READ-ONLY 전용** — 주문/매매 API 일체 import·호출 안 함. (참고: KIS OpenAPI엔 출금/이체 API 자체가 없어 키 유출 시에도 현금 인출은 불가)
- APP Key/Secret은 **본인 계좌와 1:1 결합** — 절대 타인에게 공유 금지
- 의심스러운 유출 시 즉시 KIS 포털에서 키 재발급 + `scripts/clear_keys.py`로 Keychain 정리

## 프로젝트 구조

```
miniMacaron/
├── README.md
├── .gitignore
├── pyproject.toml              # uv 프로젝트
├── backend/
│   ├── __init__.py
│   └── auth.py                 # Keychain wrapper + 공식 kis_auth 부트스트랩
├── scripts/
│   ├── setup_keys.py           # 키 입력 CLI (Swift Setup UI 백엔드)
│   ├── clear_keys.py           # Keychain 초기화
│   └── verify_auth.py          # 인증 검증 (Step 4)
├── macapp/                     # Swift macOS 메뉴바 앱 (Phase 5)
└── vendor/                     # (gitignored) 공식 repo는 외부에 클론
```

## 작동 원리 — Keychain 부트스트랩

공식 `kis_auth.py`는 import 시점에 `~/KIS/config/kis_devlp.yaml`을 강제 로드합니다.
우리는 다음 방식으로 yaml 의존성을 우회합니다:

1. **빈 yaml 파일만 생성** (`open()` 통과용, chmod 600)
2. **yaml.load monkey-patch**: import 직전 일시적으로 교체, Keychain에서 읽은 dict 반환
3. `import kis_auth` → 공식 코드가 우리 dict를 받음
4. yaml.load 원복 → 다른 호출에 영향 없음

결과: 디스크에 평문 키 **0**, 공식 코드 수정 **0** (포크 없음), 보안 최대.

## 개발 로드맵

- [x] Phase 1: 환경 셋업 + Keychain 인증
- [ ] Phase 2: REST 잔고 조회 (inquire_present_balance)
- [ ] Phase 3: WebSocket 실시간 체결가 (delayed_ccnl)
- [ ] Phase 4: FastAPI 백엔드 (REST + WebSocket relay)
- [ ] Phase 5: SwiftUI macOS 메뉴바 앱 (Setup 화면 포함)
- [ ] Phase 6: 환손익 분해 / 다크모드 / launchd 데몬화 / .dmg 패키징

## 라이선스 / 면책

- 비공식 도구. 한국투자증권과 무관.
- 사용으로 인한 손해에 대해 책임지지 않음.
- MacaronHTS는 한국투자증권의 등록상표였음 — 본 프로젝트명 'miniMacaron'은 단순 오마주.
