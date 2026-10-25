# TimeWeave · 时序

一个使用 SwiftUI 构建的原生 iOS 时间记录应用，支持 iOS 16 及以上。无需账号、后端或第三方依赖。

## 已实现

- **记录**：按日期查看环形饼图、分类时长和记录列表；点击开始进行实时计时，点击结束后在页面内自绘确认面板中调整时间、选择分类并确认，也可编辑或删除历史时间段。
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
4. 在记录页点击「开始」启动计时，底部卡片会持续显示时长；点击卡片右侧的「结束」进入自绘确认面板（不是系统表单），选择分类后保存。同日记录默认折叠日期控件，需要时可点「调整日期」；点击已有记录可编辑或删除。

真机运行：在 Xcode 的 Settings > Accounts 登录 Apple 账户，连接并信任 iPhone，启用开发者模式，在 Signing & Capabilities 选择自己的 Team，选择该手机后运行。工程不包含个人签名身份。

## V2 AI 时间分析

在 Mac 的 `selfweave-agent` 仓库设置 `SELFWEAVE_MODEL_BASE_URL`、`SELFWEAVE_MODEL_API_KEY`、`SELFWEAVE_MODEL_NAME`，运行 `go run ./cmd/selfweave-server`。在 iOS Simulator 打开「统计 → AI 分析近 7／30 天」，输入问题后提交。

App 默认连接 `http://127.0.0.1:8787/v1/analysis`，发送统计范围、时区、总分钟、分类名称/分钟、每日日期/分钟和问题。不会发送原始记录、备注或 UUID；百炼密钥只保存在服务端。问题和聚合数据会发送给百炼，并写入当前服务所在机器的私有运行日志。

每次分析独立，不保留聊天上下文；出错后可手动重试。默认 35 秒客户端超时，Go 分析超时 30 秒。看到连接错误时，先核对分析页显示的环境和地址。

### 本地／远端开关

进入「统计 → AI 分析近 7／30 天 → 右上角服务设置」，选择本地或远端并保存。两边地址分别保存，选择跨重启保留，不用重新编译；失败不会自动切到另一边。保存配置会取消在途请求并清空旧结果，但不能撤回服务端已收到的分析。

- 本地：默认 `http://127.0.0.1:8787`，适合模拟器访问 Mac。真机与 Mac 在同一可信局域网时可改为 `http://<Mac 的内网 IP>:8787` 或 `.local` 主机名；需要允许 App 本地网络权限，并让 Mac 服务监听该内网接口、配置防火墙。默认只监听回环的服务不会因此自动对手机开放。不要将无鉴权本地服务暴露到公网。
- 远端：填写 HTTPS 服务地址和该服务的访问令牌；地址只填协议、主机及可选端口，不加 `/v1/analysis`。默认预填 `https://api.super-vivian.top` **不表示公网入口已开通**：当前 ECS 服务仅监听服务器 `127.0.0.1:8787`，需要后续建立安全网络通道才能从手机直接访问。
- 令牌：填写的是 selfweave 服务的 Bearer 令牌，**不是阿里云 AK，也不是百炼 API Key**。仅保存在当前设备钥匙串，不在设置里回显；空输入表示保留该地址已有令牌。更换域名、协议或非默认端口后需重新提供对应令牌，不会把旧地址令牌发给新地址。可在设置中显式删除已保存的令牌。

所有请求拒绝 HTTP 重定向；远端不支持明文 HTTP，不绕过 TLS 证书校验。UserDefaults 仅保存环境与地址；Keychain 使用设备本地、解锁时可用的保护，不通过 iCloud 同步。重新安装可能仍保留同签名 App 的钥匙串条目，需要撤销时显式删除或轮换服务端令牌。

测试设置页的远端令牌功能时应使用签名的模拟器构建（Xcode 默认即可）；`CODE_SIGNING_ALLOWED=NO` 仅用于编译检查，未签名 App 调用 Keychain 会报 `-34018`。模拟器 UI 验证可指定 `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=<自己的 Team>`；不要关闭钥匙串保护来迁就未签名测试。

端到端 UI 测试通过单独的 `TimeWeaveLocalAnalysis` scheme 显式执行。使用全新模拟器（成功用例会创建一条 60 分钟的测试记录），先启动本机服务：

```sh
xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeaveLocalAnalysis \
  -destination 'platform=iOS Simulator,id=<全新模拟器的 UDID>' \
  -only-testing:TimeWeaveLocalAnalysisTests/LocalAnalysisUITests/testSnapshotAnalysisReachesServerAndDisplaysAnswer \
  CODE_SIGNING_ALLOWED=NO test
```

验证服务未启动的错误页时，先停止服务，将 `-only-testing` 的方法改为 `testUnavailableServerShowsRetry`。两种测试的外部服务前提相反，应分别运行。

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

支持可跨重启恢复的实时计时与事后补录；计时由持久化时间戳计算，不依赖后台常驻任务。暂不包含提醒、Live Activity、桌面组件、账号、同步或导入导出。App Icon 暂沿用第一期的默认图标，资源目录尚未加入编译。
