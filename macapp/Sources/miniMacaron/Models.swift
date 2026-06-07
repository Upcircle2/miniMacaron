import Foundation

// MARK: 해외 (/balance/overseas)

struct OverseasSnapshot: Codable, Equatable {
    let exrt: Double
    let summary: Summary
    let holdings: [Holding]
    let as_of: Double?   // 데이터 생성 epoch (신선도 판정용)

    // as_of(서버시각)는 매 폴링 변하므로 '내용 동일' 판정에서 제외 → 잔고 불변 시 재렌더 skip.
    static func == (l: OverseasSnapshot, r: OverseasSnapshot) -> Bool {
        l.exrt == r.exrt && l.summary == r.summary && l.holdings == r.holdings
    }
}

struct Summary: Codable, Equatable {
    let tot_asset_krw: Double
    let eval_pl_krw: Double
    let eval_rate: Double
    let eval_krw: Double
    let pchs_krw: Double
}

struct Holding: Codable, Identifiable, Equatable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let qty: Double
    let avg: Double
    let cur: Double
    let pchs_usd: Double
    let eval_usd: Double
    let pl_usd: Double
    let pl_rate: Double
    let excg: String
    let day_rate: Double?   // 전일 종가 대비 등락률 (null=아직 미수신)
}

// MARK: 국내 (/balance/domestic)

struct DomesticSnapshot: Codable, Equatable {
    let summary: DomesticSummary
    let holdings: [DomesticHolding]
    let as_of: Double?

    static func == (l: DomesticSnapshot, r: DomesticSnapshot) -> Bool {
        l.summary == r.summary && l.holdings == r.holdings
    }
}

struct DomesticSummary: Codable, Equatable {
    let tot_eval_krw: Double
    let nass_krw: Double
    let eval_pl_krw: Double
    let pchs_krw: Double
    let dnca_krw: Double
}

/// /indices 응답 — 주요 지수(나스닥·S&P500) 미니 위젯용.
struct IndexQuote: Codable, Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let value: Double
    let change: Double
    let rate: Double
    let up: Bool
    let spark: [[Double]]   // [[x(0~1, 세션 시각), value], ...]
}

struct DomesticHolding: Codable, Identifiable, Equatable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let qty: Double
    let avg: Double
    let cur: Double
    let eval_krw: Double
    let pl_krw: Double
    let pl_rate: Double
    let day_rate: Double?   // 전일 종가 대비 등락률 (null=아직 미수신)
}
