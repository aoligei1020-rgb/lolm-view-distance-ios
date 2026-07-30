import UIKit
import WebKit

class ViewController: UIViewController {
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        webView = WKWebView(frame: view.bounds)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.isScrollEnabled = true
        view.addSubview(webView)

        if let path = Bundle.main.path(forResource: "index", ofType: "html"),
           let html = try? String(contentsOfFile: path, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }
    }
}
