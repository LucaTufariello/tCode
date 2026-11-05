import Foundation
import XCTest

@testable import TCodeCore

final class LineIndexTests: XCTestCase {
  func testLineStartsForLineEndings() {
    XCTAssertEqual(LineIndex(text: "one\ntwo\nthree").starts, [0, 4, 8])
    XCTAssertEqual(LineIndex(text: "one\r\ntwo\r\nthree").starts, [0, 5, 10])
    XCTAssertEqual(LineIndex(text: "one\rtwo\rthree").starts, [0, 4, 8])
    XCTAssertEqual(LineIndex(text: "").starts, [0])
    XCTAssertEqual(LineIndex(text: "one\n").starts, [0, 4])
  }

  func testPositionMatchesPositionMap() {
    let samples = [
      "one\ntwo\nthree",
      "one\r\ntwo\r\nthree",
      "one\rtwo\rthree",
      "a👩🏽‍💻e\u{301}\n第二行\n",
      "let value = 42\nprint(value)\n",
    ]
    for text in samples {
      let index = LineIndex(text: text)
      let ns = text as NSString
      for offset in 0...ns.length {
        let expected = PositionMap.position(in: text, utf16Offset: offset)
        let actual = index.position(in: text, utf16Offset: offset)
        XCTAssertEqual(actual, expected, "offset \(offset) in \(text.debugDescription)")
      }
    }
  }

  func testOffsetRoundTripsForEncodings() {
    let text = "a👩🏽‍💻e\u{301}\n第二行\n"
    let index = LineIndex(text: text)
    let ns = text as NSString
    for encoding in ["utf-16", "utf-8", "utf-32"] {
      var offsets: [Int] = []
      if encoding == "utf-16" {
        offsets = Array(0...ns.length)
      } else {
        var offset = 0
        for scalar in text.unicodeScalars {
          offsets.append(offset)
          offset += scalar.utf16.count
        }
        offsets.append(ns.length)
      }
      for offset in offsets {
        let position = index.position(in: text, utf16Offset: offset, encoding: encoding)
        XCTAssertEqual(
          index.offset(in: text, position: position, encoding: encoding), offset,
          "\(encoding) offset \(offset)")
      }
    }
  }

  func testApplyEditMatchesFreshIndex() {
    var text = "one\ntwo\nthree"
    var index = LineIndex(text: text)

    func replace(_ range: NSRange, with replacement: String) {
      let mutable = NSMutableString(string: text)
      let oldLength = mutable.length
      mutable.replaceCharacters(in: range, with: replacement)
      let delta = mutable.length - oldLength
      let editedRange = NSRange(location: range.location, length: replacement.utf16.count)
      index.applyEdit(text: mutable, editedRange: editedRange, delta: delta)
      text = mutable as String
      XCTAssertEqual(
        index.starts, LineIndex(text: text).starts,
        "edit \(range) -> \(replacement.debugDescription) in \(text.debugDescription)")
    }

    replace(NSRange(location: 3, length: 0), with: "X")
    replace(NSRange(location: 4, length: 0), with: "\n")
    replace(NSRange(location: 5, length: 1), with: "")
    replace(NSRange(location: 0, length: 0), with: "start\n")
    replace(NSRange(location: (text as NSString).length, length: 0), with: "\nend")
    replace(NSRange(location: 0, length: 2), with: "A\r\nB")
    replace(NSRange(location: 0, length: (text as NSString).length), with: "fresh\nindex\r\n")
    replace(NSRange(location: 0, length: (text as NSString).length), with: "")
    replace(NSRange(location: 0, length: 0), with: "👩🏽‍💻\n第二行\n")
  }

  func testApplyEditCRLFAndWholeLineDeletion() {
    var text = "a\r\nline\r\nb\r\n"
    var index = LineIndex(text: text)

    func replace(_ range: NSRange, with replacement: String) {
      let mutable = NSMutableString(string: text)
      let oldLength = mutable.length
      mutable.replaceCharacters(in: range, with: replacement)
      let delta = mutable.length - oldLength
      let editedRange = NSRange(location: range.location, length: replacement.utf16.count)
      index.applyEdit(text: mutable, editedRange: editedRange, delta: delta)
      text = mutable as String
      XCTAssertEqual(index.starts, LineIndex(text: text).starts)
    }

    // Delete "line\r\n" while keeping the following line start.
    replace(NSRange(location: 3, length: 6), with: "")
    // Delete the CRLF between "a" and "b".
    replace(NSRange(location: 1, length: 2), with: "")
    // Insert a CRLF in the middle of a line.
    replace(NSRange(location: 1, length: 0), with: "\r\n")
  }
}
