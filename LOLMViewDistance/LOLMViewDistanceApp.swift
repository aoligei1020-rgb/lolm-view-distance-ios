import SwiftUI

@main
struct LOLMViewDistanceApp: App {
    @StateObject private var server = LocalHTTPServer()

    var body: some Scene {
        WindowGroup {
            ContentView(server: server)
                .onAppear { server.start() }
        }
    }
}
