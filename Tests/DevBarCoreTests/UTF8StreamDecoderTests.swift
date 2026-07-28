import Foundation
import XCTest
@testable import DevBarCore

final class UTF8StreamDecoderTests: XCTestCase {
    func testPreservesIncompleteChineseScalarUntilItsRemainingBytesArrive() {
        var decoder = UTF8StreamDecoder()

        XCTAssertEqual(decoder.append(Data([0xE4, 0xB8])), "")
        XCTAssertEqual(decoder.append(Data([0xAD, 0x21])), "中!")
        XCTAssertEqual(decoder.finish(), "")
    }

    func testInvalidBytesBecomeReplacementCharactersWithoutDroppingAdjacentBytes() {
        var decoder = UTF8StreamDecoder()

        XCTAssertEqual(decoder.append(Data([0x41, 0xC3, 0x28, 0x42])), "A�(B")
        XCTAssertEqual(decoder.append(Data([0xE4])), "")
        XCTAssertEqual(decoder.finish(), "�")
    }
}
