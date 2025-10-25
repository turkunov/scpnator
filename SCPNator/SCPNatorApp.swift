import SwiftUI

@main
struct SCPNatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView() // or MainView() if you renamed
                .environmentObject(AppViewModel())
                .frame(minWidth: 900, minHeight: 600)
                .tint(Color("AccentColor"))
        }
    }
}
