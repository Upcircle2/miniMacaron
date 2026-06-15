import SwiftUI

@main
struct MiniMacaronApp: App {
    // @State(=비구독)로 소유만 → 모델의 0.5초 objectWillChange 가 App body 를 재평가하지 않음.
    // 메뉴바 라벨은 MenuBarStore, 팝오버는 ContentView 가 각자 필요한 것만 구독.
    @State private var model = BalanceModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
                .task { model.start() }
        } label: {
            // 별도 스토어만 구독 → 라벨이 ~1.5초(throttle)에만 재렌더 (24/7 누적 완화).
            MenuBarLabel(store: model.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 메뉴바 라벨 — MenuBarStore 만 구독해 title 변경 시에만 재렌더.
struct MenuBarLabel: View {
    @ObservedObject var store: MenuBarStore
    var body: some View { Text(store.title) }
}
