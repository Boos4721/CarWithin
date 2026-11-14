# CarWithin

这是一个实验性的 iPhone 同机 CarPlay 接收器。它在 iPhone 上接收并显示本机生成的 CarPlay 界面，支持触控和本机播放音频，也可以把画面共享到同一局域网的浏览器。

## 下载与安装

- [下载 CarWithin.ipa](https://github.com/xmz28/CarWithin/releases/download/v0.2/CarWithin.ipa)（包内版本 `0.2`，构建号 `2`）。
- 系统要求为 iOS 16.4 或更高。实际可用性取决于机型、系统版本与签名环境。
- 安装包需要通过支持 IPA 的侧载工具签名后安装。按设备提示完成开发者信任或开发者模式设置。

## 工作原理

1. **建立同机连接**。App 先打开接收端口，再通过 iOS 的 CoreAccessories 私有接口创建虚拟配件。系统与配件建立 iAP2 链路，完成证书挑战与配件识别后，App 请求系统连接到本机接收端。
2. **接收系统画面和音频**。iOS 生成 CarPlay 界面，接收端通过配对验证和 RTSP 协商控制、视频、音频等通道。App 在手机上显示接收的视频并播放音频。触控通过 CarPlay 事件通道回传给系统。
3. **将画面共享给浏览器**。开启共享后，App 通过 WebSocket 把接收到的视频发送给局域网浏览器，并把浏览器操作传回同一 CarPlay 会话。HTTP 模式使用浏览器媒体缓冲播放，HTTPS 模式在浏览器支持 WebCodecs 时可逐帧解码。

## 使用

1. 将 IPA 侧载到 iPhone。打开 App，选择本机接收模式，根据界面提示填写当前 Wi-Fi 信息，确认配件身份就绪。
2. 点击开始连接，允许系统的 CarPlay 请求。画面出现后，可直接在 iPhone 上触控。系统连接浮层若一直挡住画面，可按历史真机记录尝试点 X 收起。
3. 如果想在电脑、平板或另一台手机上操作，开启浏览器共享，让双方连到同一 Wi-Fi，并打开 App 显示的地址。先用 HTTP 地址确认能看到画面。需要低延迟时再试 HTTPS 地址，首次打开可能需要处理自签名证书提示。
4. 浏览器无画面时，先检查同网设备能否互访，并用 H.264 和 HTTP 兼容模式重试。H.265 播放取决于浏览器和设备的解码支持。
5. 用完关闭共享。局域网共享允许能访问地址的客户端查看和触控，HTTPS 负责传输加密，页面本身没有登录校验。

本项目依赖 iOS 私有接口，系统更新可能影响功能。本项目与 Apple 无官方关联。

## 许可与来源

项目采用 GPL-3.0-or-later。配件认证、配对和媒体协议的部分实现参考了 [PlayPort](https://github.com/youcci/playport)、[DiPlay](https://github.com/shihabal3amri/DiPlay) 与 [xcertplay](https://github.com/shilapi/xcertplay)，并使用 MIT 许可的 [BigInt](https://github.com/attaswift/BigInt)。对应源码与完整许可声明见各版本的发布说明。
