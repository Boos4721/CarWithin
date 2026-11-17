# CarWithin

[English](README.md) · **简体中文**

[![Platform: iOS 16.4+](https://img.shields.io/badge/iOS-16.4%2B-blue)](#下载与安装) [![Status: released](https://img.shields.io/badge/status-released-brightgreen)](#快速开始) [![Release](https://img.shields.io/github/v/release/xmz28/CarWithin?label=release)](https://github.com/xmz28/CarWithin/releases/latest)

CarWithin 在同一台 iPhone 上启动、显示和触控本机 CarPlay。你可以直接在 iPhone 上用导航、音乐等 CarPlay 应用，也可以把画面送到同一局域网的车机浏览器、平板、电脑或另一台手机。浏览器接收支持触控回传。

## 下载与安装

- [从 GitHub Releases 下载](https://github.com/xmz28/CarWithin/releases/latest)。当前版本为 **1.0.0（构建 11）**。
- 下载 `CarWithin-1.0.0-unsigned.ipa`，用支持 IPA 的侧载工具按自己的签名方式签名并安装。按设备提示完成开发者信任或开启开发者模式。
- 最低部署目标为 iOS/iPadOS 16.4，arm64。实际可用性取决于设备、系统版本和签名方式。CarWithin 使用 iOS 私有接口，系统升级后可能需要重新验证。

## 快速开始

1. **在 iPhone 上用 CarPlay。** 打开 CarWithin，按提示在「Wi-Fi 与网络」保存当前 Wi-Fi 信息，然后点「启动 CarPlay」。画面出现后即可在 iPhone 上触控，或切换全屏。
2. **用另一台设备接收。** 在「设置 → 输出方式」选择「浏览器」并打开「局域网接收页」。让接收设备和 iPhone 连到同一 Wi-Fi，或让接收设备加入 iPhone 的个人热点。启动 CarPlay 后，在接收设备的浏览器打开 App 显示的 HTTP 地址。
3. **用本机 Safari 接收。** CarPlay 启动后，进入「设置 → 输出方式」，点「在本机浏览器打开」。如果网页显示「开始播放」，点一下即可。
4. **停止共享。** 用完在 iPhone 上停止 CarPlay。局域网接收页目前没有登录校验，可访问地址的设备可以观看与触控。请在信任的网络中使用。

## 浏览器的 HTTP、HTTPS 与声音

| 方式 | 适用场景 | 默认端口 |
| --- | --- | --- |
| HTTP | 首次连接、排查网络，或浏览器需要 MSE 兼容播放时 | 9888 |
| HTTPS | 浏览器支持 WebCodecs，且希望减少画面延迟时 | 9889 |

HTTP 和 HTTPS 端口可分别在「设置 → 输出方式」修改。HTTPS 端口留空时通常使用 HTTP 端口加 1。始终以 App 当前显示的完整地址为准。

### 配置 HTTPS

1. 先在**接收设备**上打开 HTTP 接收页，再点「配置 HTTPS」。核对页面提示与 iPhone 日志中的证书指纹。
2. **iPhone 或 iPad** 下载并安装描述文件，然后在系统「通用 → 关于本机 → 证书信任设置」中开启对该证书的完全信任。**Android** 下载 Android 证书，按页面指引在系统设置中安装为 CA 证书。菜单名称随系统和品牌而异。
3. 打开 App 显示的 HTTPS 地址。如果浏览器没有 WebCodecs，网页会使用兼容播放。

### 选择声音输出

- **由 iPhone 输出**是默认方式。声音走 iPhone 当前选中的扬声器或蓝牙设备，iPhone 连上车机蓝牙时可由车机播放。
- **随画面传输（Wi-Fi）**会让浏览器播放伴音。在「设置 → 声音」选择后重新启动 CarPlay。网页先播放画面，再尝试自动出声。如果浏览器拦截音频自动播放，点「开启声音」即可。通话和 Siri 的声音留在 iPhone。
- 电脑网页点「全屏」后可按 Esc 退出。点「统计」可以查看解码模式、丢帧和音频缓冲等信息。

## 画面设置与车辆按钮

- **跟随车机。** 浏览器会报告接收窗口尺寸。多个接收页同时连接时，第一个接收页决定画面规格，其他接收页观看同一视频流。主接收页关闭后，可由剩余接收页接管。
- **固定尺寸。** 如果车机拉伸画面，或遇到黑屏、卡顿，可在「设置 → 画面」试用固定分辨率、30 FPS 和 H.264。配置改变可能需要重启 CarPlay。
- **车辆按钮。** 在「设置 → 车辆」可启用车辆按钮、选取自己的图标，或恢复默认。图标更改在下次启动 CarPlay 时生效。App 全屏时，可从 CarPlay 主屏幕点车辆按钮退出。如果未显示车辆按钮，可以点左上角退出。
- **画中画与后台。** 在「设置 → 后台与画中画」选择画中画开启时机。使用锁屏继续运行前，在 iPhone 的「设置 → 通用 → CarPlay → CarWithin」开启「锁定时允许 CarPlay」。画中画只显示实时画面，触控在 App 或浏览器中完成。

## 其他输出方式

- **无线 CarLife。** 适用于兼容无线 CarLife 的车机。让车机与 iPhone 连到同一 Wi-Fi 或 iPhone 热点，在 CarWithin 选择 CarLife，再打开车机上的 CarLife，最后启动本机 CarPlay。车机 IP 可手动填写，留空时自动发现。画面与触控走 CarLife，声音可以走车机蓝牙。输出最高为 H.264、1080p、30 FPS。
- **AirPlay（实验）。** 在输出方式选择 AirPlay，启动 CarPlay 并等待画面就绪。在主界面连接卡片点 AirPlay 图标，选取同一网络中的视频接收器。AirPlay 画面有缓冲，触控仍在 iPhone 上完成，声音沿用 iPhone 或车机蓝牙。

## 常见问题

- **网页打不开。** 确认 CarPlay 已启动、局域网接收页已打开、两台设备能互访，并用 App 显示的 HTTP 地址先试。能开 HTTP、HTTPS 提示证书问题时，按上面的步骤在接收设备上配置证书。
- **连接成功但不出画面。** 试用 H.264、较低的分辨率或帧率，也可换浏览器。Redmi K30 5G 的 X 浏览器已实测能播放 HTTP 和 HTTPS。同机的 Chrome 109 曾遇到 H.265 解码失败。若切换网页后出现硬解码器资源不足，重启浏览器再试。
- **网页有画面但没声音。** 检查是否已选「随画面传输（Wi-Fi）」并重新启动 CarPlay。若网页显示「开启声音」，点一下，再检查接收设备的音量。
- **如何查版本或反馈问题。** 在「设置 → 关于」查看版本、检查更新或查看发布记录。反馈问题时请附 iPhone 和接收设备型号、系统、浏览器版本、HTTP/HTTPS、编码和分辨率，以及「设置 → 诊断与实验 → 日志」中相关片段。 [提交问题](https://github.com/xmz28/CarWithin/issues)

## 工作原理与许可

iPhone 通过虚拟配件与本机接收端建立 CarPlay 会话。CarWithin 接收 iOS 生成的画面和声音，并把触控传回系统。开启网页输出后，视频通过 WebSocket 送到接收设备，兼容模式用 MSE，支持时可用 WebCodecs 逐帧解码。

CarWithin 基于 tds-car-kit，采用 GPL-3.0-or-later。CarLife 实现移植自 [OpenXPlay-Stream](https://github.com/OpenXPlay/OpenXPlay-Stream)，采用 AGPL-3.0-only。协议实现参考了 [PlayPort](https://github.com/youcci/playport)、[DiPlay](https://github.com/shihabal3amri/DiPlay) 与 [xcertplay](https://github.com/shilapi/xcertplay)，并使用 MIT 许可的 [BigInt](https://github.com/attaswift/BigInt)。对应源码及第三方声明见 [1.0.0 发布页](https://github.com/xmz28/CarWithin/releases/tag/v1.0.0)。CarWithin 与 Apple 无官方关联。
