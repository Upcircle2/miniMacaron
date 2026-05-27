import SwiftUI

@main
struct MiniMacaronApp: App {
    @StateObject private var model = BalanceModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
                .task { model.start() }
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
