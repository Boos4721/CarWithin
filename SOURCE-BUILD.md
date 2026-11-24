# 源码构建说明

使用 Xcode 打开 TDSCarKit.xcodeproj，选择 TDSCarKit scheme，配置自己的开发团队、Bundle ID 和签名，再构建 iOS 目标。最低部署目标为 iOS 16.0。

源码不包含配件认证身份、私钥、证书或 Apple 签名材料。没有可用身份时应用可编译，但本机 CarPlay 连接需要另行配置有效身份。Tools/generate_project.py 会将本地 App/BundledIdentity 内的文件加入生成的工程，请勿把该目录中的身份材料提交到公开仓库。

发布安装包与源码应对应同一代码版本。第三方许可与来源见 THIRD_PARTY_NOTICES.txt 和 LICENSES。

Wi-Fi 自动加入使用 `App/TDSCarKit.entitlements`，包含 `com.apple.developer.networking.HotspotConfiguration` 与 `com.apple.developer.networking.wifi-info`。开发者账号的 App ID 和 provisioning profile 必须支持并启用 Hotspot Configuration / Access WiFi Information；重新签名 IPA 时也需保留这些权限。工程及生成脚本默认设置 `TDS_WIFI_ENTITLEMENTS=App/TDSCarKit.entitlements`。模拟器与 Mac Catalyst 不执行自动加入。

九号自动连接的真机验收步骤见 `docs/ninebot-auto-connect-validation.md`。

默认启用 `TDS_WIFI_NAME_DETECTION=YES`，显示“读取当前 Wi-Fi”入口。读取非本 App 配置的当前网络通常需要用户授予精确定位；该权限仅用于读取 Wi-Fi 名称，不调用位置坐标采集。

## 云端编译未签名 IPA

`.github/workflows/ios-build.yml` 在 `codex/ninebot-ant-bms` 分支推送时使用 GitHub 的 macOS 15 构建机运行核心测试、重新生成 Xcode 工程，再编译 Release iOS 应用。成功后在 Actions 的 Artifacts 中提供未签名 IPA、SHA-256、源代码提交号、签名权限文件及日志。该流程不发布 Release。

安装前需要用自己的签名工具重新签名；有效配件身份仍需另行配置。使用 GitHub 构建不包含或上传本地身份材料。也可在 Mac 上执行与工作流相同的 `xcodebuild` 命令。
