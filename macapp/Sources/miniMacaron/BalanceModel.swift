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
    @Published var status: String = "연결 중…"

    private let base = "http://127.0.0.1:8000"
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { await pollLoop() }
    }

    private func pollLoop() async {
        // 실전 REST 한도 ~20건/초. 0.5초 폴링 = 2건/초로 한도 대비 충분한 여유.
        while !Task.isCancelled {
            await fetchOnce()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func fetchOnce() async {
        switch market {
        case .overseas: await fetch("/balance/overseas", OverseasSnapshot.self) { self.overseas = $0 }
        case .domestic: await fetch("/balance/domestic", DomesticSnapshot.self) { self.domestic = $0 }
        }
    }

    private func fetch<T: Decodable>(_ path: String, _ type: T.Type, assign: (T) -> Void) async {
        guard let url = URL(string: base + path) else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                status = "백엔드 오류 (서버 응답 비정상)"
                return
            }
            assign(try JSONDecoder().decode(T.self, from: data))
            status = "갱신: " + Date().formatted(date: .omitted, time: .standard)
        } catch {
            status = "백엔드 연결 실패 — run_api.py 실행 중인가요?"
        }
    }

    /// 메뉴바 라벨 (선택된 시장 기준).
    var menuTitle: String {
        switch market {
        case .overseas:
            guard let s = overseas?.summary else { return "miniMacaron" }
            return label(totalKRW: s.tot_asset_krw, rate: s.eval_rate)
        case .domestic:
            guard let s = domestic?.summary else { return "miniMacaron" }
            let rate = s.pchs_krw > 0 ? s.eval_pl_krw / s.pchs_krw * 100 : 0
            return label(totalKRW: s.tot_eval_krw, rate: rate)
        }
    }

    private func label(totalKRW: Double, rate: Double) -> String {
        let m = totalKRW / 1_000_000
        let arrow = rate >= 0 ? "▲" : "▼"
        return String(format: "₩%.1fM %@%.2f%%", m, arrow, abs(rate))
    }
}
