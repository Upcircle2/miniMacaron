import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: BalanceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let snap = model.snapshot {
                summaryView(snap.summary, exrt: snap.exrt)
                Divider()
                holdingsList(snap.holdings)
            } else {
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("miniMacaron · 해외").font(.headline)
            Spacer()
            Button {
                Task { await model.fetchOnce() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
    }

    private func summaryView(_ s: Summary, exrt: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("총자산  ₩\(won(s.tot_asset_krw))").font(.title3.bold())
            HStack(spacing: 6) {
                Text("평가손익 ₩\(won(s.eval_pl_krw))")
                Text("(\(pct(s.eval_rate)))")
            }
            .foregroundStyle(s.eval_pl_krw >= 0 ? .green : .red)
            Text("평가 ₩\(won(s.eval_krw)) · 매입 ₩\(won(s.pchs_krw)) · 환율 \(String(format: "%.1f", exrt))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func holdingsList(_ holdings: [Holding]) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(holdings.sorted { $0.eval_usd > $1.eval_usd }) { h in
                    HStack(spacing: 4) {
                        Text(h.symbol).frame(width: 64, alignment: .leading)
                        Spacer()
                        Text(String(format: "$%.2f", h.cur))
                            .frame(width: 90, alignment: .trailing)
                        Text(pct(h.pl_rate))
                            .frame(width: 78, alignment: .trailing)
                            .foregroundStyle(h.pl_usd >= 0 ? .green : .red)
                    }
                    .font(.system(.body, design: .monospaced))
                }
            }
        }
        .frame(height: 340)
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
