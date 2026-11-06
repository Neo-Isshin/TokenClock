#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

@MainActor final class InstantHintLayoutTests: XCTestCase {
    func testShortHintIncludesTheTextFieldsNativeInsets() {
        let text="Open all Ailyre news in your default browser"
        let label=InstantHintTextLayout.label(for:text,maximumWidth:260)
        XCTAssertEqual(label.stringValue,text)
        XCTAssertGreaterThanOrEqual(label.frame.width,ceil(label.cell!.cellSize.width))
        XCTAssertGreaterThanOrEqual(label.frame.height,label.cell!.cellSize(forBounds:label.bounds).height)
    }
    func testLongEnglishChineseAndExplicitLinesHaveEnoughHeightAtNarrowWidths() {
        for width:CGFloat in [140,180,260] {
            for text in [String(repeating:"Keep all tooltip words visible without cutting off the ending. ",count:4),String(repeating:"完整展示中文提示，换行后的文字也不能被裁掉。",count:4),"First line\nSecond line\nFinal line"] {
                let label=InstantHintTextLayout.label(for:text,maximumWidth:width)
                let measured=label.cell!.cellSize(forBounds:NSRect(x:0,y:0,width:label.frame.width,height:100_000))
                XCTAssertLessThanOrEqual(label.frame.width,width)
                XCTAssertGreaterThanOrEqual(label.frame.height,ceil(measured.height))
                XCTAssertGreaterThan(label.frame.height,28)
                XCTAssertEqual(label.maximumNumberOfLines,0)
            }
        }
    }
}
#endif
