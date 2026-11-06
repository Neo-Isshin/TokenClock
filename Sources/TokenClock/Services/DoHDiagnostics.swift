import Foundation

/// Minimal bounded DNS wire codec. Responses must echo our question, not merely
/// return HTTP 200. Only the Cloudflare CHAOS whoami answer is a client-IP echo;
/// ordinary resolver/EDNS-subnet answers are never treated as the client address.
enum DoHWire {
    static func query(_ name: String, type: UInt16 = 1, qclass: UInt16 = 1) -> Data {
        var bytes: [UInt8] = [0,0,1,0,0,1,0,0,0,0,0,0]
        for label in name.split(separator:".") {bytes.append(UInt8(label.utf8.count));bytes += label.utf8}
        bytes += [0,UInt8(type>>8),UInt8(type&255),UInt8(qclass>>8),UInt8(qclass&255)]
        return Data(bytes)
    }
    private static func u16(_ bytes: [UInt8], _ at: Int) -> Int? {
        guard at >= 0,at+2<=bytes.count else{return nil};return Int(bytes[at])*256+Int(bytes[at+1])
    }
    private static func name(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        var pos=offset,labels:[String]=[],visited=Set<Int>(),end:Int?
        for _ in 0..<128 {
            guard pos<bytes.count,visited.insert(pos).inserted else{return nil}
            let n=Int(bytes[pos]);pos+=1
            if n==0 {offset=end ?? pos;return labels.joined(separator:".").lowercased()}
            if n&192==192 {
                guard pos<bytes.count else{return nil};let pointer=(n&63)*256+Int(bytes[pos]);end=end ?? pos+1;pos=pointer;continue
            }
            guard n<=63,pos+n<=bytes.count,labels.joined().count+n<255,
                  let label=String(bytes:bytes[pos..<pos+n],encoding:.ascii) else{return nil}
            labels.append(label);pos+=n
        }
        return nil
    }
    static func response(_ data: Data, question: String, type: UInt16 = 1, qclass: UInt16 = 1) -> (rcode:Int, addresses:[String])? {
        let bytes=[UInt8](data)
        guard (12...16384).contains(bytes.count),u16(bytes,0)==0,let flags=u16(bytes,2),flags&0x8000 != 0,
              flags&0x7A00==0,u16(bytes,4)==1,let count=u16(bytes,6),count<=64 else{return nil}
        var pos=12
        guard name(bytes,&pos)==question.lowercased(),u16(bytes,pos)==Int(type),u16(bytes,pos+2)==Int(qclass) else{return nil}
        pos+=4;var addresses:[String]=[]
        for _ in 0..<count {
            guard let owner=name(bytes,&pos),let kind=u16(bytes,pos),let cls=u16(bytes,pos+2),let length=u16(bytes,pos+8),pos+10+length<=bytes.count else{return nil}
            pos+=10;let end=pos+length
            if owner==question.lowercased(),kind==16,cls==Int(qclass) {
                var text=""
                while pos<end {let n=Int(bytes[pos]);pos+=1;guard pos+n<=end else{return nil};text+=String(decoding:bytes[pos..<pos+n],as:UTF8.self);pos+=n}
                if let address=NetworkDiagnosticParser.address(text) {addresses.append(address)}
            }
            pos=end
        }
        return (flags&15,addresses)
    }
}

enum BrowserDoHConfiguration {
    static func values(_ data: [String:Any]) -> (String,String?)? {
        let nested=data["dns_over_https"] as? [String:Any] ?? [:]
        let mode=(data["DnsOverHttpsMode"] ?? data["dns_over_https.mode"] ?? nested["mode"]) as? String
        let template=(data["DnsOverHttpsTemplates"] ?? data["dns_over_https.templates"] ?? nested["templates"]) as? String
        guard mode != nil || template != nil else{return nil}
        // Only show endpoint hosts: templates may embed private account IDs.
        let hosts=template?.split(separator:" ").compactMap { URL(string:String($0).replacingOccurrences(of:"{?dns}",with:""))?.host }.joined(separator:", ")
        return (mode ?? "未标明模式",hosts)
    }
    static func read(home: String = NSHomeDirectory()) -> [NetworkDiagnosticRow] {
        var rows:[NetworkDiagnosticRow]=[]
        #if os(Windows)
        let base=ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? home+"/AppData/Local"
        let browsers=[("Chrome",base+"/Google/Chrome/User Data"),("Edge",base+"/Microsoft/Edge/User Data"),("Brave",base+"/BraveSoftware/Brave-Browser/User Data")]
        #else
        let base=ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? home+"/.config"
        let browsers=[("Chrome",base+"/google-chrome"),("Chromium",base+"/chromium"),("Edge",base+"/microsoft-edge"),("Brave",base+"/BraveSoftware/Brave-Browser")]
        #endif
        for (browser,folder) in browsers {
            let root=URL(fileURLWithPath:folder)
            let profiles=((try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? []).filter{$0=="Default" || $0.hasPrefix("Profile ")}.prefix(6)
            let files=[root.appendingPathComponent("Local State")]+profiles.map{root.appendingPathComponent($0+"/Preferences")}
            for file in files {
                guard let size=try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=4*1024*1024,
                      let body=try? Data(contentsOf:file),let object=try? JSONSerialization.jsonObject(with:body) as? [String:Any],let value=values(object) else{continue}
                rows.append(.init(id:"doh-config-\(rows.count)",category:"dohConfig",label:browser+" · "+file.deletingLastPathComponent().lastPathComponent,
                    host:value.1 ?? "",state:"configured",note:value.0+" · 配置快照，非当前连接证明"))
            }
        }
        #if os(Windows)
        let firefox=URL(fileURLWithPath:(ProcessInfo.processInfo.environment["APPDATA"] ?? home+"/AppData/Roaming")+"/Mozilla/Firefox/Profiles")
        #else
        let firefox=URL(fileURLWithPath:home+"/.mozilla/firefox")
        #endif
        for profile in ((try? FileManager.default.contentsOfDirectory(atPath:firefox.path)) ?? []).prefix(6) {
            let path=firefox.appendingPathComponent(profile+"/prefs.js")
            guard let size=try? path.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<2*1024*1024,let text=try? String(contentsOf:path,encoding:.utf8) else{continue}
            let regex=try! NSRegularExpression(pattern:#"user_pref\("network\.trr\.(mode|uri|custom_uri)",\s*(\d+|"(?:[^"\\]|\\.)*")\s*\)"#)
            let ns=text as NSString;var mode:String?,host:String?
            for match in regex.matches(in:text,range:NSRange(location:0,length:ns.length)) {
                let key=ns.substring(with:match.range(at:1)),raw=ns.substring(with:match.range(at:2))
                if key=="mode" {mode=["2":"优先 DoH / 可回退","3":"仅 DoH","5":"显式关闭","0":"默认/策略决定"][raw] ?? "模式 "+raw}
                else if let data=("["+raw+"]").data(using:.utf8),let array=try? JSONSerialization.jsonObject(with:data) as? [String] {host=array.first.flatMap{URL(string:$0)?.host}}
            }
            if mode != nil || host != nil {rows.append(.init(id:"doh-config-firefox-\(rows.count)",category:"dohConfig",label:"Firefox",host:host ?? "",state:"configured",note:(mode ?? "未标明模式")+" · 配置快照"))}
        }
        if rows.isEmpty {rows.append(.init(id:"doh-config-unknown",category:"dohConfig",label:"浏览器 / 系统",host:"",state:"unknown",note:"未发现显式浏览器设置；默认策略、系统/VPN 加密 DNS 未确认"))}
        return Array(rows.prefix(8))
    }
}

enum DoHDiagnostics {
    static func request(_ endpoint:String, name:String, type:UInt16=1, qclass:UInt16=1)->ProviderHTTPRequest {
        var request=ProviderHTTPRequest(url:URL(string:endpoint)!);request.httpMethod="POST";request.timeoutInterval=3
        request.setValue("application/dns-message",forHTTPHeaderField:"Accept");request.setValue("application/dns-message",forHTTPHeaderField:"Content-Type")
        request.httpBody=DoHWire.query(name,type:type,qclass:qclass);return request
    }
    static func verified(_ reply:NetworkDiagnosticReply,name:String,type:UInt16=1,qclass:UInt16=1)->Bool {
        guard reply.status==200,!reply.limited,reply.mime?.lowercased()=="application/dns-message",let packet=DoHWire.response(reply.data,question:name,type:type,qclass:qclass) else{return false}
        return [0,3].contains(packet.rcode)
    }
    static func run(token:String?,baseline:String?,fetcher:NetworkDiagnosticFetcher) async -> [NetworkDiagnosticRow] {
        guard let token,token.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil else{return [.init(id:"doh-unavailable",category:"doh",label:"DoH",host:"",state:"unknown",note:toolboxText("请在 Ailyre 完整浏览器检测页查看 DNS / DoH 结果；本机客户端未取得此项的可验证记录。","Review DNS / DoH on Ailyre’s full browser check page; this native client has no verifiable browser result.")) ]}
        async let configs=Task.detached {BrowserDoHConfiguration.read()}.value
        var rows=await withTaskGroup(of:NetworkDiagnosticRow.self) {group in
            for (index,label,endpoint) in [(0,"Cloudflare","https://cloudflare-dns.com/dns-query"),(1,"Google","https://dns.google/dns-query")] {
                group.addTask {
                    let name="d\(index).\(token).probe.tokenclock.ailyre.com"
                    let reply=await fetcher.fetch(request(endpoint,name:name))
                    return NetworkDiagnosticRow(id:"doh-\(index)",category:"doh",label:label,host:URL(string:endpoint)!.host!,state:verified(reply,name:name) ? "verified":"unavailable",httpStatus:reply.status,
                        note:verified(reply,name:name) ? "DoH DNS 响应已验证":"未取得可验证 DoH 响应",proxy:reply.proxy)
                }
            }
            var result:[NetworkDiagnosticRow]=[];for await row in group {result.append(row)};return result
        }
        if !Task.isCancelled {
            // This endpoint's CHAOS response echoes the client IP of this exact
            // DoH request. Google's resolver IP / ECS subnet is not an equivalent.
            let echo=await fetcher.fetch(request("https://cloudflare-dns.com/dns-query",name:"whoami.cloudflare",type:16,qclass:3))
            var row=NetworkDiagnosticRow(id:"doh-client",category:"dohEcho",label:"Cloudflare DoH 出口",host:"cloudflare-dns.com",state:"unknown",note:"没有精确客户端 IP 证据",proxy:echo.proxy)
            if verified(echo,name:"whoami.cloudflare",type:16,qclass:3),let ip=DoHWire.response(echo.data,question:"whoami.cloudflare",type:16,qclass:3)?.addresses.first {
                row.ip=ip;row.state="observed";row.note="本次 DoH 请求返回的客户端 IP"
            }
            rows.append(row)
            var authorityRequest=ProviderHTTPRequest(url:URL(string:"https://www.ailyre.com/tokenclock/network-check/result/"+token)!);authorityRequest.timeoutInterval=3
            let result=await fetcher.fetch(authorityRequest)
            if result.status==200,let map=NetworkDiagnosticParser.json(result.data)?["dohResolvers"] as? [String:[String]] {
                for i in rows.indices where rows[i].category=="doh" {
                    let name=rows[i].id=="doh-0" ? "d0":"d1"
                    let sources=(map[name] ?? []).compactMap(NetworkDiagnosticParser.address)
                    if rows[i].state=="verified",!sources.isEmpty {rows[i].note="DoH 与权威端查询已双向核验 · "+sources.joined(separator:", ")}
                    else if rows[i].state=="verified" {rows[i].note="DoH 响应有效；未观测到独立权威记录"}
                }
            }
        }
        rows += await configs
        return rows
    }
}
