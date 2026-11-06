import Foundation
#if os(macOS)
import Darwin
#endif

struct DSHUsageReceipt {
    let id:String,session:String,name:String
    let model:String?
    let date:Date
    let buckets:ModelBuckets
}

#if os(macOS)
private final class BundledZstd: @unchecked Sendable {
    static let shared=BundledZstd()
    typealias Create = @convention(c) () -> OpaquePointer?
    typealias InitStream = @convention(c) (OpaquePointer?) -> UInt
    typealias Decode = @convention(c) (OpaquePointer?,UnsafeMutableRawPointer?,UnsafeMutableRawPointer?) -> UInt
    typealias IsError = @convention(c) (UInt) -> UInt32
    let handle:UnsafeMutableRawPointer?
    let create:Create?,initialize:InitStream?,decode:Decode?,free:InitStream?,isError:IsError?
    init(){
        let path=Bundle.module.resourceURL?.appendingPathComponent("DSHDecoder/libzstd.1.dylib").path
        let h=path.flatMap{dlopen($0,RTLD_NOW|RTLD_LOCAL)};handle=h
        func load<T>(_ name:String,_ type:T.Type)->T? {guard let h,let p=dlsym(h,name) else{return nil};return unsafeBitCast(p,to:type)}
        create=load("ZSTD_createDStream",Create.self);initialize=load("ZSTD_initDStream",InitStream.self);decode=load("ZSTD_decompressStream",Decode.self);free=load("ZSTD_freeDStream",InitStream.self);isError=load("ZSTD_isError",IsError.self)
    }
    struct Buffer {var pointer:UnsafeRawPointer?;var size:Int;var pos:Int}
    func read(_ path:String,emit:(Data)->Bool)->Bool {
        guard let file=FileHandle(forReadingAtPath:path) else{return false}
        defer{try? file.close()}
        guard let create,let initialize,let decode,let free,let isError,let stream=create() else{return false}
        defer{_ = free(stream)}
        guard isError(initialize(stream))==0 else{return false}
        var last:UInt=1;var output=[UInt8](repeating:0,count:65536)
        do {
            while let data=try file.read(upToCount:65536),!data.isEmpty {
                var okay=true
                data.withUnsafeBytes { input in
                    var source=Buffer(pointer:input.baseAddress,size:input.count,pos:0)
                    while source.pos<source.size && okay {
                        let previous=source.pos
                        output.withUnsafeMutableBytes { raw in
                            var destination=Buffer(pointer:raw.baseAddress,size:raw.count,pos:0)
                            last=decode(stream,&destination,&source)
                            if isError(last) != 0 {okay=false;return}
                            if destination.pos>0 {okay=emit(Data(raw.prefix(destination.pos)))}
                            if previous==source.pos && destination.pos==0 {okay=false}
                        }
                    }
                }
                if !okay{return false}
            }
        } catch{return false}
        return last==0 // Truncated/unverified frames never replace a good snapshot.
    }
}
#endif

enum DSHReceiptReader {
    static func generation(_ name:String)->Int? {
        let base=name.hasSuffix(".zstd") ? String(name.dropLast(5)):name
        if base=="session.jsonl"{return 0}
        guard base.hasPrefix("session.v"),base.hasSuffix(".jsonl") else{return nil}
        return Int(base.dropFirst(9).dropLast(6))
    }
    static func latest(_ paths:[String])->[String] {
        Dictionary(grouping:paths,by:{URL(fileURLWithPath:$0).deletingLastPathComponent().path}).values.compactMap { files in
            files.max { a,b in
                let av=generation(URL(fileURLWithPath:a).lastPathComponent) ?? -1,bv=generation(URL(fileURLWithPath:b).lastPathComponent) ?? -1
                if av != bv{return av<bv}
                let at=(try? FileManager.default.attributesOfItem(atPath:a)[.modificationDate]) as? Date ?? .distantPast
                let bt=(try? FileManager.default.attributesOfItem(atPath:b)[.modificationDate]) as? Date ?? .distantPast
                return at==bt ? a<b:at<bt
            }
        }.sorted()
    }
    static func count(_ raw:Any?)->Int? {
        guard let n=raw as? NSNumber,!JSONNumber.isBoolean(n),n.doubleValue.isFinite,n.doubleValue>=0,n.doubleValue<=1_000_000_000,n.doubleValue.rounded(.down)==n.doubleValue else{return nil}
        return n.intValue
    }
    static func buckets(_ usage:[String:Any])->ModelBuckets? {
        guard let input=count(usage["inputTokens"]),let output=count(usage["outputTokens"]),
              let read=count(usage["cacheReadTokens"] ?? 0),let write=count(usage["cacheWriteTokens"] ?? 0) else{return nil}
        // DSH explicitly declares these four counters disjoint, including input.
        return ModelBuckets(input:input,output:output,cacheRead:read,cacheWrite:write)
    }
    static func read(_ path:String)->[DSHUsageReceipt]? {
        var session="",title="",header=false,invalid=false,seed=false,seedCount=0
        var slots:[String:DSHUsageReceipt]=[:],attempts:[String:Int]=[:],models:[String:String]=[:]
        func consume(_ line:String) {
            if invalid{return}
            guard let data=line.data(using:.utf8),let row=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let type=row["type"] as? String else{invalid=true;return}
            if !header {
                guard type=="session",let version=count(row["version"]),(0...4).contains(version),let id=row["id"] as? String,!id.isEmpty else{invalid=true;return}
                session=id;title=(row["name"] as? String) ?? id;seed=row["isSeeded"] as? Bool ?? false;seedCount=count(row["seedLength"]) ?? 0;header=true;return
            }
            let payload=row["data"] as? [String:Any] ?? [:]
            guard let seq=count(row["seq"]) else{invalid=true;return}
            if type=="session/end-seed",payload["inherited"] as? Bool==true {seed=false;return}
            if seed || seq<seedCount{return}
            guard let turn=count(payload["turn"]),let step=count(payload["step"]) else{return}
            let group="\(turn):\(step)"
            if type=="llm/retry-started" {attempts[group,default:0]+=1;return}
            if type=="request/header" {
                let h=payload["header"] as? [String:Any] ?? payload
                if let model=h["model"] as? String {models[group]=model};return
            }
            guard ["assistant/message","assistant/attempt"].contains(type) else{return}
            let message=payload["message"] as? [String:Any] ?? [:],source=message["source"] as? [String:Any] ?? [:]
            var usage=payload["usage"] as? [String:Any]
            if usage==nil {
                for record in payload["stream"] as? [[String:Any]] ?? [] where record["type"] as? String=="chunk" {
                    if let chunk=record["chunk"] as? [String:Any],chunk["type"] as? String=="usage",let u=chunk["usage"] as? [String:Any] {usage=u}
                }
            }
            guard let usage else{return}
            guard let values=buckets(usage),let time=row["time"] as? NSNumber,!JSONNumber.isBoolean(time),time.doubleValue.isFinite,time.doubleValue>0 else{invalid=true;return}
            let key=group+":\(attempts[group] ?? 0)"
            slots[key]=DSHUsageReceipt(id:"dsh:\(session):\(key)",session:session,name:title,model:ModelNormalizer.normalize(source["model"] as? String ?? message["model"] as? String ?? models[group]),date:Date(timeIntervalSince1970:time.doubleValue/1000),buckets:values)
        }
        var carry=Data()
        func emit(_ data:Data)->Bool {
            carry.append(data)
            while let end=carry.firstIndex(of:10) {
                if end>16*1024*1024{return false}
                let line=String(decoding:carry.prefix(upTo:end),as:UTF8.self)
#if canImport(ObjectiveC)
                autoreleasepool {if !line.trimmingCharacters(in:.whitespaces).isEmpty {consume(line)}}
#else
                if !line.trimmingCharacters(in:.whitespaces).isEmpty {consume(line)}
#endif
                carry.removeSubrange(...end)
                if invalid{return false}
            }
            return carry.count<=16*1024*1024
        }
        let success:Bool
        if path.hasSuffix(".zstd") {
#if os(macOS)
            success=BundledZstd.shared.read(path,emit:emit)
#else
            success=false
#endif
        } else {
            guard let handle=FileHandle(forReadingAtPath:path) else{return nil};defer{try? handle.close()}
            var okay=true
            do {while let data=try handle.read(upToCount:65536),!data.isEmpty {if !emit(data){okay=false;break}}}catch{okay=false}
            success=okay
        }
        guard success,header,!invalid else{return nil}
        return slots.values.sorted{$0.id<$1.id}
    }
}
