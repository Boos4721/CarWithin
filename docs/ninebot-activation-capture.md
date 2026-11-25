# 九号仪表投屏激活：iPhone 采集说明

## 当前结论

用户实测仍需在九号出行开启导航投屏，仪表才显示 CarWithin 画面。当前版本可以加入 Wi-Fi、建立本机 CarPlay 会话并发送五寸/七寸视频，尚未实现替代九号出行的仪表激活指令。用户确认官方快捷指令没有投屏操作，不使用快捷指令作为现成的激活方案。

已有日志确认本机 iAP2 认证、Pair-Setup、Pair-Verify、媒体 SETUP 和 H.264 视频均成功；UDP 5013 控制回应或本机视频启动不能用来判断仪表已切换投屏模式。

尚缺少的证据是：官方 App 开启/关闭投屏前后的控制通信、车辆认证过程，以及激活回应。激活是否完全走蓝牙、是否有额外 Wi-Fi 控制步骤，仍需用实测日志判断。

## 只用 iPhone 进行采集

Apple 提供 Bluetooth for iOS/iPadOS 的日志描述文件，并指导在复现后生成 sysdiagnose。采集可先在 iPhone 上完成；日志是否包含本次需要的完整报文，需检查实际文件。

1. 用 iPhone 的 Safari 打开 [Apple Profiles and Logs](https://developer.apple.com/feedback-assistant/profiles-and-logs/?platform=ios&name=bluetooth)。找到 **Bluetooth for iOS/iPadOS**，下载 **Profile** 和 **Instructions**。下载可能要求在 Apple 页面登录 Apple 账号。
2. 按 Apple 的 Instructions 安装描述文件、重启并启用相应记录。在 CarWithin 停止 CarPlay，采集期间暂时关闭 BMS 读取，减少另一条蓝牙链路的干扰。
3. 靠近并启动自己的车辆，在九号出行按平时方式连接。投屏尚未开启时等待约 10 秒，记下时间；点击“导航投屏”，等仪表出画后再等待约 10 秒；关闭投屏，再记下时间。记录这次是五寸还是七寸、车型、仪表固件版本和九号出行版本；不知道的项目标为未知。
4. 尽快按 Apple Instructions 触发 sysdiagnose，等待生成。可在 iPhone 设置的“分析数据”中寻找对应时间、以 `sysdiagnose_` 开头的诊断文件，并使用分享菜单保存到“文件”。具体菜单和按键以 Apple 当前 Instructions 为准。

先记录诊断文件名、大小和上述两个操作时间。系统诊断包可能包含其他手机信息和蓝牙配对材料，不应提交到公开仓库。检查实际包结构后再提取相关蓝牙日志，不要求先公开上传整包。若采集没有 HCI/ATT 数据，不能将其当作已取得激活协议。

采集完成后，按 Apple 说明关闭记录或移除日志描述文件。五寸、七寸分别采集，不能把一台仪表上的激活参数直接当作另一型号的参数。

## 后续实现与验收

- 识别官方启停时实际发送的指令、目标服务/特征、帧格式、认证依赖与回应，区分导航数据、视频保活和模式切换。
- 只移植经过确认的投屏启停流程；若存在动态令牌或计数，不能简单重放一次采集的字节。
- 冷启动车辆且不手动开启官方投屏，从 CarWithin 启动，必须以仪表实际出画为验收结果。只连接 Wi-Fi、只收到 UDP 回应或只看到手机 CarPlay 都不足以通过。

## 参考

- [Apple 工程师：安装 Bluetooth 日志描述文件、重启、复现并立即采集 sysdiagnose](https://developer.apple.com/forums/thread/801718)
- [Apple：Profiles and Logs](https://developer.apple.com/feedback-assistant/profiles-and-logs/?platform=ios&name=bluetooth)
- [Apple WWDC22：描述文件安装后复现并采集 sysdiagnose](https://developer.apple.com/videos/play/wwdc2022/10119/)
- [NinebotEnhance：调用官方巡航入口的实现](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/app/src/main/java/dev/ichinomiya/ninebotenhance/ui/DirectCastController.java)
- [NinebotEnhance：导航数据发送依赖官方设备接口，投屏启停由官方负责](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/app/src/main/java/dev/ichinomiya/ninebotenhance/hook/NaviSender.java)

## 官方投屏助手已移除（Build 39）

开发分支已移除官方投屏助手页面、助手报告导入与配套观察插件、IPA 注入准备工具；CI 不再构建或分发这些工具。Build 26–29 的验证文档仅保留为历史记录。

现有九号车辆 BLE 配对、投屏连接和连接诊断仍保留。独立激活能否在具体车型上成功，仍以冷启动实车出画为准。
