import CoreBluetooth
import Foundation
import UIKit

/// Read-only multibrand telemetry. Main-queue owned, explicit device and family selection.
/// Existing ANT preference keys and the callback model remain compatible with older builds.
final class ANTBMSClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device {
        let id: UUID
        let name: String
        let rssi: Int
        let family: BMSFamily?
        let advertisedSOC: Int?
    }
    private struct Link { let writer: CBCharacteristic; let reader: CBCharacteristic }
    private let defaults: UserDefaults
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var found: [UUID: Device] = [:]
    private var links: [Link] = []
    private var linkIndex = -1
    private var remainingServices = 0
    private var writer: CBCharacteristic?
    private var reader: CBCharacteristic?
    private var parser = BMSReadOnlyProtocol(family: .ant)
    private var timer: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var enabled = false
    private var automaticReconnect = true
    private var scanRequested = false
    private var writePending = false
    private var sendQueue: [Data] = []
    private var queuedAt = 0.0
    private var connectedAt: TimeInterval?
    private var channelAt: TimeInterval?
    private var lastValidAt: TimeInterval?
    private var retryDelay: TimeInterval = 2
    private var disconnecting = Set<UUID>()
    private var access: BMSAccessStore.Access?
    private(set) var status = "未连接 BMS"
    private(set) var sample: ANTBMSSample?
    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?
    var devices: [Device] { found.values.sorted { $0.rssi > $1.rssi } }
    var selectedID: UUID? { defaults.string(forKey: "antBMSPeripheral").flatMap(UUID.init(uuidString:)) }
    var selectedName: String { defaults.string(forKey: "antBMSName") ?? "未选择" }
    var selectedFamily: BMSFamily {
        guard let id = selectedID else { return .ant }
        return defaults.string(forKey: "bmsFamily." + id.uuidString).flatMap(BMSFamily.init(rawValue:)) ?? .ant
    }
    var freshReading: ANTBMSReading? {
        guard let sample, sample.isFresh(at: ProcessInfo.processInfo.systemUptime) else { return nil }
        return sample.reading
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; super.init()
        clearUnsupportedSelection()
    }
    @discardableResult
    private func clearUnsupportedSelection() -> Bool {
        guard let id = selectedID,
              let raw = defaults.string(forKey: "bmsFamily." + id.uuidString),
              BMSFamily(rawValue: raw) == nil else { return false }
        defaults.removeObject(forKey: "antBMSPeripheral")
        defaults.removeObject(forKey: "antBMSName")
        sample = nil
        update("原板型已不再支持，请重新选择设备与板型")
        return true
    }
    deinit { timer?.invalidate(); reconnectWork?.cancel(); scanTimeout?.cancel() }
    func start() {
        guard !enabled else { return }
        enabled = true
        automaticReconnect = true
        if central == nil { central = CBCentralManager(delegate:self,queue:.main) }
        else if central?.state == .poweredOn { connectRememberedOrScan() }
        else { update("等待蓝牙可用") }
        let timer = Timer(timeInterval:0.25,repeats:true) { [weak self] _ in self?.tick() }
        self.timer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func stop() {
        enabled=false;scanRequested=false;timer?.invalidate();timer=nil
        reconnectWork?.cancel();reconnectWork=nil;scanTimeout?.cancel();scanTimeout=nil
        central?.stopScan();clearConnection();update("未连接 BMS")
    }
    func scan() {
        guard enabled else { return }
        scanRequested=true;found.removeAll();discovered.removeAll();beginScan()
    }
    func select(_ id:UUID, family: BMSFamily? = nil) {
        guard enabled,let device=found[id],let family=family ?? device.family else { return }
        automaticReconnect = true
        if selectedID != id { sample=nil }
        defaults.set(id.uuidString,forKey:"antBMSPeripheral");defaults.set(device.name,forKey:"antBMSName")
        defaults.set(family.rawValue,forKey:"bmsFamily."+id.uuidString)
        reconnectWork?.cancel();reconnectWork=nil;scanTimeout?.cancel();scanTimeout=nil
        central?.stopScan();scanRequested=false;clearConnection();retryDelay=2
        connectRememberedOrScan()
    }
    func setFamily(_ family:BMSFamily) {
        guard let id=selectedID else { return }
        automaticReconnect = true
        defaults.set(family.rawValue,forKey:"bmsFamily."+id.uuidString)
        reconnectWork?.cancel();reconnectWork=nil;central?.stopScan();clearConnection()
        if enabled { connectRememberedOrScan() } else { update(family.supportDescription) }
    }
    func saveAccess(password:String,mac:String) throws {
        guard let id=selectedID else { return }
        let password=password.trimmingCharacters(in:.whitespacesAndNewlines)
        let mac=mac.trimmingCharacters(in:.whitespacesAndNewlines)
        if !password.isEmpty {
            let valid = selectedFamily == .jbd
                ? password.utf8.count==6 && password.utf8.allSatisfy { (32...126).contains($0) }
                : password.range(of:"^[0-9]{6}$|^[0-9A-Fa-f]{12}$",options:.regularExpression) != nil
            guard valid else { throw AccessError.invalidPassword }
        }
        guard mac.isEmpty || mac.range(of:"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$",options:.regularExpression) != nil else { throw AccessError.invalidMAC }
        try BMSAccessStore.save(.init(password:password,mac:mac),id:id)
        setFamily(selectedFamily)
    }
    enum AccessError: LocalizedError {
        case invalidPassword, invalidMAC
        var errorDescription:String? {
            self == .invalidMAC ? "请输入真实的六字节 MAC，例如 AA:BB:CC:DD:EE:FF；不清楚可留空。" : "JBD 密码需六位可打印字符；蓝宝匹配码需六位数字或十二位十六进制。"
        }
    }
    func forget() {
        let id=selectedID
        central?.stopScan();scanTimeout?.cancel();clearConnection();reconnectWork?.cancel();reconnectWork=nil
        if let id { BMSAccessStore.remove(id);defaults.removeObject(forKey:"bmsFamily."+id.uuidString) }
        defaults.removeObject(forKey:"antBMSPeripheral");defaults.removeObject(forKey:"antBMSName")
        if enabled { scan() } else { update("未选择 BMS") }
    }
    func restoreSelection(id:UUID?,name:String?,family:String? = nil) {
        automaticReconnect = true
        clearConnection();reconnectWork?.cancel();reconnectWork=nil
        central?.stopScan();scanTimeout?.cancel()
        if let id {
            defaults.set(id.uuidString,forKey:"antBMSPeripheral");defaults.set(name ?? "BMS",forKey:"antBMSName")
            if let family { defaults.set(family,forKey:"bmsFamily."+id.uuidString) }
        } else { defaults.removeObject(forKey:"antBMSPeripheral");defaults.removeObject(forKey:"antBMSName") }
        if clearUnsupportedSelection() { return }
        if enabled { connectRememberedOrScan() } else { update("已恢复车辆 BMS 配置") }
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard enabled else { return }
        if central.state == .poweredOn {
            if scanRequested {beginScan()}else{connectRememberedOrScan()}
        } else {
            reconnectWork?.cancel();reconnectWork=nil;scanTimeout?.cancel();scanTimeout=nil
            clearConnection();disconnecting.removeAll()
            switch central.state {
            case .unauthorized:update("蓝牙权限未允许，请在系统设置中开启")
            case .poweredOff:update("蓝牙已关闭")
            case .unsupported:update("此设备不支持 BMS 蓝牙读取")
            default:update("等待蓝牙可用")
            }
        }
    }
    private func connectRememberedOrScan() {
        guard enabled,let central,central.state == .poweredOn,peripheral==nil else{return}
        guard let id=selectedID else{scan();return}
        let family=selectedFamily
        if !family.supportsGATT {
            if family == .xiaoha {scanRequested=true;beginScan()}
            else {update(family.supportDescription)}
            return
        }
        guard !disconnecting.contains(id) else{scheduleReconnect();return}
        do {access=try BMSAccessStore.load(id)} catch {update(error.localizedDescription);return}
        if let target=discovered[id] ?? central.retrievePeripherals(withIdentifiers:[id]).first {
            central.stopScan();scanTimeout?.cancel();peripheral=target;target.delegate=self
            parser=BMSReadOnlyProtocol(family:family,password:access?.password,mac:access?.mac)
            connectedAt=ProcessInfo.processInfo.systemUptime
            update("正在连接 \(selectedName)（\(family.shortName)）…");central.connect(target)
        } else {scanRequested=true;beginScan()}
    }
    private func beginScan() {
        guard enabled,let central,central.state == .poweredOn else{return}
        scanTimeout?.cancel()
        let services=Array(Set(BMSFamily.allCases.flatMap { $0.channels.map(\.service) })).map(CBUUID.init(string:))
        central.scanForPeripherals(withServices:UIApplication.shared.applicationState == .active || selectedFamily == .xiaoha ? nil:services,
            options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])
        update(selectedFamily == .xiaoha && selectedID != nil ? "正在监听小哈广播电量…":"正在扫描 BMS 与电量计…")
        let timeout=DispatchWorkItem { [weak self] in
            guard let self,self.enabled else{return}
            self.central?.stopScan();self.scanRequested=false
            if self.peripheral==nil {
                if self.selectedFamily != .xiaoha || self.freshReading==nil {self.update(self.found.isEmpty ? "未找到 BMS，请确认蓝牙模块已开启":"请选择自己的设备与板型")}
                if self.selectedID != nil {self.scheduleReconnect()}
            }
        }
        scanTimeout=timeout;DispatchQueue.main.asyncAfter(deadline:.now()+15,execute:timeout)
    }
    func centralManager(_ central:CBCentralManager,didDiscover item:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard enabled else{return}
        let name=advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? item.name ?? "未命名设备"
        let services=((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])+(advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])).map(\.uuidString)
        let manufacturer=advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let company=manufacturer.flatMap { data -> UInt16? in guard data.count>=2 else{return nil};let b=[UInt8](data);return UInt16(b[0])|UInt16(b[1])<<8 }
        let family=BMSFamily.identify(name:name,services:services,manufacturerID:company)
        let relevant=family != nil || services.contains { service in
            ["FFE0","FF00","FEE9","FA00","6E400001-B5A3-F393-E0A9-E50E24DCCA9E"].contains(service.uppercased())
        } || item.identifier==selectedID
        guard relevant,!name.uppercased().hasPrefix("CJ01"),found[item.identifier] != nil || found.count<100 else{return}
        let soc=BMSFamily.advertisedSOC(name)
        discovered[item.identifier]=item
        found[item.identifier]=Device(id:item.identifier,name:name,rssi:RSSI.intValue,family:family,advertisedSOC:soc)
        if selectedID==item.identifier,selectedFamily == .xiaoha,let soc {
            var values=BMSValues();values.soc=soc;values.details["数据来源"]="HBB 名称广播，只有电量"
            sample=ANTBMSSample(reading:values.reading(.xiaoha),uptime:ProcessInfo.processInfo.systemUptime)
            update("小哈广播电量已更新；无 GATT 直连")
        } else {
            onChange?()
            if selectedID==item.identifier,peripheral==nil,selectedFamily.supportsGATT {connectRememberedOrScan()}
        }
    }
    func centralManager(_ central:CBCentralManager,didConnect item:CBPeripheral) {
        guard enabled,item === peripheral else{return}
        connectedAt=ProcessInfo.processInfo.systemUptime
        update("已连接蓝牙，正在发现 \(selectedFamily.shortName) 通道…")
        item.discoverServices(Array(Set(selectedFamily.channels.map(\.service))).map(CBUUID.init(string:)))
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect item:CBPeripheral,error:Error?) {disconnected(item,"BMS 连接失败")}
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral item:CBPeripheral,error:Error?) {disconnected(item,"BMS 已断开")}
    private func disconnected(_ item:CBPeripheral,_ reason:String) {
        if disconnecting.remove(item.identifier) != nil {if enabled,peripheral==nil{scheduleReconnect()};return}
        guard item === peripheral else{return}
        clearConnection();guard enabled else{return};update(reason+"，等待重连");scheduleReconnect()
    }
    func peripheral(_ item:CBPeripheral,didDiscoverServices error:Error?) {
        guard enabled,item === peripheral else{return}
        let wanted=selectedFamily.channels.map{CBUUID(string:$0.service)}
        let services=(item.services ?? []).filter{wanted.contains($0.uuid)}
        guard error==nil,!services.isEmpty else{failConnection("未找到所选板型的服务，请核对板型");return}
        links=[];remainingServices=services.count
        for service in services {item.discoverCharacteristics(nil,for:service)}
    }
    func peripheral(_ item:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard enabled,item === peripheral else{return}
        if error==nil {
            for channel in selectedFamily.channels where CBUUID(string:channel.service)==service.uuid {
                let characteristics=service.characteristics ?? []
                let writers=characteristics.filter { c in
                    (channel.write.isEmpty || c.uuid==CBUUID(string:channel.write)) && (c.properties.contains(.write)||c.properties.contains(.writeWithoutResponse))
                }
                let readers=characteristics.filter { c in
                    (channel.notify.isEmpty || c.uuid==CBUUID(string:channel.notify)) && (c.properties.contains(.notify)||c.properties.contains(.indicate))
                }
                for writer in writers {for reader in readers where links.count<24 {
                    if !links.contains(where:{$0.writer === writer && $0.reader === reader}) {links.append(Link(writer:writer,reader:reader))}
                }}
            }
        }
        remainingServices-=1
        if remainingServices==0 {nextChannel()}
    }
    private func nextChannel() {
        guard let item=peripheral,item.state == .connected else{return}
        if let reader,reader.isNotifying {item.setNotifyValue(false,for:reader)}
        linkIndex+=1
        guard links.indices.contains(linkIndex) else{failConnection("所有候选通道均未收到有效 \(selectedFamily.shortName) 数据，请核对板型、登录信息或结束其他 App 连接");return}
        writer=links[linkIndex].writer;reader=links[linkIndex].reader
        sendQueue=[];writePending=false;sample=nil;lastValidAt=nil
        parser=BMSReadOnlyProtocol(family:selectedFamily,password:access?.password,mac:access?.mac)
        channelAt=ProcessInfo.processInfo.systemUptime
        update("正在订阅 \(selectedFamily.shortName) 候选通道 \(linkIndex+1)/\(links.count)…")
        item.setNotifyValue(true,for:links[linkIndex].reader)
    }
    func peripheral(_ item:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?) {
        guard enabled,item === peripheral,characteristic === reader else{return}
        guard error==nil,characteristic.isNotifying else{nextChannel();return}
        update("等待校验有效的 \(selectedFamily.shortName) 实时数据…");poll()
    }
    func peripheral(_ item:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?) {
        guard enabled,item === peripheral,characteristic === reader,error==nil,let data=characteristic.value else{return}
        let now=ProcessInfo.processInfo.systemUptime
        for reading in parser.append(data,now:now) {
            sample=ANTBMSSample(reading:reading,uptime:now);lastValidAt=now;retryDelay=2
            update("\(selectedFamily.shortName) 实时数据已连接")
        }
        poll()
    }
    func peripheral(_ item:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?) {
        guard item === peripheral,characteristic === writer else{return}
        writePending=false
        if error != nil {failConnection("BMS 读取请求发送失败")}else{pumpWrites()}
    }
    func peripheralIsReady(toSendWriteWithoutResponse item:CBPeripheral) {if item === peripheral{pumpWrites()}}
    private func tick() {
        guard enabled else{return}
        let now=ProcessInfo.processInfo.systemUptime
        if parser.halted {
            let message = parser.error ?? "所选板型协议不兼容，请核对配置后重试"
            automaticReconnect = false
            clearConnection(); update(message)
            return
        }
        if selectedFamily == .xiaoha {
            if sample != nil,freshReading==nil {update("小哈广播电量已过期，等待新广播")}
            onChange?();return
        }
        if sample != nil,freshReading==nil{update("BMS 数据已过期，等待恢复")}
        if !sendQueue.isEmpty || writePending {
            if now-queuedAt>8{failConnection("BMS 发送超时");return}
        }
        if let channelAt {
            let firstTimeout=selectedFamily == .yanyang ? 30.0:selectedFamily == .jbd ? 25.0:12.0
            if now-(lastValidAt ?? channelAt)>(lastValidAt == nil ? firstTimeout:12){
                if let error=parser.error{onLog?(error)}
                nextChannel();return
            }
        } else if let connectedAt,now-connectedAt>15{failConnection("BMS 服务发现或连接超时");return}
        poll();onChange?()
    }
    private func poll() {
        guard enabled,let item=peripheral,item.state == .connected,reader?.isNotifying==true,writer != nil,
              sendQueue.isEmpty,!writePending else{return}
        let now=ProcessInfo.processInfo.systemUptime
        guard let frame=parser.nextRequest(now:now) else{return}
        guard BMSReadOnlyProtocol.permits(frame,family:selectedFamily) else{failConnection("已阻止非读取命令");return}
        let type:CBCharacteristicWriteType=writer!.properties.contains(.write) ? .withResponse:.withoutResponse
        let maximum=item.maximumWriteValueLength(for:type)
        guard maximum>0 else{failConnection("BMS 写入长度不可用");return}
        sendQueue=stride(from:0,to:frame.count,by:maximum).map{frame.subdata(in:$0..<min($0+maximum,frame.count))}
        queuedAt=now;pumpWrites()
    }
    private func pumpWrites() {
        guard enabled,let item=peripheral,item.state == .connected,let writer,!writePending else{return}
        let type:CBCharacteristicWriteType=writer.properties.contains(.write) ? .withResponse:.withoutResponse
        while !sendQueue.isEmpty {
            if type == .withoutResponse && !item.canSendWriteWithoutResponse{return}
            let part=sendQueue.removeFirst();writePending=type == .withResponse
            item.writeValue(part,for:writer,type:type)
            if writePending{return}
        }
    }
    private func failConnection(_ message:String){clearConnection();update(message);scheduleReconnect()}
    private func clearConnection() {
        let previous=peripheral
        peripheral=nil;writer=nil;reader=nil;sample=nil;connectedAt=nil;channelAt=nil;lastValidAt=nil
        links=[];linkIndex = -1;remainingServices=0;writePending=false;sendQueue=[];access=nil
        parser=BMSReadOnlyProtocol(family:.ant)
        previous?.delegate=nil
        if let previous,previous.state != .disconnected{disconnecting.insert(previous.identifier);central?.cancelPeripheralConnection(previous)}
    }
    private func scheduleReconnect(){
        guard enabled,automaticReconnect,selectedID != nil,reconnectWork==nil,central?.state == .poweredOn else{return}
        let retry=DispatchWorkItem{[weak self] in guard let self else{return};self.reconnectWork=nil;self.connectRememberedOrScan()}
        reconnectWork=retry;DispatchQueue.main.asyncAfter(deadline:.now()+retryDelay,execute:retry);retryDelay=min(30,retryDelay*2)
    }
    private func update(_ message:String){if message != status{status=message;onLog?(message)};onChange?()}
}
