import SwiftUI

enum SortMode: String, CaseIterable, Identifiable {
    case eval = "평가금액"
    case pchs = "매입금액"
    case rate = "수익률"
    var id: String { rawValue }
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

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            marketToggle
            if model.market == .overseas {
                overseasSection
            } else {
                domesticSection
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 384)
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
            }
            sortBar
            columnHeader(valueLabel: showKRW ? "평가₩" : "평가$")
            grid(sortedOverseas(snap.holdings)) { h in
                rowCells(
                    symbol: h.symbol,
                    cur: showKRW ? "₩\(won(h.cur * snap.exrt))" : String(format: "$%.2f", h.cur),
                    value: showKRW ? "₩\(won(h.eval_usd * snap.exrt))" : "$\(won(h.eval_usd))",
                    rate: h.pl_rate, gain: h.pl_usd >= 0)
            }
        } else {
            placeholder
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
                Text("총평가  ₩\(won(snap.summary.tot_eval_krw))").font(.title3.bold())
                HStack(spacing: 6) {
                    Text("평가손익 ₩\(won(snap.summary.eval_pl_krw))")
                }
                .foregroundStyle(snap.summary.eval_pl_krw >= 0 ? .green : .red)
                Text("순자산 ₩\(won(snap.summary.nass_krw)) · 예수금 ₩\(won(snap.summary.dnca_krw))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if snap.holdings.isEmpty {
                Text("국내 보유 종목 없음")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                sortBar
                columnHeader(valueLabel: "평가₩")
                grid(sortedDomestic(snap.holdings)) { h in
                    rowCells(symbol: h.symbol, cur: "₩\(won(h.cur))",
                             value: "₩\(won(h.eval_krw))", rate: h.pl_rate, gain: h.pl_krw >= 0)
                }
            }
        } else {
            placeholder
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

    // MARK: 공통 컴포넌트

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

    private func columnHeader(valueLabel: String) -> some View {
        HStack(spacing: 4) {
            Text("종목").frame(width: 60, alignment: .leading)
            Spacer()
            Text("현재").frame(width: 90, alignment: .trailing)
            Text(valueLabel).frame(width: 96, alignment: .trailing)
            Text("손익%").frame(width: 66, alignment: .trailing)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private func grid<Item: Identifiable, RowContent: View>(
        _ items: [Item],
        @ViewBuilder row: @escaping (Item) -> RowContent
    ) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    row(item)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(idx.isMultiple(of: 2) ? Color.clear
                                                          : Color.primary.opacity(0.05))
                    Divider()
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(height: 320)
    }

    private func rowCells(symbol: String, cur: String, value: String,
                          rate: Double, gain: Bool) -> some View {
        HStack(spacing: 4) {
            Text(symbol).frame(width: 60, alignment: .leading)
            Spacer()
            Text(cur).frame(width: 90, alignment: .trailing)
            Text(value).frame(width: 96, alignment: .trailing)
            Text(pct(rate))
                .frame(width: 66, alignment: .trailing)
                .foregroundStyle(gain ? .green : .red)
        }
        .font(.system(.body, design: .monospaced))
    }

    private var placeholder: some View {
        Text(model.status)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var footer: some View {
        HStack {
            Text(model.status).font(.caption).foregroundStyle(.secondary)
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
}

extension View {
    /// 포인터가 손가락 등으로 바뀌지 않고 항상 화살표를 유지하도록 강제.
    func forceArrowCursor() -> some View {
        onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }
}
