# 电岭电量计 DL：NinebotEnhance 协议核对

核对日期：2026-11-29。用户提供 wx9614-cell/NinebotEnhance，固定提交为 `2eb54bbd47f8edd89c9b7d7423487d520b01b04f`。初次核对仅更新协议依据；随后用户要求接入，Build 51 的实现范围与验证说明见 [DL 接入记录](dl-meter-build51.md)。以下保留参考源码的证据与移植注意事项。

## 新找到的独立读取路径

参考项目不只包含品牌名称，已经实现设备识别、GATT 通道、会话密钥交换、加密帧、轮询和数据布局。用户确认 DL 对应电岭电量计，App 因此使用“电岭电量计”名称。参考源码将协议称为 DL BMS；具体型号与固件仍需用实际设备广播和有效回复确认兼容范围，不因源码文件名将计量器归为保护板。

| 项目 | 参考实现 |
| --- | --- |
| 广播名称 | 前缀 `DL-BMS`，大小写不敏感 |
| 厂商广播 | company ID `0x6C64`，厂商数据以 ASCII `kjmk` 开头 |
| GATT | 服务 FFE0，写入 FFE1，通知 FFE2 |
| 握手 | FC00，secp256k1 ECDH；公钥为 64 字节 X\|\|Y，大端，无 04 前缀 |
| 共享值 | ECDH 点的 32 字节 X 坐标；前 16 字节为 AES key，后 16 字节为 IV |
| 加密 | FC00 明文；后续 AES-128-CBC，零填充到 16 字节倍数，已经对齐时不额外填充 |
| 读取 | FC17 空内容轮询；请求序号递增 |
| 帧格式 | 请求头 A5 5A 00 40，响应头 5A A5 00 40；13 字节头、内容、2 字节小端累加校验 |

参考读取路径没有调用厂商云 API 或要求输入设备绑定口令。但它不能证明所有 DL 固件、首次绑定状态或其他型号都接受此会话方式。

## 可解析字段与转换

- FC17 包含带名称的完整布局和不带名称的精简布局。基础字段包括总压、有符号电流、有符号功率、SOC、额定容量、剩余容量、MOS 状态和温度。
- 完整布局还包含最高／最低／平均单体、压差、循环容量和循环次数；精简布局从有效单体计算极值和压差，不应把没有提供的循环次数填成真实零。
- 参考代码最多解析 32 串、9 路温度。温度是 signed int8；没有明确区分的温度通道不能直接命名为 MOS 温度。
- 电流与功率为负时表示充电。CarWithin 的其他适配器已有放电为正的约定，不能无条件反转正负；需要显式映射充放电状态，并以实车充电／放电对照核对。
- 参考代码对大于 10000 的单体原始数使用除以 13.4 的旧固件换算。这是参考实现中的兼容规则，不能在没有型号与样本证据时当成通用倍率。

## CarWithin 接入时需要完成的工作

1. 独立 DL 协议族和状态机，复用现有设备选择、卡片、统计及仪表叠加；不能套用陆行 FC03。陆行的 FFE2 写／FFE1 通知与 DL 正好相反。
2. 提供经过验证的 secp256k1 实现和 AES-CBC；现有 C 加密桥只提供 AES-CTR，不能拿它直接处理 DL。会话私钥临时生成，不记录到诊断或复用 MFi 身份。
3. 发送边界只允许 FC00 握手及 FC17 读取；通用 FFE0 服务不自动确认 DL 或向未知设备发握手。
4. 回复必须关联当前请求的功能码和序号，并检查分包计数、长度上限、校验及零填充。参考接收流程并未完整验证这些关联条件，不应照搬。
5. 对短帧、粘包、分片、无效曲线公钥、超时、断连、字段缺失及真实零做验证。只有校验有效的实时数据才更新新鲜度和确认设备。
6. 缺失字段保留为可选值。沿用现有手机、九号 4.3／5／7 寸及极核输出通道，仍需分别进行实际 BLE 与仪表测试。

参考仓库的 `BmsTests.java` 包含曲线向量、ECDH 一致性、帧校验、AES 往返以及两种数据布局测试。本次已阅读测试，当前环境没有 Java／javac，未执行；也没有 DL 硬件实测。

## 来源与授权

- [DlBmsProtocol.java](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/app/src/main/java/dev/ichinomiya/ninebotenhance/core/DlBmsProtocol.java)
- [BmsController.java](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/app/src/main/java/dev/ichinomiya/ninebotenhance/bms/BmsController.java)
- [Secp256k1.java](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/app/src/main/java/dev/ichinomiya/ninebotenhance/core/Secp256k1.java)
- [BmsData.java](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/app/src/main/java/dev/ichinomiya/ninebotenhance/core/BmsData.java)
- [BmsTests.java](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/tests/java/BmsTests.java)
- [LICENSE](https://github.com/wx9614-cell/NinebotEnhance/blob/2eb54bbd47f8edd89c9b7d7423487d520b01b04f/LICENSE)：Apache-2.0。实际移植时需保留适用的版权、许可与修改说明。本次没有拷入其实现代码。
