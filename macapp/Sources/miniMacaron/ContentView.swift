import SwiftUI

enum SortMode: String, CaseIterable, Identifiable {
    case eval = "평가금액"
    case pchs = "매입금액"
    case rate = "수익률"
    var id: String { rawValue }
}

/// 표 한 행의 표시용 데이터 (해외/국내 공통).
fileprivate struct RowItem: Identifiable {
    let id: String
    let symbol: String
    let name: String
    let pl: String
    let cur: String
    let avgPrice: String   // 매입단가
    let value: String
    let pchsAmount: String // 매입금액
    let rate: Double
    let gain: Bool
    let dayRate: Double?   // 전일 종가 대비 등락률
    let stocksSymbol: String   // Apple 주식 앱 딥링크용 심볼
}

struct ContentView: View {
    @EnvironmentObject var model: BalanceModel
    @State private var sortMode: SortMode = .eval
    @State private var sortDesc = true  // 내림차순 기본
    @State private var showKRW = false  // 해외 종목 값 표시 통화 (false=$, true=₩)

    var body: some View {
        if model.setupComplete == false || model.showSetup {
            SetupView()
        } else {
            mainView
        }
    }

    /// 팝오버 가로폭 (₩ 큰 숫자 = 더 넓게). 매입단가·매입금액 2열 추가로 확대.
    private var popoverWidth: CGFloat {
        (model.market == .domestic || showKRW) ? 760 : 680
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // 토글+요약은 정상 흐름, 지수 위젯은 우측 상단에 overlay(겹침) → 레이아웃 안 밀림.
            VStack(alignment: .leading, spacing: 8) {
                HStack { marketToggle.frame(width: 116); Spacer() }
                summaryArea
            }
            .overlay(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(model.indices) { IndexMini(q: $0) }
                }
            }
            tableArea
            Divider()
            footer
        }
        .padding(12)
        .frame(width: popoverWidth)
        .forceArrowCursor()
    }

    // 좌측 요약 (시장별)
    @ViewBuilder private var summaryArea: some View {
        if model.market == .overseas { overseasSummary } else { domesticSummary }
    }

    // 종목 표 (시장별)
    @ViewBuilder private var tableArea: some View {
        if model.market == .overseas { overseasTable } else { domesticTable }
    }

    // MARK: 상단 토글 / 헤더

    private var header: some View {
        HStack(spacing: 10) {
            Text("miniMacaron").font(.headline)
            Spacer()
            if model.market == .overseas {
                Button { showKRW.toggle() } label: {
                    Text(showKRW ? "₩" : "$").frame(width: 14)
                }
                .buttonStyle(.borderless)
                .help("종목 값 통화 전환 (₩/$)")
            }
            Button {
                Task { await model.fetchOnce() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
            Button {
                model.showSetup = true
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
        }
    }

    private var marketToggle: some View {
        Picker("시장", selection: $model.market) {
            ForEach(Market.allCases) { m in Text(m.rawValue).tag(m) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: 해외

    @ViewBuilder private var overseasSummary: some View {
        if let snap = model.overseas {
            VStack(alignment: .leading, spacing: 2) {
                Text("총자산  ₩\(won(snap.summary.tot_asset_krw))").font(.title3.bold())
                    .lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    Text("평가손익 ₩\(won(snap.summary.eval_pl_krw))")
                    Text("(\(pct(snap.summary.eval_rate)))")
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(snap.summary.eval_pl_krw >= 0 ? .green : .red)
                Text("평가 ₩\(won(snap.summary.eval_krw)) · 매입 ₩\(won(snap.summary.pchs_krw)) · 환율 \(String(format: "%.1f", snap.exrt))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }

    @ViewBuilder private var overseasTable: some View {
        if let snap = model.overseas {
            sortBar
            tableView(valueLabel: showKRW ? "평가₩" : "평가$", rows: overseasRows(snap))
        } else {
            placeholder
        }
    }

    private func overseasRows(_ snap: OverseasSnapshot) -> [RowItem] {
        sortedOverseas(snap.holdings).map { h in
            RowItem(
                id: h.symbol,
                symbol: h.symbol,
                name: h.name,
                pl: showKRW ? signedKRW(h.pl_usd * snap.exrt) : signedUSD(h.pl_usd),
                cur: showKRW ? "₩\(won(h.cur * snap.exrt))" : String(format: "$%.2f", h.cur),
                avgPrice: showKRW ? "₩\(won(h.avg * snap.exrt))" : String(format: "$%.2f", h.avg),
                value: showKRW ? "₩\(won(h.eval_usd * snap.exrt))" : "$\(won(h.eval_usd))",
                pchsAmount: showKRW ? "₩\(won(h.pchs_usd * snap.exrt))" : "$\(won(h.pchs_usd))",
                rate: h.pl_rate,
                gain: h.pl_usd >= 0,
                dayRate: h.day_rate,
                stocksSymbol: h.symbol   // 미국 티커 그대로 (예: AMD)
            )
        }
    }

    private func sortedOverseas(_ h: [Holding]) -> [Holding] {
        let key: (Holding) -> Double
        switch sortMode {
        case .eval: key = { $0.eval_usd }
        case .pchs: key = { $0.pchs_usd }
        case .rate: key = { $0.pl_rate }
        }
        return h.sorted { sortDesc ? key($0) > key($1) : key($0) < key($1) }
    }

    // MARK: 국내

    @ViewBuilder private var domesticSummary: some View {
        if let snap = model.domestic {
            VStack(alignment: .leading, spacing: 2) {
                Text("총 자산  ₩\(won(snap.summary.tot_eval_krw))").font(.title3.bold())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("평가손익 ₩\(won(snap.summary.eval_pl_krw))")
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(snap.summary.eval_pl_krw >= 0 ? .green : .red)
                Text("순자산 ₩\(won(snap.summary.nass_krw)) · 예수금 ₩\(won(snap.summary.dnca_krw))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }

    @ViewBuilder private var domesticTable: some View {
        if let snap = model.domestic {
            if snap.holdings.isEmpty {
                Text("국내 보유 종목 없음")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 480)
            } else {
                sortBar
                tableView(valueLabel: "평가₩", rows: domesticRows(snap))
            }
        } else {
            placeholder
        }
    }

    private func domesticRows(_ snap: DomesticSnapshot) -> [RowItem] {
        sortedDomestic(snap.holdings).map { h in
            RowItem(
                id: h.symbol,
                symbol: h.symbol,
                name: h.name,
                pl: signedKRW(h.pl_krw),
                cur: "₩\(won(h.cur))",
                avgPrice: "₩\(won(h.avg))",
                value: "₩\(won(h.eval_krw))",
                pchsAmount: "₩\(won(h.eval_krw - h.pl_krw))",
                rate: h.pl_rate,
                gain: h.pl_krw >= 0,
                dayRate: h.day_rate,
                stocksSymbol: "\(h.symbol).KS"   // 국내: 6자리코드 + .KS (Apple 주식 한국 표기, best-effort)
            )
        }
    }

    private func sortedDomestic(_ h: [DomesticHolding]) -> [DomesticHolding] {
        let key: (DomesticHolding) -> Double
        switch sortMode {
        case .eval: key = { $0.eval_krw }
        case .pchs: key = { $0.qty * $0.avg }
        case .rate: key = { $0.pl_rate }
        }
        return h.sorted { sortDesc ? key($0) > key($1) : key($0) < key($1) }
    }

    // MARK: 정렬 바

    private var sortBar: some View {
        HStack(spacing: 6) {
            ForEach(SortMode.allCases) { mode in
                Button {
                    if sortMode == mode {
                        sortDesc.toggle()          // 같은 탭 재클릭 → 방향 전환
                    } else {
                        sortMode = mode            // 다른 탭 → 전환(내림차순부터)
                        sortDesc = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(mode.rawValue)
                        if sortMode == mode {
                            Image(systemName: sortDesc ? "arrow.down" : "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(sortMode == mode ? Color.accentColor.opacity(0.25)
                                                 : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
    }

    // MARK: 표 (Grid — 컬럼이 내용 폭에 맞춰 정렬, 줄바꿈 없음)

    private func tableView(valueLabel: String, rows: [RowItem]) -> some View {
        ScrollView {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text("종목").gridColumnAlignment(.leading)
                    Text("손익")
                    Text("손익%")
                    Text("현재")
                    Text("매입단가")
                    Text(valueLabel)
                    Text(valueLabel.hasPrefix("평가₩") ? "매입₩" : "매입$")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.vertical, 5)

                Divider().gridCellColumns(7)

                ForEach(rows) { r in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(r.symbol)
                                if let d = r.dayRate {
                                    Text(String(format: "%+.2f%%", d))
                                        .font(.caption2)
                                        .foregroundStyle(d >= 0 ? .green : .red)
                                }
                            }
                            Text(r.name)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 140, alignment: .leading)
                        Text(r.pl).foregroundStyle(r.gain ? .green : .red).lineLimit(1)
                        Text(pct(r.rate)).foregroundStyle(r.gain ? .green : .red).lineLimit(1)
                        Text(r.cur).lineLimit(1)
                        Text(r.avgPrice).lineLimit(1)
                        Text(r.value).lineLimit(1)
                        Text(r.pchsAmount).lineLimit(1)
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { openInStocks(r.stocksSymbol) }   // 클릭 → Apple 주식 앱

                    if r.id != rows.last?.id {
                        Divider().gridCellColumns(7)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 480)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: 기타

    private var placeholder: some View {
        VStack(spacing: 8) {
            if model.connected {
                ProgressView().controlSize(.small)
                Text("불러오는 중…")
            } else {
                Image(systemName: "wifi.exclamationmark").font(.title2)
                Text("백엔드에 연결할 수 없습니다\nrun_api.py 실행 중인지 확인")
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 480)
    }

    private var footer: some View {
        HStack {
            Text(model.statusText).font(.caption)
                .foregroundStyle((!model.connected || model.isStale) ? Color.red : Color.secondary)
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
    }

    /// 종목 클릭 → Apple 주식 앱의 해당 종목 상세로 이동.
    private func openInStocks(_ symbol: String) {
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty,
              let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "stocks://?symbol=\(enc)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func won(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)))
    }
    private func pct(_ v: Double) -> String {
        String(format: "%+.2f%%", v)
    }
    private func signedUSD(_ v: Double) -> String {
        (v < 0 ? "-$" : "+$") + won(abs(v))
    }
    private func signedKRW(_ v: Double) -> String {
        (v < 0 ? "-₩" : "+₩") + won(abs(v))
    }
}

/// 주요 지수 미니 위젯 (이름 · 등락률 · 값 · 스파크라인).
private struct IndexWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

fileprivate struct IndexMini: View {
    let q: IndexQuote
    @State private var textW: CGFloat = 120   // 텍스트 블록 폭 → 차트 폭에 적용
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(q.name).font(.system(size: 15, weight: .bold))
                    Text(String(format: "%+.2f%%", q.rate))
                        .font(.system(size: 13))
                        .foregroundStyle(q.up ? .green : .red)
                }
                Text(q.value.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)   // 폭 고정 → GeometryReader 진동(무한 재렌더) 차단
            .background(GeometryReader { g in
                Color.clear.preference(key: IndexWidthKey.self, value: g.size.width)
            })
            Sparkline(points: q.spark, up: q.up)
                .frame(width: textW, height: 34)   // 차트 좌우 끝 = 텍스트 블록 좌우 끝
        }
        .onPreferenceChange(IndexWidthKey.self) { if $0 > 0 { textW = $0 } }
    }
}

/// 장중 시계열 스파크라인 — 보유 데이터를 프레임 가로폭에 균등 분포로 꽉 채움.
fileprivate struct Sparkline: View {
    let points: [[Double]]
    let up: Bool
    var body: some View {
        GeometryReader { geo in
            let vs = points.compactMap { $0.count > 1 ? $0[1] : nil }
            if vs.count > 1, let lo = vs.min(), let hi = vs.max(), hi > lo {
                Path { p in
                    let w = geo.size.width, h = geo.size.height
                    for (i, v) in vs.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(vs.count - 1)  // 균등 분포(좌→우 꽉)
                        let y = h * (1 - CGFloat((v - lo) / (hi - lo)))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(up ? Color.green : Color.red, lineWidth: 1.3)
            }
        }
    }
}

extension View {
    /// 포인터가 손가락 등으로 바뀌지 않고 항상 화살표를 유지하도록 강제.
    func forceArrowCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}
