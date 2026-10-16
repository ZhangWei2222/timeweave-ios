# TimeWeave iOS

TimeWeave（时序）是一个使用 SwiftUI 构建的原生 iOS 时间管理应用。本期 Demo 启动后会在屏幕中央显示 `Hello world`。

## 本地运行

1. 使用 Xcode 26.3 或更高版本打开 `TimeWeave.xcodeproj`。
2. 在 Xcode 顶部选择一个 iPhone Simulator。
3. 点击运行按钮，或按 `Command-R`。

## 安装到 iPhone

1. 在 Xcode 的 `Settings > Accounts` 中登录 Apple 账户。
2. 用数据线连接 iPhone，并在手机上启用开发者模式。
3. 打开 Target `TimeWeave` 的 `Signing & Capabilities`，选择自己的 Personal Team，并保持 `Automatically manage signing` 开启。
4. 在 Xcode 顶部选择该 iPhone，点击运行按钮。

免费的 Personal Team 可以用于个人真机测试，但签名会周期性到期，需要重新构建安装。
