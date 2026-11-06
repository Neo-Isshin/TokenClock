import Foundation

/// Digests of public Chromium cache keys and entry checksums. No credential storage.
enum CacheHash {
    private static func bytes(_ data: Data) -> [UInt8] {
        var message = Array(data); let length = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message += (0..<8).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) }
        return message
    }
    private static func output(_ words: [UInt32]) -> Data {
        Data(words.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
    }
    private static func rotateLeft(_ value: UInt32, _ shift: UInt32) -> UInt32 { (value << shift) | (value >> (32-shift)) }
    private static func rotateRight(_ value: UInt32, _ shift: UInt32) -> UInt32 { (value >> shift) | (value << (32-shift)) }
    static func sha1(_ data: Data) -> Data {
        let message=bytes(data);var state:[UInt32]=[0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0]
        for start in stride(from:0,to:message.count,by:64) {
            var w=[UInt32](repeating:0,count:80)
            for i in 0..<16 { for j in 0..<4 { w[i]=(w[i]<<8)|UInt32(message[start+i*4+j]) } }
            for i in 16..<80 { w[i]=rotateLeft(w[i-3]^w[i-8]^w[i-14]^w[i-16],1) }
            var a=state[0],b=state[1],c=state[2],d=state[3],e=state[4]
            for i in 0..<80 {
                let f:UInt32,k:UInt32
                switch i {case 0..<20:f=(b&c)|((~b)&d);k=0x5a827999;case 20..<40:f=b^c^d;k=0x6ed9eba1;case 40..<60:f=(b&c)|(b&d)|(c&d);k=0x8f1bbcdc;default:f=b^c^d;k=0xca62c1d6}
                let t=rotateLeft(a,5)&+f&+e&+k&+w[i];e=d;d=c;c=rotateLeft(b,30);b=a;a=t
            }
            for (i,v) in [a,b,c,d,e].enumerated(){state[i]=state[i]&+v}
        }
        return output(state)
    }
    private static let constants:[UInt32]=[
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    static func sha256(_ data: Data) -> Data {
        let message=bytes(data);var state:[UInt32]=[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        for start in stride(from:0,to:message.count,by:64) {
            var w=[UInt32](repeating:0,count:64)
            for i in 0..<16 { for j in 0..<4 { w[i]=(w[i]<<8)|UInt32(message[start+i*4+j]) } }
            for i in 16..<64 {
                let s0=rotateRight(w[i-15],7)^rotateRight(w[i-15],18)^(w[i-15]>>3)
                let s1=rotateRight(w[i-2],17)^rotateRight(w[i-2],19)^(w[i-2]>>10)
                w[i]=w[i-16]&+s0&+w[i-7]&+s1
            }
            var a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7]
            for i in 0..<64 {
                let s1=rotateRight(e,6)^rotateRight(e,11)^rotateRight(e,25),ch=(e&f)^((~e)&g)
                let t1=h&+s1&+ch&+constants[i]&+w[i]
                let s0=rotateRight(a,2)^rotateRight(a,13)^rotateRight(a,22),maj=(a&b)^(a&c)^(b&c),t2=s0&+maj
                h=g;g=f;f=e;e=d&+t1;d=c;c=b;b=a;a=t1&+t2
            }
            for (i,v) in [a,b,c,d,e,f,g,h].enumerated(){state[i]=state[i]&+v}
        }
        return output(state)
    }
}
