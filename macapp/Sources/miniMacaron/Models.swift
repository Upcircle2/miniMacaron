import Foundation

// MARK: 해외 (/balance/overseas)

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
    let pchs_usd: Double
    let eval_usd: Double
    let pl_usd: Double
    let pl_rate: Double
    let excg: String
    let day_rate: Double?   // 전일 종가 대비 등락률 (null=아직 미수신)
}

// MARK: 국내 (/balance/domestic)

struct DomesticSnapshot: Codable {
    let summary: DomesticSummary
    let holdings: [DomesticHolding]
}

struct DomesticSummary: Codable {
    let tot_eval_krw: Double
    let nass_krw: Double
    let eval_pl_krw: Double
    let pchs_krw: Double
    let dnca_krw: Double
}

struct DomesticHolding: Codable, Identifiable {
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
