# 개발 비화 — 미니차트가 만든 CPU 100% 무한 재렌더 루프

**날짜**: 2026-05-30
**증상**: 앱의 *모든* 기능에 심한 렉. 토글·정렬·스크롤 전부 버벅임.

## 1. 증상과 첫 측정
"렉이 심하다"는 추상적 보고 → 추측 대신 측정부터.

```
ps aux | grep miniMacaron
→ 앱 프로세스 CPU 99.6%   (백엔드는 5.9%, /indices 응답 3ms)
```

- 백엔드는 멀쩡, **프론트(SwiftUI 앱)가 코어 하나를 100% 점유**.
- 중복 프로세스 없음, :8000 리스너 1개. → 순수 렌더링/메인루프 문제.

## 2. 콜스택 샘플로 범위 좁히기
```
sample <pid> 1
→ Sort by top of stack:
   libswiftObservation.dylib ...
   Hasher._combine / _hash, swift_retain/release
```

메인 스레드가 **SwiftUI Observation 그래프 재평가 + 해싱**에 시간을 쏟고 있었다.
= "이벤트 없이도 뷰가 계속 다시 그려지는" **무한 재렌더 루프**의 전형적 시그니처.
(커서/AppKit 코드가 아니라 SwiftUI diff가 핫 → 입력이 아니라 상태 피드백이 범인)

## 3. 범인: GeometryReader 폭측정 피드백
직전에 추가한 "지수 미니차트 차트 폭 = 텍스트 폭" 기능이 원인이었다.

```swift
// IndexMini (문제 코드)
VStack {
    텍스트블록(이름/등락률/값)
        .background(GeometryReader { g in           // ← 텍스트블록 폭 측정
            Color.clear.preference(key: IndexWidthKey.self, value: g.size.width)
        })
    Sparkline().frame(width: textW, height: 34)     // ← 측정값을 차트 폭에 적용
}
.onPreferenceChange(IndexWidthKey.self) { textW = $0 }  // ← @State 갱신 → 재렌더
```

피드백 고리:
1. 텍스트블록 폭 측정 → `textW` 갱신
2. `textW` 가 옆 Sparkline 폭을 정함
3. 바깥 VStack 폭 = `max(텍스트블록, Sparkline)` → 레이아웃 변화
4. 그 영향으로 텍스트블록 렌더 폭이 **sub-pixel(149.67 ↔ 149.33)로 진동**
5. PreferenceKey 가 매번 "다른" 값으로 인식 → onPreferenceChange 재발화 → 1번으로 복귀

CGFloat 동등 비교가 sub-pixel 차이를 못 잡아 **영원히 수렴하지 않음 → CPU 100%**.
SwiftUI의 고전적 함정: *GeometryReader 가 자기가 측정하는 뷰의 크기에 되먹임*.

## 4. 수정 (한 줄)
측정 대상 텍스트 블록을 **내용 고정 폭**으로 못박아 진동을 차단:

```swift
텍스트블록
    .fixedSize(horizontal: true, vertical: false)   // 폭 = 항상 내용 intrinsic
    .background(GeometryReader { ... })
```

`fixedSize` 로 텍스트블록 폭이 Sparkline/VStack 폭과 무관하게 항상 같은 값이 되어
측정값이 즉시 수렴 → 루프 소멸. **기능(차트 좌우 끝 = 텍스트 끝)은 그대로 유지.**

측정 결과: 앱 CPU **99.6% → 0.0%**.

## 교훈
- "렉" 신고는 추측 금지. `ps`(어느 프로세스) → `sample`(어느 콜스택)로 좁힌다.
- SwiftUI에서 `GeometryReader → PreferenceKey → @State → 같은 서브트리 크기` 고리는
  무한 재렌더의 단골 원인. 측정 대상은 `fixedSize` 등으로 크기를 **되먹임에서 분리**할 것.
- 콜스택에 `libswiftObservation` + `Hasher` 가 핫하면 입력이 아니라 **상태 피드백 루프**를 의심.
