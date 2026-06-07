import SwiftUI

enum Market: String, CaseIterable, Identifiable {
    case domestic = "국내"
    case overseas = "해외"
    var id: String { rawValue }
}

/// 백엔드(127.0.0.1:8000)를 폴링해 선택된 시장의 잔고를 보관.
@MainActor
final class BalanceModel: ObservableObject {
    @Published var market: Market = .overseas {
        // 시장별 지수를 따로 캐시 → 토글 시 캐시된 값 즉시 표시(깜빡임 없음) + 백그라운드 갱신.
        didSet { Task { await fetchOnce(); await fetchIndices() } }
    }
    @Published var overseas: OverseasSnapshot?
    @Published var domestic: DomesticSnapshot?
    @Published private var overseasIdx: [IndexQuote] = []   // 해외 지수 캐시
    @Published private var domesticIdx: [IndexQuote] = []   // 국내 지수 캐시
    /// 현재 시장의 지수 위젯 (캐시 반환 — 전환 시 즉시 표시).
    var indices: [IndexQuote] { market == .domestic ? domesticIdx : overseasIdx }
    @Published var connected = true            // 연속 실패 누적 시에만 false
    @Published var lastUpdate: Date?           // 잔고가 '실제로 바뀐' 마지막 시각
    @Published private(set) var stale = false  // 신선도 경고(>90s) — 상태 변할 때만 갱신(재렌더 최소화)
    private var dataAsOfRaw: Double?           // 서버 as_of: 매 폴링 갱신하되 @Published 아님(헛재렌더 방지)
    @Published var setupComplete: Bool? = nil  // nil = 확인 중/백엔드 다운
    @Published var showSetup = false            // 사용자가 직접 연 경우

    private let base = "http://127.0.0.1:8000"
    private var started = false
    private var failStreak = 0

    /// 백엔드와 공유하는 IPC 토큰 (앱 지원 폴더의 파일에서 읽음).
    private func ipcToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/miniMacaron/ipc.token")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 토큰 헤더가 붙은 GET 요청 (행/멈춤 방지용 4초 타임아웃).
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        if let t = ipcToken() {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// 데이터가 오래됐는지 — 폴링 루프가 상태 변할 때만 갱신하는 stale 플래그.
    var isStale: Bool { stale }

    /// 푸터/플레이스홀더 표시 문구 — 단발성 실패는 숨기고 누적 실패/지연만 노출.
    var statusText: String {
        if !connected { return "백엔드 연결 끊김 — run_api.py 확인" }
        if stale, let a = dataAsOfRaw {
            let age = Int(Date().timeIntervalSince1970 - a)
            let mins = age / 60
            let ago = mins > 0 ? "\(mins)분 전" : "\(age)초 전"
            return "⚠︎ 데이터 지연 — 마지막 \(ago) (KIS 응답 지연)"
        }
        if let t = lastUpdate { return "갱신 " + t.formatted(date: .omitted, time: .standard) }
        return "불러오는 중…"
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            await checkHealth()
            await preloadBothMarkets()   // 양 시장 미리 로딩 → 토글 시 즉시 표시(로딩 갭 제거)
            await pollLoop()
        }
        Task { await indicesLoop() }
    }

    /// 국내·해외 잔고/지수를 1회씩 미리 받아 캐시 → 탭 전환 시 네트워크 대기 없이 즉시 표시.
    private func preloadBothMarkets() async {
        if let o: OverseasSnapshot = await fetchValue("/balance/overseas") {
            overseas = o; updateFreshness(o.as_of); lastUpdate = Date()
        }
        if let d: DomesticSnapshot = await fetchValue("/balance/domestic") { domestic = d }
        await fetchIndicesFor(.overseas)
        await fetchIndicesFor(.domestic)
    }

    /// 주요 지수(나스닥·S&P500/선물) 5초 주기 갱신 (값은 5초, 차트는 백엔드 60초 캐시).
    private func indicesLoop() async {
        while !Task.isCancelled {
            await fetchIndices()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func fetchIndices() async { await fetchIndicesFor(market) }

    private func fetchIndicesFor(_ cur: Market) async {
        let mkt = cur == .domestic ? "domestic" : "overseas"
        guard let url = URL(string: base + "/indices?market=\(mkt)") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode([IndexQuote].self, from: data)
            // 값/스파크 동일하면 대입 안 함 → 지수 안 바뀐 5초 주기엔 재렌더 skip(밤새 누적 방지).
            if cur == .domestic {
                if domesticIdx != decoded { domesticIdx = decoded }
            } else {
                if overseasIdx != decoded { overseasIdx = decoded }
            }
        } catch {
            // 실패 시 직전 값 유지(캐시 보존)
        }
    }

    func checkHealth() async {
        guard let url = URL(string: base + "/health") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url))
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let complete = obj["setup_complete"] as? Bool else { return }
            setupComplete = complete
        } catch {
            setupComplete = nil  // 백엔드 미기동
        }
    }

    /// Setup 화면에서 입력한 실전 키 4종을 백엔드로 전송 → keyring 저장.
    func submitSetup(appKey: String, appSecret: String, htsId: String, accountNo: String) async -> Bool {
        guard let url = URL(string: base + "/setup") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = ipcToken() {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let body = ["app_key": appKey, "app_secret": appSecret,
                    "hts_id": htsId, "account_no": accountNo]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = obj["setup_complete"] as? Bool else { return false }
            setupComplete = ok
            return ok
        } catch {
            return false
        }
    }

    private func pollLoop() async {
        // 고정 주기 0.5초(빠를 땐 "이전 시작+0.5초"). 응답이 느려도 최소 0.2초는 쉬어
        // back-to-back 폭주(KIS 부하·재렌더 폭주로 멈춤 악화)를 방지.
        let interval = 0.5
        while !Task.isCancelled {
            let start = Date()
            await fetchOnce()
            let remaining = interval - Date().timeIntervalSince(start)
            try? await Task.sleep(for: .seconds(max(0.2, remaining)))
        }
    }

    func fetchOnce() async {
        switch market {
        case .overseas:
            if let v: OverseasSnapshot = await fetchValue("/balance/overseas") {
                updateFreshness(v.as_of)
                if overseas != v { overseas = v; lastUpdate = Date() }  // 내용 바뀔 때만 재렌더
            }
        case .domestic:
            if let v: DomesticSnapshot = await fetchValue("/balance/domestic") {
                updateFreshness(v.as_of)
                if domestic != v { domestic = v; lastUpdate = Date() }
            }
        }
    }

    /// GET → 디코드. 성공 시 연결상태만 (전이 시) 갱신하고 값 반환. 실패 시 nil.
    /// 값 대입/재렌더 여부는 호출측이 '내용 변경'을 보고 결정(헛재렌더 방지).
    private func fetchValue<T: Decodable>(_ path: String) async -> T? {
        guard let url = URL(string: base + path) else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                registerFailure(); return nil
            }
            let value = try JSONDecoder().decode(T.self, from: data)
            failStreak = 0
            if !connected { connected = true }   // 같은 값 재대입 금지 → 전이 시에만 발화
            return value
        } catch {
            registerFailure(); return nil
        }
    }

    /// 서버 as_of 로 신선도 갱신. dataAsOfRaw 는 매 폴링 갱신하되 @Published 가 아니라 재렌더 안 함.
    /// stale 은 상태가 바뀔 때만 대입 → 닫힌 장(정상 응답)엔 false 유지, 백엔드 장애 시에만 1회 재렌더.
    private func updateFreshness(_ asOf: Double?) {
        dataAsOfRaw = asOf
        let nowStale = asOf.map { Date().timeIntervalSince1970 - $0 > 90 } ?? false
        if nowStale != stale { stale = nowStale }
    }

    /// 단발성 실패는 무시하고, 연속 실패(약 2초)가 쌓일 때만 연결 끊김으로 표시.
    private func registerFailure() {
        failStreak += 1
        if failStreak >= 4 && connected { connected = false }  // 전이 시에만 발화
    }

    /// 메뉴바 라벨 (선택된 시장 기준) — 정확한 총액 + 평가손익 + 수익률.
    var menuTitle: String {
        switch market {
        case .overseas:
            guard let s = overseas?.summary else { return "miniMacaron" }
            return label(total: s.tot_asset_krw, pl: s.eval_pl_krw, rate: s.eval_rate)
        case .domestic:
            guard let s = domestic?.summary else { return "miniMacaron" }
            let rate = s.pchs_krw > 0 ? s.eval_pl_krw / s.pchs_krw * 100 : 0
            return label(total: s.tot_eval_krw, pl: s.eval_pl_krw, rate: rate)
        }
    }

    private func label(total: Double, pl: Double, rate: Double) -> String {
        let arrow = pl >= 0 ? "▲" : "▼"
        let plStr = pl < 0 ? "-₩\(grouped(abs(pl)))" : "₩\(grouped(pl))"
        return "₩\(grouped(total))  \(arrow)\(plStr) (\(String(format: "%.2f", abs(rate)))%)"
    }

    private func grouped(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)))
    }
}
