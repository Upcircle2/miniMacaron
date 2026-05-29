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
        didSet { Task { await fetchOnce() } }  // 토글 시 즉시 갱신
    }
    @Published var overseas: OverseasSnapshot?
    @Published var domestic: DomesticSnapshot?
    @Published var indices: [IndexQuote] = []   // 나스닥·S&P500 미니 위젯
    @Published var connected = true            // 연속 실패 누적 시에만 false
    @Published var lastUpdate: Date?
    @Published var dataAsOf: Double?           // 서버가 보낸 데이터 생성 epoch (신선도)
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

    /// 토큰 헤더가 붙은 GET 요청 (행 방지용 8초 타임아웃).
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if let t = ipcToken() {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// 데이터가 오래됐는지(서버 as_of 기준 90초 초과). KIS 일시장애로 직전값이 반복될 때 true.
    var isStale: Bool {
        guard let a = dataAsOf else { return false }
        return Date().timeIntervalSince1970 - a > 90
    }

    /// 푸터/플레이스홀더 표시 문구 — 단발성 실패는 숨기고 누적 실패/지연만 노출.
    var statusText: String {
        if !connected { return "백엔드 연결 끊김 — run_api.py 확인" }
        if isStale, let a = dataAsOf {
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
            await pollLoop()
        }
        Task { await indicesLoop() }
    }

    /// 주요 지수(나스닥·S&P500)는 10초 주기로 갱신 (분봉 스파크라인).
    private func indicesLoop() async {
        while !Task.isCancelled {
            await fetchIndices()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func fetchIndices() async {
        guard let url = URL(string: base + "/indices") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            indices = try JSONDecoder().decode([IndexQuote].self, from: data)
        } catch {
            // 실패 시 직전 값 유지
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
        req.timeoutInterval = 8
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
        // 고정 주기 0.5초: "이전 시작 + 0.5초"가 되도록 fetch 소요시간을 차감.
        // (fetch 후 0.5초를 자면 실제 간격 = 지연 + 0.5초 ≈ 1초가 되던 버그 수정)
        let interval = 0.5
        while !Task.isCancelled {
            let start = Date()
            await fetchOnce()
            let remaining = interval - Date().timeIntervalSince(start)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    func fetchOnce() async {
        switch market {
        case .overseas:
            await fetch("/balance/overseas", OverseasSnapshot.self) {
                self.overseas = $0; self.dataAsOf = $0.as_of
            }
        case .domestic:
            await fetch("/balance/domestic", DomesticSnapshot.self) {
                self.domestic = $0; self.dataAsOf = $0.as_of
            }
        }
    }

    private func fetch<T: Decodable>(_ path: String, _ type: T.Type, assign: (T) -> Void) async {
        guard let url = URL(string: base + path) else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: authorizedRequest(url))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                registerFailure(); return
            }
            assign(try JSONDecoder().decode(T.self, from: data))
            failStreak = 0
            connected = true
            lastUpdate = Date()
        } catch {
            registerFailure()
        }
    }

    /// 단발성 실패는 무시하고, 연속 실패(약 2초)가 쌓일 때만 연결 끊김으로 표시.
    private func registerFailure() {
        failStreak += 1
        if failStreak >= 4 { connected = false }
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
        return "₩\(grouped(total))  \(arrow)₩\(grouped(abs(pl))) (\(String(format: "%.2f", abs(rate)))%)"
    }

    private func grouped(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)))
    }
}
