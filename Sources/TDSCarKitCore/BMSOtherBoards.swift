// Read-only Swift adaptation of maibms YadiProtocol, MingtangProtocol and LanBaoProtocol (MIT).
import Foundation

extension BMSReadOnlyProtocol {
    func drainYadi(_ now:Double)->[ANTBMSReading] {
        guard pending != nil else { buffer.removeAll();return [] }
        guard let last=buffer.last, (48...57).contains(last)||(65...70).contains(last)||(97...102).contains(last) else { buffer.removeAll();return [] }
        guard buffer.count>=4 else { return [] }
        guard String(decoding:buffer.prefix(4),as:UTF8.self).uppercased()=="F403" else { buffer.removeFirst();return [] }
        guard buffer.count>=6,let header=Self.hex(String(decoding:buffer.prefix(6),as:UTF8.self)) else { return [] }
        let count=Int(header[2]),length=(count+5)*2
        guard buffer.count>=length else { return [] }
        guard let frame=Self.hex(String(decoding:buffer.prefix(length),as:UTF8.self)) else { buffer.removeFirst();return [] }
        buffer.removeFirst(length)
        guard Self.withCRC(Array(frame.dropLast(2)))==frame else {
            pending=nil;step=0;page=[UInt8](repeating:0,count:124);buffer.removeAll();drainUntil=now+3;error="亚迪 CRC 错误，本页作废";return []
        }
        guard count==[60,59,5][step] else { return [] }
        let offset=[0,60,119][step]
        page.replaceSubrange(offset..<offset+count,with:frame[3..<3+count])
        complete(now:now);step+=1;buffer.removeAll()
        guard step==3 else { return [] }
        step=0
        let d=BMSBytes(page),cells=d.u8(63),voltage=Double(d.le16(20))/100
        guard (1...24).contains(cells),voltage>0,voltage<=200 else { return [] }
        values=BMSValues();values.voltage=voltage
        values.soc=d.le16(48)<=1000 ? Int((Double(d.le16(48))/10).rounded()):nil
        values.cells=(0..<cells).map { i in
            let raw=d.le16(68+i*2);return (1...6000).contains(raw) ? Double(raw)/1000:nil
        }
        values.details=["协议":"YADI-F403（待真机验证）","循环次数":String(d.le16(60))]
        values.details["原始容量寄存器"]=d.b[52..<60].map { String(format:"%02X",$0) }.joined()
        return [values.reading(.yadi)]
    }

    func drainMingtang(_ now:Double)->[ANTBMSReading] {
        guard !buffer.isEmpty else { return [] }
        guard buffer[0]==0xe1 else { buffer.removeFirst();return [] }
        guard buffer.count>=6 else { return [] }
        guard buffer[1]==0x11,buffer[2]==0 else { buffer.removeFirst();return [] }
        let tail=BMSBytes(buffer).be16(4)
        guard tail>=6,tail<4096 else { buffer.removeFirst();return [] }
        guard buffer.count>=tail+1 else { return [] }
        let frame=Array(buffer.prefix(tail+1));buffer.removeFirst(tail+1)
        let d=BMSBytes(frame);var fields:[Int:[UInt8]]=[:];var cursor=6
        while cursor<tail {
            guard cursor+3<=tail else { return [] }
            let tag=d.be16(cursor),count=d.u8(cursor+2);cursor+=3
            guard cursor+count<=tail,fields[tag]==nil else { return [] }
            fields[tag]=Array(frame[cursor..<cursor+count]);cursor+=count
        }
        func valid(_ tag:Int,_ length:Int)->Bool {
            switch tag {
            case 3:return length==1 || length==2
            case 4:return length>=2 && length<=128 && length%2==0
            case 5,6,7,10,27...31:return length==2
            case 13,15,25,36,37:return length==4
            case 17,19,21,24,38:return length==1
            case 26:return length>0
            default:return true
            }
        }
        guard fields.allSatisfy({valid($0.key,$0.value.count)}),let v=fields[10],let soc=fields[38],soc[0]<=100 else { return [] }
        let voltage=Double(BMSBytes(v).be16(0))/100
        guard voltage>0,voltage<=384 else { return [] }
        var reading=BMSValues();reading.voltage=voltage;reading.soc=Int(soc[0])
        if let cells=fields[4] {
            let b=BMSBytes(cells)
            guard stride(from:0,to:cells.count,by:2).allSatisfy({b.be16($0)<=6000||b.be16($0)==0xffff}) else { return [] }
            reading.cells=stride(from:0,to:cells.count,by:2).map { i in
                let raw=b.be16(i);return raw>0&&raw<=6000 ? Double(raw)/1000:nil
            }
        }
        if let count=fields[3] {
            let slots=count.count==1 ? Int(count[0]):BMSBytes(count).be16(0)
            guard (1...64).contains(slots) else { return [] }
            if slots>reading.cells.count { reading.cells += [Double?](repeating:nil,count:slots-reading.cells.count) }
        }
        for tag in [13,15] {
            if let b=fields[tag],abs(BMSBytes(b).bi32(0))>10_000_000 { return [] }
        }
        if let charge=fields[13],let discharge=fields[15] {
            reading.current=Double(BMSBytes(discharge).bi32(0)-BMSBytes(charge).bi32(0))/1000
        }
        for tag in 27...31 {
            if let b=fields[tag] {
                let raw=BMSBytes(b).bi16(0)
                if raw == -27300 || raw == 30000 { continue }
                guard (-10000...20000).contains(raw) else { return [] }
                if tag==27 { reading.mos=Double(raw)/100 } else { reading.temperatures.append(Double(raw)/100) }
            }
        }
        for tag in [36,37] {
            if let b=fields[tag] {
                let raw=BMSBytes(b).bi32(0)
                guard (0...10_000_000).contains(raw),tag != 36 || raw>0 else { return [] }
                if tag==36 { reading.capacity=Double(raw)/1000 } else { reading.remaining=Double(raw)/1000 }
            }
        }
        guard reading.current != nil || reading.capacity != nil || reading.remaining != nil || reading.mos != nil || !reading.temperatures.isEmpty || reading.cells.contains(where:{$0 != nil}) else { return [] }
        reading.details=["协议":"明唐 E1 TLV（总压倍率待实物确认）","帧校验":"结构与字段边界检查；协议无已确认 CRC"]
        for tag in [17,19,21,26] {
            if let raw=fields[tag] { reading.details["原始字段 \(tag)"]=raw.map{String(format:"%02X",$0)}.joined() }
        }
        if let balance=fields[24] { guard balance[0]<=1 else {return []};reading.details["均衡"]=balance[0]==1 ? "开":"关" }
        values=reading;complete(now:now);nextAt=now+0.5
        return [reading.reading(.mingtang)]
    }

    func drainLanbao(_ now:Double)->[ANTBMSReading] {
        guard !buffer.isEmpty else { return [] }
        guard buffer[0]==0xfa else { buffer.removeFirst();return [] }
        guard buffer.count>=5 else { return [] }
        guard buffer[1]==0x50,buffer[4]==0x15 else { buffer.removeFirst();return [] }
        guard buffer.count>=130 else { return [] }
        let candidates=[130,153].filter { size in
            guard buffer.count>=size else { return false }
            let frame=Array(buffer.prefix(size))
            return frame.last==0xe5 && Self.withCRC(Array(frame.dropLast(3)),polynomial:0xc328,bigEndian:true)+[0xe5]==frame
        }
        guard let size=candidates.first else {
            if buffer.count>=153 {buffer.removeFirst();error="蓝宝 CRC 校验失败"};return []
        }
        let frame=Array(buffer.prefix(size));buffer.removeFirst(size)
        guard pending != nil else { return [] }
        let d=BMSBytes(Array(frame[16..<(size-3)]))
        complete(now:now);step+=1
        if size==153 {
            let cap=Double(d.be32(48))/1000
            values.capacity=cap>0 ? cap:nil;auxiliaryAt=now
            values.details["序列号"]=d.text(0,16);values.details["硬件版本"]=d.text(16,8);values.details["软件版本"]=d.text(24,8)
            values.details["串数"]=String(d.u8(47));values.details["循环次数"]=String(d.be16(57))
            return []
        }
        let voltage=Double(d.be16(0))/100,soc=d.be16(6)/10
        guard voltage>0,voltage<=650,soc<=100 else { return [] }
        values.voltage=voltage;values.current=Double(d.bi32(2))/100;values.soc=soc
        values.power=d.bi32(19);values.remaining=Double(d.be32(15))/100000
        values.temperatures=[Double(Int(Int8(bitPattern:d.b[14])))];values.cells=[]
        values.delta=Double(d.be16(86))/1000
        values.state=abs(values.current!)<0.3 ? 1:values.current!>0 ? 2:4 // meter retains factory signs
        values.details["中继品牌"]=[1:"ANT",2:"彦阳",3:"极空",4:"JBD"][d.u8(50)] ?? "未知"
        values.details["中继名称"]=d.text(57,25)
        values.details["最高单体"]=String(format:"%.3f V",Double(d.be16(82))/1000)
        values.details["最低单体"]=String(format:"%.3f V",Double(d.be16(84))/1000)
        values.details["协议"]="蓝宝 FA50 双表"
        if now-auxiliaryAt>15 {values.capacity=nil}
        return [values.reading(.lanbao)]
    }
}
