# Time Distribution Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline; user authorized execution without repeated checkpoints.

**Goal:** 本地记录时间、单分类饼图、每日趋势与时段分布。
**Architecture:** Foundation模型与统计核心供App和Swift Package测试共享；MainActor Store管理原子持久化；SwiftUI三个Tab及编辑sheet。
**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Foundation, XCTest; iOS 16+.
**Spec:** docs/superpowers/specs/2026-10-16-time-distribution-design.md

## Global Constraints
- feat/time-distribution-20261016；不合并main；无第三方依赖；中文；iOS 16+。
- 一条记录一个分类、禁止重叠、跨日求交集、分类删除迁移、保存失败不改变内存状态。

## Review Focus
- 跨午夜终点不能计入下一天（Task 1测试）。
- 夏令时日不能假定86400秒（Task 1测试）。
- 编辑排除自身，但不能越过邻接记录（Task 1测试）。
- 删除分类不丢失历史时间（Task 1测试）。
- 损坏数据和写入失败不被空状态覆盖（Task 1测试、Task 2界面检查）。

### Task 1: Core and persistence
**Files:** TimeWeave/Core/{TimeLedger,TimeStatistics,LedgerFile}.swift, Package.swift, Tests/TimeWeaveCoreTests/LedgerTests.swift.
**Interfaces:** TimeLedger.categories/entries, saveEntry(_:now:), saveCategory(_:), deleteCategory(_:replacement:), deleteEntry(_:); TimeStatistics.seconds(_:in:categoryID:), days(ending:count:calendar:), hourly(_:in:categoryID:calendar:); LedgerFile.load()/save(_:).
- [x] 写真实业务测试：无效时间和重叠失败、端点允许、编辑自身、跨日分别1h/1h、DST23/25h、时段9:30–10:30各30m、分类迁移总量不变、重启读回、损坏文件不覆盖、未知版本失败。
- [ ] 实现前的业务失败验证：初次执行受沙箱权限阻止，未获得有效证据；详见验证记录。
- [x] 实现模型、统计和原子JSON存储。
- [x] swift test全绿后提交。

### Task 2: SwiftUI feature
**Files:** TimeWeave/{TimeStore,DesignSystem,ContentView,DayView,EntryEditor,StatisticsView,CategoriesView}.swift, TimeWeave.xcodeproj/project.pbxproj.
**Interfaces:** TimeStore.ledger和throwing更新函数共享核心模型。所有页面使用同一个StateObject。
- [x] 实现Store，保存失败不发布新状态；加载错误提供重试。
- [x] 实现三个Tab、环形图、分类图例、日期导航、记录增删改表单、删除确认。
- [x] 实现7/30天统计、分类明细曲线和小时柱图、分类增删改与迁移选择。
- [x] 注册工程Sources，保留iOS16可用API，Swift Charts绘制柱/线、Shape绘制圆环。
- [x] 两套SDK构建通过，README已更新，首次实施时模拟器安装启动成功。
- [ ] 逐项界面操作和重启验收：Computer Use权限未授予，待人工确认。

### Task 3: Review and delivery
- [x] 独立检查全部diff、统计口径、可访问性、数据丢失边界。
- [x] 跑全量测试、确认最终构建与工作区、推送功能分支，报告运行方式及验证范围。

## 验证记录

见 `docs/superpowers/specs/2026-10-16-time-distribution-verification.md`。勾选项代表已实现或已验证；未勾选项保留真实限制。
