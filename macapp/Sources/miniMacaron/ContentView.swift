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

    /// 표 컬럼 고정폭 (모드별). Grid 자동열폭은 매 렌더마다 전 셀을 측정해 0.5초 폴링서
    /// 무거움 → 폭을 박아 측정 비용 제거. ₩(큰 숫자)/$(작은 숫자) 두 세트, popoverWidth 안에 맞춤.
    private struct Cols { let sym, pl, rate, cur, avg, eval, pchs: CGFloat }
    private var cols: Cols {
        (model.market == .domestic || showKRW)
            ? Cols(sym: 128, pl: 92, rate: 60, cur: 84, avg: 84, eval: 94, pchs: 94)
            : Cols(sym: 128, pl: 70, rate: 60, cur: 72, avg: 72, eval: 70, pchs: 70)
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
                // IndicesStore 만 구독하는 서브뷰 — 지수 변동(5초, 선물은 밤에도 움직임)이
                // 팝오버 전체가 아니라 이 스트립만 재렌더.
                IndexStrip(store: model.indicesStore, market: model.market)
            }
            tableArea
            Divider()
            footer
        }
        .padding(12)
        .frame(width: popoverWidth)
        // 세로도 ideal 로 고정 → NSHostingView 가 창 콘텐츠 min/max 크기를 매 패스마다
        // 전체 트리 재탐색(updateWindowContentSizeExtremaIfNecessary)하지 않음.
        // (가로만 고정 시 세로 협상이 maxWidth:.infinity 버튼·minimumScaleFactor 텍스트를
        //  수백 번 재측정해 CPU 100% 무한 레이아웃 루프 유발 — 2026-06-05 sample 로 확인.)
        .fixedSize(horizontal: false, vertical: true)
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
            // LazyVStack: 보이는 행만 렌더. 각 셀 고정폭 → Grid 자동열폭 측정 비용 제거.
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("종목").frame(width: cols.sym, alignment: .leading)
                    Text("손익").frame(width: cols.pl, alignment: .trailing)
                    Text("손익%").frame(width: cols.rate, alignment: .trailing)
                    Text("현재").frame(width: cols.cur, alignment: .trailing)
                    Text("매입단가").frame(width: cols.avg, alignment: .trailing)
                    Text(valueLabel).frame(width: cols.eval, alignment: .trailing)
                    Text(valueLabel.hasPrefix("평가₩") ? "매입₩" : "매입$")
                        .frame(width: cols.pchs, alignment: .trailing)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.vertical, 5)

                Divider()

                ForEach(rows) { r in
                    HStack(spacing: 12) {
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
                        .frame(width: cols.sym, alignment: .leading)
                        Text(r.pl).foregroundStyle(r.gain ? .green : .red).lineLimit(1)
                            .frame(width: cols.pl, alignment: .trailing)
                        Text(pct(r.rate)).foregroundStyle(r.gain ? .green : .red).lineLimit(1)
                            .frame(width: cols.rate, alignment: .trailing)
                        Text(r.cur).lineLimit(1).frame(width: cols.cur, alignment: .trailing)
                        Text(r.avgPrice).lineLimit(1).frame(width: cols.avg, alignment: .trailing)
                        Text(r.value).lineLimit(1).frame(width: cols.eval, alignment: .trailing)
                        Text(r.pchsAmount).lineLimit(1).frame(width: cols.pchs, alignment: .trailing)
                    }
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { openInStocks(r.stocksSymbol) }   // 클릭 → Apple 주식 앱

                    if r.id != rows.last?.id { Divider() }
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

/// 지수 위젯 스트립 — IndicesStore 만 구독. 지수가 변해도 재렌더 범위가 이 뷰로 한정됨.
fileprivate struct IndexStrip: View {
    @ObservedObject var store: IndicesStore
    let market: Market
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(market == .domestic ? store.domestic : store.overseas) { IndexMini(q: $0) }
        }
    }
}

/// 주요 지수 미니 위젯 (이름 · 등락률 · 값 · 스파크라인).
/// 차트 폭은 고정값. (GeometryReader 폭측정은 장중 값 변동 시 sub-pixel 진동→무한 재렌더 루프를
///  유발해 제거함. 미세한 텍스트-차트 폭 불일치보다 성능이 우선.)
fileprivate struct IndexMini: View {
    let q: IndexQuote
    private let chartW: CGFloat = 150
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
                .frame(width: chartW, height: 34)
        }
        .frame(width: chartW, alignment: .leading)
    }
}

/// 장중 시계열 스파크라인 — 보유 데이터를 프레임 가로폭에 균등 분포로 꽉 채움.
/// Canvas 로 그림(GeometryReader 는 greedy 라 창 크기 추정 피드백 루프를 유발해 제거).
fileprivate struct Sparkline: View {
    let points: [[Double]]
    let up: Bool
    var body: some View {
        Canvas { ctx, size in
            let vs = points.compactMap { $0.count > 1 ? $0[1] : nil }
            guard vs.count > 1, let lo = vs.min(), let hi = vs.max(), hi > lo else { return }
            var path = Path()
            let w = size.width, h = size.height
            for (i, v) in vs.enumerated() {
                let x = w * CGFloat(i) / CGFloat(vs.count - 1)
                let y = h * (1 - CGFloat((v - lo) / (hi - lo)))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(up ? .green : .red), lineWidth: 1.3)
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
