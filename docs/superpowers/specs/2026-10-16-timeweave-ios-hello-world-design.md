# TimeWeave iOS Hello World 设计

## 目标

创建一个可由 Xcode 打开、编译并安装到 iPhone 的原生 iOS 应用。用户从手机桌面打开“时序”后，首屏中央显示 `Hello world`。

## 范围

本阶段只建立可持续扩展的最小工程骨架，不包含时间记录、任务管理、账号、网络、通知、持久化、分析或发布配置。

## 技术方案

- 平台：iOS 16.0 及以上
- 开发工具：Xcode 26.3
- 语言：Swift 6
- 界面：SwiftUI
- 生命周期：SwiftUI App
- 工程名与 Target 名：`TimeWeave`
- 手机桌面显示名：`时序`
- Bundle Identifier：`com.zhangwei2222.timeweave`
- 签名：Xcode 自动管理；仓库不保存个人 Team ID 或证书

## 工程结构

```text
TimeWeave.xcodeproj/
TimeWeave/
  TimeWeaveApp.swift
  ContentView.swift
  Assets.xcassets/
README.md
```

`TimeWeaveApp` 是应用入口，只负责加载 `ContentView`。`ContentView` 使用系统布局在安全区域内居中显示 `Hello world`。资源目录保留应用图标和强调色入口，方便后续替换视觉资产。

## 运行流程

应用启动后创建主窗口，加载 `ContentView`，SwiftUI 完成布局并显示静态文本。该阶段没有输入、状态、数据流或错误分支。

## 验证方式

1. 使用 `xcodebuild` 对通用 iOS Simulator 目标执行无签名编译，确认工程文件和 Swift 代码有效。
2. 使用 Xcode 打开工程，选择用户的 Personal Team 并开启自动签名。
3. 连接已启用开发者模式的 iPhone，选择该设备运行。
4. 验收：App 成功安装；桌面名称为“时序”；点击后稳定显示 `Hello world`。

## 后续扩展约束

后续功能继续放在同一 App Target 中，只有出现明确的共享边界时才拆分模块。Bundle Identifier 在首次对外发布前可以调整；发布后保持稳定，以确保用户能够收到升级。
