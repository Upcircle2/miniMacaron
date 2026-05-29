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
    let value: String
    let rate: Double
    let gain: Bool
    let dayRate: Double?   // 전일 종가 대비 등락률
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

    /// 표시 통화에 따라 팝오버 가로폭 가변 (₩ 큰 숫자 = 더 넓게).
    private var popoverWidth: CGFloat {
        // 종목 셀에 기업명(최대 120pt)이 추가돼 폭을 더 확보.
        (model.market == .domestic || showKRW) ? 620 : 540
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .center, spacing: 10) {
                marketToggle.frame(width: 116)
                Spacer(minLength: 6)
                ForEach(model.indices) { IndexMini(q: $0) }
            }
            if model.market == .overseas {
                overseasSection
            } else {
                domesticSection
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: popoverWidth)
        .forceArrowCursor()
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

    @ViewBuilder private var overseasSection: some View {
        if let snap = model.overseas {
            VStack(alignment: .leading, spacing: 2) {
                Text("총자산  ₩\(won(snap.summary.tot_asset_krw))").font(.title3.bold())
                HStack(spacing: 6) {
                    Text("평가손익 ₩\(won(snap.summary.eval_pl_krw))")
                    Text("(\(pct(snap.summary.eval_rate)))")
                }
                .foregroundStyle(snap.summary.eval_pl_krw >= 0 ? .green : .red)
                Text("평가 ₩\(won(snap.summary.eval_krw)) · 매입 ₩\(won(snap.summary.pchs_krw)) · 환율 \(String(format: "%.1f", snap.exrt))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
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
                value: showKRW ? "₩\(won(h.eval_usd * snap.exrt))" : "$\(won(h.eval_usd))",
                rate: h.pl_rate,
                gain: h.pl_usd >= 0,
                dayRate: h.day_rate
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

    @ViewBuilder private var domesticSection: some View {
        if let snap = model.domestic {
            VStack(alignment: .leading, spacing: 2) {
                Text("총 자산  ₩\(won(snap.summary.tot_eval_krw))").font(.title3.bold())
                Text("평가손익 ₩\(won(snap.summary.eval_pl_krw))")
                    .foregroundStyle(snap.summary.eval_pl_krw >= 0 ? .green : .red)
                Text("순자산 ₩\(won(snap.summary.nass_krw)) · 예수금 ₩\(won(snap.summary.dnca_krw))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
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
                value: "₩\(won(h.eval_krw))",
                rate: h.pl_rate,
                gain: h.pl_krw >= 0,
                dayRate: h.day_rate
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
                    Text(valueLabel)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.vertical, 5)

                Divider().gridCellColumns(5)

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
                        Text(r.value).lineLimit(1)
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.vertical, 4)

                    if r.id != rows.last?.id {
                        Divider().gridCellColumns(5)
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
                .foregroundStyle(model.connected ? Color.secondary : Color.red)
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
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
fileprivate struct IndexMini: View {
    let q: IndexQuote
    var body: some View {
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
            Sparkline(points: q.spark, up: q.up)
                .frame(width: 120, height: 30)
        }
    }
}

/// 장중 시계열 스파크라인 — x축 = ET 정규장 09:30~16:00 (points[i] = [x(0~1), value]).
fileprivate struct Sparkline: View {
    let points: [[Double]]
    let up: Bool
    var body: some View {
        GeometryReader { geo in
            let vs = points.compactMap { $0.count > 1 ? $0[1] : nil }
            if points.count > 1, let lo = vs.min(), let hi = vs.max(), hi > lo {
                Path { p in
                    let w = geo.size.width, h = geo.size.height
                    for (i, pt) in points.enumerated() where pt.count > 1 {
                        let x = w * CGFloat(pt[0])
                        let y = h * (1 - CGFloat((pt[1] - lo) / (hi - lo)))
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
