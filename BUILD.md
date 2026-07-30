# LOLM 视距工具 - IPA 构建指南

## 你不需要 Mac！

因为你没有 Mac，我们改用 **GitHub Actions** 自动编译。
整个项目已经配好了 CI，上传到 GitHub 就会自动构建，不需要本地 Mac。

## 操作步骤

### 1. 把项目推送到 GitHub

在你的 GitHub 上新建一个仓库（Private/Public 都行），然后在终端运行：

```bash
cd C:\Users\lF-T\.openclaw\workspace\cards-pages\lolm-view-distance-ios
git init
git add .
git commit -m "第一次提交"
git remote add origin https://github.com/你的用户名/你的仓库名.git
git push -u origin main
```

### 2. 去 GitHub Actions 页面等编译

推送后打开你的仓库 → **Actions** 标签页 → 会有一个名为 **Build IPA (TrollStore ready)** 的 workflow 正在运行。

等几分钟编译完成后（绿色勾），点进这个 workflow → 在底部 **Artifacts** 区下载 **LOLMViewDistance-unsigned**，里面就是 `.ipa` 文件。

### 3. 安装到手机

- **有 TrollStore：** 把 IPA 发到手机上 → 用 TrollStore 打开 → 直接安装
- **有越狱但没 TrollStore：** 用 Sideloadly 或 AltStore 侧载
- **爱思助手：** 设备连接电脑 → 爱思助手 → 应用游戏 → 导入 IPA

## 使用说明

1. 安装后打开 App
2. App 自动启动本地 HTTP 服务器（127.0.0.1:8080）
3. 切到王者荣耀，呼出 H5GG
4. 在 H5GG 的 WebView 中输入 `http://127.0.0.1:8080/`
5. 即可使用视距调整功能

> ⚠️ 切回游戏后 App 可能被系统挂起，如果加载失败就切回 App 等几秒再切回去

## 项目文件结构

```
lolm-view-distance-ios/
├── project.yml                 # XcodeGen 项目配置
├── BUILD.md                    # 本文件
├── ExportOptions.plist         # IPA 导出配置
├── .github/workflows/build.yml # GitHub Actions 自动构建
├── .gitignore
└── LOLMViewDistance/
    ├── LOLMViewDistanceApp.swift   # App 入口
    ├── ContentView.swift           # 主界面（显示地址）
    ├── LocalHTTPServer.swift       # 本地 HTTP 服务器
    ├── Info.plist                  # App 配置
    ├── index.html                  # 视距脚本（58KB）
    └── Assets.xcassets/            # 图标
```
