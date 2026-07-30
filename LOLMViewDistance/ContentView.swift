import SwiftUI

struct ContentView: View {
    @ObservedObject var server: LocalHTTPServer
    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 50))
                .foregroundColor(.blue)
                .padding(.bottom, 8)

            Text("LOLM 视距工具")
                .font(.largeTitle)
                .bold()

            Text("本地 HTTP 服务器")
                .font(.headline)
                .foregroundColor(.secondary)

            if server.isRunning {
                VStack(spacing: 16) {
                    Label("服务器运行中", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)

                    Text("在 H5GG 中打开此地址：")
                        .font(.subheadline)

                    Text(server.urlString)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                    Button(action: {
                        UIPasteboard.general.string = server.urlString
                        showCopied = true
                    }) {
                        Label("复制地址", systemImage: "doc.on.doc")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .alert("已复制到剪贴板", isPresented: $showCopied) {
                        Button("好的", role: .cancel) {}
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Label("服务器未运行", systemImage: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.title3)

                    Button("重新启动") {
                        server.start()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()

            VStack(spacing: 4) {
                Text("使用说明")
                    .font(.caption)
                    .bold()
                Text("1. 打开本 App，确认地址已显示\n2. 打开王者荣耀（确保 H5GG 已安装）\n3. 呼出 H5GG，在 WebView 中输入上方地址\n4. 即可使用视距调整功能")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .padding()
    }
}
