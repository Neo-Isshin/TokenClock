import XCTest
@testable import TokenClock
final class CacheHashTests: XCTestCase {
    func testIndependentDigestVectorsAndPaddingBoundaries() {
        func hex(_ data:Data)->String{data.map{String(format:"%02x",$0)}.joined()}
        XCTAssertEqual(hex(CacheHash.sha1(Data())),"da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(CacheHash.sha1(Data("abc".utf8))),"a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex(CacheHash.sha256(Data())),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(CacheHash.sha256(Data("abc".utf8))),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(CacheHash.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}
