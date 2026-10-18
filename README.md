# TimeWeave · 时序

一个使用 SwiftUI 构建的原生 iOS 时间记录应用，支持 iOS 16 及以上。无需账号、后端或第三方依赖。

## 已实现

- **记录**：按日期查看环形饼图、分类时长和记录列表；新增、编辑、删除时间段，填写描述并选择一个分类。
- **统计**：最近 7／30 天总时长与每日趋势；点击分类查看每日时长曲线、0–23 时累计分钟柱状图和每日明细。
- **分类**：初始提供工作、阅读、睡觉、其他；支持新增、改名、换颜色、删除。使用中的分类删除前必须选择迁移目标，至少保留一个分类。
- **本地保存**：记录与分类写入 App 的 Application Support/TimeWeave/ledger.json，重启后保留；卸载会删除本地数据，当前没有云同步或导出。

## 统计规则

每条记录只能选择一个分类。结束时间必须晚于开始时间且不能晚于现在，记录不能重叠，相邻端点允许。跨午夜记录按各天实际时长统计，跨小时记录按小时拆分。自然日按设备当前时区划分，并处理夏令时。

每日饼图以完整自然日为分母，包含「未记录」；今天尚未发生的部分单独显示为「尚未到来」。分类统计折线图单位为小时；小时分布柱图显示所选区间各小时的累计分钟。空数据不会自动填充示例记录。

## 在 Xcode 运行

1. 用 Xcode 26.3 或更高版本打开 `TimeWeave.xcodeproj`。
2. 选择 Scheme `TimeWeave` 和一台已安装系统的 iPhone Simulator。
3. 按 `Command-R`，进入「记录／统计／分类」三个页面。
4. 在记录页点击「添加时间」，保存后可返回查看饼图；点击记录可编辑或删除。

真机运行：在 Xcode 的 Settings > Accounts 登录 Apple 账户，连接并信任 iPhone，启用开发者模式，在 Signing & Capabilities 选择自己的 Team，选择该手机后运行。工程不包含个人签名身份。

## 自动验证

核心模型由 App 和 Swift Package 共用，测试不需要模拟器：

```sh
swift test
```

测试覆盖重叠与邻接时间、编辑排除自身、无效和未来时间、跨午夜、小时切分、23／25 小时夏令时日、分类迁移与重命名、本地文件往返、损坏文件保护、未知版本及写入失败。

未签名的两套 SDK 编译：

```sh
xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 当前范围

支持事后补录，暂不包含实时计时器、提醒、账号、同步或导入导出。App Icon 暂沿用第一期的默认图标，资源目录尚未加入编译。
