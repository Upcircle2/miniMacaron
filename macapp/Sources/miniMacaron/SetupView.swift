import SwiftUI

struct SetupView: View {
    @EnvironmentObject var model: BalanceModel
    @State private var appKey = ""
    @State private var appSecret = ""
    @State private var htsId = ""
    @State private var accountNo = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("키 설정").font(.headline)
            Text("한국투자증권 OpenAPI 실전 키. 입력값은 로컬 백엔드를 통해 macOS Keychain에 저장됩니다 (디스크 평문 저장 없음).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeled("App Key") { TextField("App Key", text: $appKey).textFieldStyle(.roundedBorder) }
            labeled("App Secret") { SecureField("App Secret", text: $appSecret).textFieldStyle(.roundedBorder) }
            labeled("HTS ID") { TextField("HTS ID", text: $htsId).textFieldStyle(.roundedBorder) }
            labeled("계좌번호 앞 8자리") { TextField("12345678", text: $accountNo).textFieldStyle(.roundedBorder) }

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
        .frame(width: 360)
    }

    private var valid: Bool {
        !appKey.isEmpty && !appSecret.isEmpty && !htsId.isEmpty && accountNo.count >= 8
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

    @ViewBuilder
    private func labeled(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            field()
        }
    }
}
