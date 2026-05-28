import SwiftUI

struct SetupView: View {
    @EnvironmentObject var model: BalanceModel
    @State private var appKey = ""
    @State private var appSecret = ""
    @State private var htsId = ""
    @State private var accountNo = ""
    @State private var saving = false
    @State private var error: String?

    private let portalURL = URL(string: "https://apiportal.koreainvestment.com/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("키 설정").font(.headline)

            // ① 포털에서 키 발급 (로그인·발급은 사용자가 직접 — 기본 브라우저에서)
            VStack(alignment: .leading, spacing: 6) {
                Text("① 포털에서 키 발급").font(.caption2.bold()).foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(portalURL)
                } label: {
                    Label("한국투자증권 API 포털 열기", systemImage: "safari")
                }
                Text("1. 로그인  →  2. 마이페이지 › KIS Developers › API 신청  →  3. 실전 App Key·Secret 발급  →  4. 값 복사")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // ② 발급받은 키 입력 (각 필드 📋 로 클립보드에서 채우기)
            VStack(alignment: .leading, spacing: 8) {
                Text("② 발급받은 키 입력").font(.caption2.bold()).foregroundStyle(.secondary)
                field("App Key", text: $appKey)
                field("App Secret", text: $appSecret, secure: true)
                field("HTS ID", text: $htsId)
                field("계좌번호 앞 8자리", text: $accountNo, placeholder: "12345678")
            }

            Text("입력값은 로컬 백엔드를 통해 macOS Keychain에 저장됩니다 (디스크 평문 저장 없음).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if model.setupComplete == true {
                    Button("취소") { model.showSetup = false }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button(saving ? "저장 중…" : "저장", action: save)
                    .disabled(saving || !valid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    /// 라벨 + 입력 위젯 + 📋 클립보드 붙여넣기 버튼.
    @ViewBuilder
    private func field(_ label: String, text: Binding<String>,
                       secure: Bool = false, placeholder: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if secure {
                    SecureField(placeholder ?? label, text: text).textFieldStyle(.roundedBorder)
                } else {
                    TextField(placeholder ?? label, text: text).textFieldStyle(.roundedBorder)
                }
                Button {
                    paste(into: text)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("클립보드에서 붙여넣기")
            }
        }
    }

    private var valid: Bool {
        !appKey.isEmpty && !appSecret.isEmpty && !htsId.isEmpty && accountNo.count >= 8
    }

    /// 사용자가 📋 버튼을 누를 때만 클립보드를 1회 읽어 해당 필드에 채움.
    private func paste(into binding: Binding<String>) {
        if let s = NSPasteboard.general.string(forType: .string) {
            binding.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            let ok = await model.submitSetup(appKey: appKey.trimmingCharacters(in: .whitespaces),
                                             appSecret: appSecret.trimmingCharacters(in: .whitespaces),
                                             htsId: htsId.trimmingCharacters(in: .whitespaces),
                                             accountNo: accountNo.trimmingCharacters(in: .whitespaces))
            saving = false
            if ok {
                model.showSetup = false
                await model.fetchOnce()
            } else {
                error = "저장 실패 — 백엔드(run_api.py)가 실행 중인지 확인하세요."
            }
        }
    }
}
