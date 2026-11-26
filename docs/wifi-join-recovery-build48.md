# Build 48：仪表 Wi-Fi 错误恢复与诊断

用户提供 Build 47 的连接报告：普通自签安装，Wi-Fi 加入请求约 0.03 秒即返回 `internal error`，报告生成时有 `192.168.1.5`；彦阳 BMS 实时数据已连接。失败发生在 Wi-Fi 阶段，不能据此判断密码错误、MFi 失败或已连接正确仪表网络。

原逻辑仅在正在通过 BLE 准备车辆热点时重试 `internal/pending`；其他情形立即失败。本次调整：

- 遇到这两类临时错误，先以 0.5 秒间隔重新读取当前网络，最多四次。确认目标 SSID 后转入已有的网络就绪等待，不再重复申请加入；必须再次看到同一目标 SSID 与稳定的可用 IPv4 才启动 CarPlay。
- 当前名称未知、同网段 IP、其他 SSID、DHCP 链路本地地址都不足以启动。丢失名称或地址变化会重置连续观察。
- 普通加入最多重试两次；原 BLE 热点准备最多重试五次；所有操作仍受同一 60 秒总超时和取消标识约束。用户拒绝、无效配置等不重试。
- 报告新增 `wifiJoin`，记录原始错误域/码、请求次数、恢复结果、名称读取的分类（目标/其他/未知）、当时 Wi-Fi 地址、定位授权数值、精确位置状态与构建的 SSID 检测开关。不会导出 SSID 名称、密码、BSSID、NSError userInfo 或身份材料。
- `ssidDetectionConfigured` 只说明构建开关，不代表实际签名拥有权限。失败提示说明普通自签需核对 Hotspot Configuration、Access Wi-Fi Information，并可在系统设置先连接仪表热点，再返回重试。

项目原本已经声明两个 Wi-Fi entitlement。本次不增加或猜测运行时授权，不修改系统已保存网络，也不尝试从系统提取 Wi-Fi 密码。若描述文件/重签名不具备所需能力，代码重试不能补齐，需要用具有相应能力的签名重新安装。

六项纯 Swift 回归覆盖目标 SSID/IP 连续观察、同网段误判、未知名称、地址变更、不可用地址、两档重试上限、拒绝与永久错误不重试。实际普通自签安装后的行为仍需复测。

Apple 参考：
- https://developer.apple.com/documentation/networkextension/nehotspotconfigurationerror
- https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:)
- https://developer.apple.com/documentation/networkextension/nehotspotconfigurationmanager
