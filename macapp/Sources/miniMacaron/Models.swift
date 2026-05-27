import Foundation

/// /balance/overseas 응답과 1:1 매핑 (JSON 키 = 프로퍼티명).
struct OverseasSnapshot: Codable {
    let exrt: Double
    let summary: Summary
    let holdings: [Holding]
}

struct Summary: Codable {
    let tot_asset_krw: Double
    let eval_pl_krw: Double
    let eval_rate: Double
    let eval_krw: Double
    let pchs_krw: Double
}

struct Holding: Codable, Identifiable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let qty: Double
    let avg: Double
    let cur: Double
    let eval_usd: Double
    let pl_usd: Double
    let pl_rate: Double
    let excg: String
}
