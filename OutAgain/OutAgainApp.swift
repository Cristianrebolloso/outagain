import SwiftUI

@main
struct OutAgainApp: App {
    @State private var store = AppStore()
    @State private var permissionCenter = PermissionCenter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(permissionCenter)
                .preferredColorScheme(.dark)
        }
    }
}
