# CarWithin

**English** · [简体中文](README.zh-CN.md)

CarWithin runs CarPlay on the same iPhone that generates its interface. Use CarPlay directly on your iPhone for navigation and music, or send the display to a head unit, tablet, computer, or another phone on the local network. A receiving browser can send touch input back to CarPlay.

## Download and install

- [Download from GitHub Releases](https://github.com/xmz28/CarWithin/releases/latest). The current version is **1.0.0 (build 11)**.
- Download `CarWithin-1.0.0-unsigned.ipa` and sign and install it with an IPA sideloading tool using your own signing setup. Follow any iOS prompts for developer trust or Developer Mode.
- The minimum deployment target is iOS/iPadOS 16.4 on arm64. CarWithin uses private iOS interfaces. Compatibility depends on the device, OS version, and signing setup, and OS updates can affect it.

## Quick start

1. **Use CarPlay on the iPhone.** Open CarWithin, save your Wi-Fi details in the app if prompted, and start CarPlay. Once the display appears, you can use touch controls or switch to fullscreen.
2. **Use another device as the display.** In the app's output settings, choose Browser and enable the local receiver page. Connect both devices to the same Wi-Fi, or connect the receiving device to the iPhone's personal hotspot. Start CarPlay and open the HTTP address displayed by the app in the receiving browser.
3. **Use Safari on the same iPhone.** After starting CarPlay, use the option to open the receiver in the local browser under the app's output settings. If the page prompts you to start playback, tap it.
4. **Stop sharing when finished.** Stop CarPlay from the iPhone. The browser receiver has no sign-in. A device that can reach its address can view and control the CarPlay session, so use a trusted network.

## Browser playback and audio

| Mode | When to use it | Default port |
| --- | --- | --- |
| HTTP | First connection, network troubleshooting, or MSE compatibility playback | 9888 |
| HTTPS | Lower-latency playback in browsers with WebCodecs support | 9889 |

You can set the HTTP and HTTPS ports separately in the app's output settings. A blank HTTPS port typically uses the HTTP port plus one. Use the full address shown in the app.

### Set up HTTPS

1. Open the HTTP receiver page on the **receiving device**, then choose HTTPS setup. Check its certificate fingerprint against the iPhone app log.
2. On **iPhone or iPad**, download and install the profile, then enable full trust for its certificate under **General → About → Certificate Trust Settings**. On **Android**, download the Android certificate and follow the setup page to install it as a CA certificate. Menu names vary by device and OS.
3. Open the HTTPS address shown in the app. Browsers without WebCodecs use compatibility playback.

### Choose where audio plays

- **iPhone output** is the default. Sound follows the speaker or Bluetooth device currently selected by iOS, including a paired head unit.
- **Wi-Fi audio** sends sound to the browser. Select it in the app's audio settings, then restart CarPlay. The page starts video and attempts to play audio automatically. If the browser blocks autoplay, use the on-page button to enable audio. Calls and Siri stay on the iPhone.
- On a computer, press Esc to exit browser fullscreen. The statistics control shows the decoder, dropped frames, and audio buffering.

## Display settings and the vehicle button

- **Follow the receiving display.** The browser reports its viewport. When several receiver pages connect, the first one determines the stream settings and the others receive the same video stream. If the first page closes, a remaining page can take over.
- **Use a fixed size.** If a head unit stretches the picture, shows a black screen, or stutters, try a fixed lower resolution, 30 FPS, or H.264 in the display settings. Applying a new display configuration may require restarting CarPlay.
- **Customize the vehicle button.** Use the vehicle settings to enable the button, pick a photo as its icon, or restore the default. Changes take effect when CarPlay starts again. In app fullscreen, use the vehicle button on the CarPlay home screen to exit. If the vehicle button is disabled, use the upper-left exit button.
- **Picture in Picture and background playback.** Choose when PiP should start in the app's background and PiP settings. For lock-screen use, enable **Allow CarPlay While Locked** under **Settings → General → CarPlay → CarWithin** on the iPhone. PiP shows live video. Use the app or browser for touch input.

## Other output methods

- **Wireless CarLife.** For compatible head units, connect the head unit and iPhone to the same Wi-Fi or the iPhone hotspot. Select CarLife in CarWithin, open CarLife on the head unit, then start CarPlay. CarWithin can discover the head unit or use an IP address you enter. CarLife carries video and touch input, with H.264 up to 1080p at 30 FPS. Audio can play through the head unit's Bluetooth connection.
- **AirPlay (experimental).** Select AirPlay and start CarPlay. When the display is ready, use the AirPlay picker on the main screen to select a video receiver on the same network. AirPlay video is buffered. Touch input stays on the iPhone, and audio follows the iPhone or head unit Bluetooth route.

## Troubleshooting

- **The page will not open.** Check that CarPlay is running and the local receiver page is enabled. Confirm that the devices can reach each other and try the HTTP address first. If HTTPS shows a certificate error, follow the setup steps on the receiving device.
- **The page connects but shows no picture.** Try a different browser, H.264, a lower resolution, or a lower frame rate. X Browser played HTTP and HTTPS on a Redmi K30 5G in testing. Chrome 109 on the same device showed an H.265 decoding error. If switching pages exhausts the hardware decoder, restart the browser and try again.
- **The picture plays without sound.** Select Wi-Fi audio in the app, restart CarPlay, and use the browser's enable-audio button if it appears. Check the volume on the receiving device.
- **Check your version or report a problem.** Open **Settings → About** for the installed version, update check, and release history. For a bug report, include the device models, OS and browser versions, HTTP or HTTPS, codec and resolution, and any relevant lines from the app's diagnostic log. [Report an issue](https://github.com/xmz28/CarWithin/issues)

## How it works and license

A virtual accessory lets the iPhone connect to its local CarPlay receiver. CarWithin presents video and audio generated by iOS and sends touch events back. The browser receives the video over WebSocket, using MSE for compatibility or WebCodecs for low-latency decoding where supported.

CarWithin is based on tds-car-kit and uses GPL-3.0-or-later. The CarLife implementation is adapted from [OpenXPlay-Stream](https://github.com/OpenXPlay/OpenXPlay-Stream) under AGPL-3.0-only. Protocol work draws on [PlayPort](https://github.com/youcci/playport), [DiPlay](https://github.com/shihabal3amri/DiPlay), and [xcertplay](https://github.com/shilapi/xcertplay). The project also uses the MIT-licensed [BigInt](https://github.com/attaswift/BigInt) library. See the [1.0.0 release](https://github.com/xmz28/CarWithin/releases/tag/v1.0.0) for corresponding source and third-party notices. CarWithin is an independent project and has no official affiliation with Apple.
