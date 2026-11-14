# CarWithin

**English** · [简体中文](README.zh-CN.md)

CarWithin is an experimental CarPlay receiver for the iPhone. The same iPhone generates and displays the CarPlay interface. The app supports touch input and audio playback on the phone, with optional browser sharing over your local network.

## Download and install

- [Download CarWithin.ipa](https://github.com/xmz28/CarWithin/releases/download/v0.2/CarWithin.ipa) (version 0.2, build 2).
- Requires iOS 16.4 or later. Compatibility depends on the device, iOS version, and signing setup.
- Sign and install the IPA with a sideloading tool. Follow any device prompts for developer trust or Developer Mode.

## How it works

1. The app opens a receiver port and uses the private iOS CoreAccessories interface to create a virtual accessory. iOS sets up an iAP2 link for accessory authentication and identification. The app then asks iOS to connect to its local receiver.
2. After pairing verification, the receiver uses RTSP to negotiate the control, video, and audio channels. CarWithin displays the incoming video and plays audio on the iPhone. It sends touch input back to iOS over the CarPlay event channel.
3. When browser sharing is enabled, the app streams video over WebSocket and forwards browser input to the same CarPlay session. HTTP uses buffered playback. HTTPS can use WebCodecs for lower-latency decoding in supported browsers.

## Usage

1. Open CarWithin, choose the local receiver mode, enter your Wi-Fi details if prompted, and check that the accessory identity is ready.
2. Start the connection and accept the iOS CarPlay prompt. Use the iPhone touchscreen once the interface appears. If the system connection overlay stays visible, try closing it with X.
3. To view or control the session from another device, enable browser sharing, connect both devices to the same Wi-Fi network, and open the address shown in the app. Try HTTP first. The optional HTTPS address uses a self-signed certificate.
4. If the browser shows a blank screen, check that the devices can reach each other and retry with H.264 over HTTP. H.265 playback depends on browser and device decoder support.
5. Turn off sharing when finished. Anyone on the local network who can reach the page can view and control the session. HTTPS encrypts the connection, and the page has no login.

CarWithin relies on private iOS interfaces, so system updates may affect compatibility. The project is independent of Apple.

## License and credits

GPL-3.0-or-later. Parts of accessory authentication, pairing, and media handling are adapted from [PlayPort](https://github.com/youcci/playport), [DiPlay](https://github.com/shihabal3amri/DiPlay), and [xcertplay](https://github.com/shilapi/xcertplay). The app uses MIT-licensed [BigInt](https://github.com/attaswift/BigInt). The corresponding source download for this IPA is currently unavailable.