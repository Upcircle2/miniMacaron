import SwiftUI

/// 백엔드(127.0.0.1:8000)를 폴링해 해외 잔고를 보관하는 뷰 모델.
@MainActor
final class BalanceModel: ObservableObject {
    @Published var snapshot: OverseasSnapshot?
    @Published var status: String = "연결 중…"
    @Published var lastUpdate: Date?

    private let url = URL(string: "http://127.0.0.1:8000/balance/overseas")!
    private var started = false

    /// 폴링 루프 시작 (중복 호출 방지).
    func start() {
        guard !started else { return }
        started = true
        Task { await pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await fetchOnce()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func fetchOnce() async {
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                status = "백엔드 오류 (서버 응답 비정상)"
                return
            }
            snapshot = try JSONDecoder().decode(OverseasSnapshot.self, from: data)
            lastUpdate = Date()
            status = "갱신: " + Date().formatted(date: .omitted, time: .standard)
        } catch {
            status = "백엔드 연결 실패 — run_api.py 실행 중인가요?"
        }
    }

    /// 메뉴바 라벨 텍스트.
    var menuTitle: String {
        guard let s = snapshot?.summary else { return "miniMacaron" }
        let won = s.tot_asset_krw / 1_000_000
        let arrow = s.eval_rate >= 0 ? "▲" : "▼"
        return String(format: "₩%.1fM %@%.2f%%", won, arrow, abs(s.eval_rate))
    }
}
