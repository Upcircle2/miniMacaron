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

    var body: some View {
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
    }

    // MARK: 상단 토글 / 헤더

    private var header: some View {
        HStack {
            Text("miniMacaron").font(.headline)
            Spacer()
            Button {
                Task { await model.fetchOnce() }
            } label: { Image(systemName: "arrow.clockwise") }
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
            sortPicker
            columnHeader(valueLabel: "평가$")
            grid(sortedOverseas(snap.holdings)) { h in
                rowCells(symbol: h.symbol, cur: String(format: "$%.2f", h.cur),
                         value: "$\(won(h.eval_usd))", rate: h.pl_rate, gain: h.pl_usd >= 0)
            }
        } else {
            placeholder
        }
    }

    private func sortedOverseas(_ h: [Holding]) -> [Holding] {
        switch sortMode {
        case .eval: return h.sorted { $0.eval_usd > $1.eval_usd }
        case .pchs: return h.sorted { $0.pchs_usd > $1.pchs_usd }
        case .rate: return h.sorted { $0.pl_rate > $1.pl_rate }
        }
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
                sortPicker
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
        switch sortMode {
        case .eval: return h.sorted { $0.eval_krw > $1.eval_krw }
        case .pchs: return h.sorted { $0.qty * $0.avg > $1.qty * $1.avg }
        case .rate: return h.sorted { $0.pl_rate > $1.pl_rate }
        }
    }

    // MARK: 공통 컴포넌트

    private var sortPicker: some View {
        Picker("정렬", selection: $sortMode) {
            ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
