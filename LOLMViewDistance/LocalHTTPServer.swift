import Foundation
import Swifter

class LocalHTTPServer: ObservableObject {
    @Published var isRunning = false
    @Published var urlString = ""

    private let server = HttpServer()
    private var port: UInt16 = 8080

    func start() {
        guard !isRunning else { return }

        do {
            guard let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") else {
                print("ERROR: index.html not found in bundle")
                return
            }

            // Serve the HTML file
            server["/"] = shareFile(htmlPath)
            server["/:path"] = shareFile(Bundle.main.resourcePath ?? "")

            // Try port 8080-8099
            for tryPort: UInt16 in stride(from: 8080, to: 8100, by: 1) {
                do {
                    try server.start(tryPort, forceIPv4: true, priority: .default)
                    port = tryPort
                    urlString = "http://127.0.0.1:\(port)/"
                    isRunning = true
                    print("Server started on port \(port)")
                    return
                } catch {
                    continue
                }
            }
            print("ERROR: Could not find available port")
        } catch {
            print("Server error: \(error)")
        }
    }

    func stop() {
        server.stop()
        isRunning = false
    }
}
