#if os(macOS)
import Foundation
import Network

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
    private final class Probe: @unchecked Sendable {
        let lock=NSLock();var finished=false;var connection:NWConnection?;var continuation:CheckedContinuation<LocalFinding,Never>?
        func finish(_ value: LocalFinding) { lock.lock();guard !finished else {lock.unlock();return};finished=true;let c=continuation;continuation=nil;let conn=connection;connection=nil;lock.unlock();conn?.stateUpdateHandler=nil;conn?.cancel();c?.resume(returning:value) }
    }
    static func check() async -> LocalFinding {
        let probe=Probe()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe.lock.lock();if probe.finished {probe.lock.unlock();continuation.resume(returning:.init(title:"已取消",detail:""));return};probe.continuation=continuation;probe.lock.unlock()
                let connection=NWConnection(host:"time.cloudflare.com",port:123,using:.udp);probe.lock.lock();if probe.finished {probe.lock.unlock();connection.cancel();return};probe.connection=connection;probe.lock.unlock()
                let queue=DispatchQueue(label:"TokenClock.NTP")
                connection.stateUpdateHandler = { [weak connection] state in
                    guard let connection else { return }
                    if case .ready = state {
                        let sent=Date();let request=packet(at:sent)
                        connection.send(content:request,completion:.contentProcessed { error in
                            if error != nil {probe.finish(.init(title:"NTP 未完成",detail:"请求失败，未更改系统时钟"));return}
                            connection.receiveMessage { data,_,_,_ in
                                let received=Date()
                                if let data,let value=offset(reply:data,request:request,sent:sent,received:received) {
                                    probe.finish(.init(title:String(format:"时钟偏差 %+.3f 秒",value),detail:String(format:"NTP · time.cloudflare.com · RTT %.0f ms · 仅检测，不校时",received.timeIntervalSince(sent)*1000)))
                                } else {probe.finish(.init(title:"NTP 未完成",detail:"回包不可验证，不能据此判断时钟异常"))}
                            }
                        })
                    } else if case .failed = state {probe.finish(.init(title:"NTP 不可达",detail:"UDP 可能被阻止，未更改系统时钟"))}
                }
                connection.start(queue:queue)
                queue.asyncAfter(deadline:.now()+4) {probe.finish(.init(title:"NTP 超时",detail:"未获取到可信回包，未更改系统时钟"))}
            }
        } onCancel: {probe.finish(.init(title:"已取消",detail:""))}
    }
}
#endif
