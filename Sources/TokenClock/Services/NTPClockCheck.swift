import Foundation
#if os(Windows)
import Win32Shim
#else
import CGtk
#endif

enum NTPClockCheck {
    static func packet(at date: Date) -> Data {
        var bytes = Data(repeating: 0, count: 48); bytes[0] = 0x23
        let time = date.timeIntervalSince1970 + 2208988800
        let seconds = UInt32(time); let fraction = UInt32((time-floor(time))*4294967296)
        for (offset,value) in [(40,seconds),(44,fraction)] { for i in 0..<4 { bytes[offset+i] = UInt8((value >> (24-i*8)) & 255) } }
        return bytes
    }
    static func offset(reply: Data, request: Data, sent: Date, received: Date) -> Double? {
        guard reply.count >= 48, request.count == 48, reply[0]&7 == 4, reply[0]>>6 != 3,
              (1...15).contains(reply[1]), reply[24..<32] == request[40..<48], received.timeIntervalSince(sent) < 5 else { return nil }
        func timestamp(_ at: Int) -> Double {
            let seconds = (0..<4).reduce(UInt32(0)) { ($0<<8)|UInt32(reply[at+$1]) }
            let fraction = (0..<4).reduce(UInt32(0)) { ($0<<8)|UInt32(reply[at+4+$1]) }
            return Double(seconds)-2208988800+Double(fraction)/4294967296
        }
        let t2=timestamp(32),t3=timestamp(40)
        guard t3>=t2, t3-t2<5, abs(t3-received.timeIntervalSince1970)<86400*365 else { return nil }
        return ((t2-sent.timeIntervalSince1970)+(t3-received.timeIntervalSince1970))/2
    }
    static func check() async -> LocalFinding {
        let result = await Task.detached(priority:.utility) { () -> LocalFinding in
            let sent=Date();let request=packet(at:sent);var output=[UInt8](repeating:0,count:512),count:Int32=0
            let status=request.withUnsafeBytes { bytes in
                #if os(Windows)
                return win_ntp_exchange(bytes.bindMemory(to:UInt8.self).baseAddress,48,&output,512,&count)
                #else
                return tc_native_ntp_exchange(bytes.bindMemory(to:UInt8.self).baseAddress,48,&output,512,&count)
                #endif
            }
            let received=Date()
            guard status != 0, count >= 48,
                  let value=offset(reply:Data(output.prefix(Int(count))),request:request,sent:sent,received:received) else {
                return .init(title:toolboxText("NTP 未完成","NTP unavailable"),detail:toolboxText("未获得可核对的回包，未更改系统时钟","No verifiable reply; the system clock was not changed"))
            }
            return .init(title:String(format:toolboxText("时钟偏差 %+.3f 秒","Clock offset %+.3f seconds"),value),detail:String(format:toolboxText("NTP · time.cloudflare.com · RTT %.0f ms · 仅检测，不校时","NTP · time.cloudflare.com · RTT %.0f ms · check only, clock unchanged"),received.timeIntervalSince(sent)*1000))
        }.value
        return Task.isCancelled ? .init(title:toolboxText("已取消","Cancelled"),detail:"") : result
    }
}
