import Foundation

public struct Position: Codable, Equatable, Sendable {
  public var line: Int
  public var character: Int
  public init(line: Int, character: Int) {
    self.line = line
    self.character = character
  }
  public var json: [String: Any] { ["line": line, "character": character] }
}
public enum PositionMap {
  // LSP columns count code units, never graphemes. NSTextView ranges are UTF-16.
  public static func position(in text: String, utf16Offset: Int, encoding: String = "utf-16")
    -> Position
  {
    let ns = text as NSString
    let offset = min(max(0, utf16Offset), ns.length)
    let prefix = ns.substring(to: offset)
    let lines = prefix.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n"
    ).components(separatedBy: "\n")
    let last = lines.last ?? ""
    return Position(
      line: lines.count - 1,
      character: encoding == "utf-8"
        ? last.utf8.count : encoding == "utf-32" ? last.unicodeScalars.count : last.utf16.count)
  }
  public static func offset(in text: String, position: Position, encoding: String = "utf-16") -> Int
  {
    let ns = text as NSString
    guard position.line >= 0 else { return 0 }
    var base = 0
    for _ in 0..<position.line {
      guard base < ns.length else { return ns.length }
      let range = ns.lineRange(for: NSRange(location: base, length: 0))
      base = NSMaxRange(range)
    }
    var lineStart = 0
    var lineEnd = 0
    var contentEnd = 0
    ns.getLineStart(
      &lineStart, end: &lineEnd, contentsEnd: &contentEnd, for: NSRange(location: base, length: 0))
    let line = ns.substring(with: NSRange(location: base, length: max(0, contentEnd - base)))
    if encoding == "utf-16" { return base + min(max(position.character, 0), line.utf16.count) }
    var units = 0
    var offset = 0
    for scalar in line.unicodeScalars {
      let size = encoding == "utf-8" ? scalar.utf8.count : 1
      if units + size > position.character { break }
      units += size
      offset += scalar.utf16.count
    }
    return base + offset
  }
  public static func range(in text: String, json: [String: Any], encoding: String = "utf-16")
    -> NSRange?
  {
    guard let s = json["start"] as? [String: Int], let e = json["end"] as? [String: Int],
      let sl = s["line"], let sc = s["character"], let el = e["line"], let ec = e["character"]
    else { return nil }
    let a = offset(in: text, position: Position(line: sl, character: sc), encoding: encoding)
    let b = offset(in: text, position: Position(line: el, character: ec), encoding: encoding)
    return b >= a ? NSRange(location: a, length: b - a) : nil
  }
}

/// A UTF-16 line-start index. Positions are answered with a binary search and an edit only
/// touches the affected line starts instead of rescanning the whole document.
public struct LineIndex: Sendable, Equatable {
  /// UTF-16 offsets of line starts. `starts[0]` is always 0.
  public private(set) var starts: [Int]

  public init(text: String) {
    self.init(text: text as NSString)
  }

  public init(text ns: NSString) {
    starts = [0]
    var index = 0
    while index < ns.length {
      let unit = ns.character(at: index)
      if unit == 10 {
        starts.append(index + 1)
      } else if unit == 13 {
        if index + 1 < ns.length && ns.character(at: index + 1) == 10 { index += 1 }
        starts.append(index + 1)
      }
      index += 1
    }
  }

  public var lineCount: Int { starts.count }

  public func position(in text: String, utf16Offset: Int, encoding: String = "utf-16")
    -> Position
  {
    position(in: text as NSString, utf16Offset: utf16Offset, encoding: encoding)
  }

  public func position(in ns: NSString, utf16Offset: Int, encoding: String = "utf-16")
    -> Position
  {
    let offset = min(max(0, utf16Offset), ns.length)
    var line = lineNumber(for: offset)
    // Match PositionMap: the LF half of CRLF already belongs to the following line.
    if offset > 0, offset < ns.length, ns.character(at: offset) == 10,
      ns.character(at: offset - 1) == 13
    {
      line = min(line + 1, starts.count - 1)
      return Position(line: line, character: 0)
    }
    let start = starts[line]
    let contentEnd = contentEnd(for: line, in: ns)
    let length = max(0, min(offset, contentEnd) - start)
    if encoding == "utf-16" { return Position(line: line, character: length) }
    let value = ns.substring(with: NSRange(location: start, length: length))
    let character: Int = encoding == "utf-8" ? value.utf8.count : value.unicodeScalars.count
    return Position(line: line, character: character)
  }

  public func offset(in text: String, position: Position, encoding: String = "utf-16") -> Int {
    offset(in: text as NSString, position: position, encoding: encoding)
  }

  public func offset(in ns: NSString, position: Position, encoding: String = "utf-16") -> Int {
    guard position.line >= 0 else { return 0 }
    guard position.line < starts.count else { return ns.length }
    let start = starts[position.line]
    let contentEnd = contentEnd(for: position.line, in: ns)
    let contentLength = max(0, contentEnd - start)
    if encoding == "utf-16" {
      return start + min(max(position.character, 0), contentLength)
    }
    let value = ns.substring(with: NSRange(location: start, length: contentLength))
    var units = 0
    var offset = 0
    for scalar in value.unicodeScalars {
      let size = encoding == "utf-8" ? scalar.utf8.count : 1
      if units + size > position.character { break }
      units += size
      offset += scalar.utf16.count
    }
    return start + offset
  }

  /// Applies an NSTextStorage character edit. `editedRange` is the range in the new text and
  /// `delta` is the change in length.
  public mutating func applyEdit(text: String, editedRange: NSRange, delta: Int) {
    applyEdit(text: text as NSString, editedRange: editedRange, delta: delta)
  }

  public mutating func applyEdit(text ns: NSString, editedRange: NSRange, delta: Int) {
    let location = min(max(0, editedRange.location), ns.length)
    let newLength = min(max(0, editedRange.length), ns.length - location)
    let oldEnd = location + max(0, newLength - delta)
    guard !starts.isEmpty else {
      starts = [0]
      return
    }

    var prefixCount = 0
    while prefixCount < starts.count && starts[prefixCount] <= location { prefixCount += 1 }
    let prefix = Array(starts[0..<prefixCount])

    var suffixIndex = prefixCount
    while suffixIndex < starts.count && starts[suffixIndex] < oldEnd { suffixIndex += 1 }
    var suffix = starts[suffixIndex...].map { $0 + delta }

    // A line start exactly at the old edit boundary survives only when the new text still
    // ends in a line terminator there. Otherwise the following line merged into this one.
    let boundary = location + newLength
    let beforeBoundary: Int =
      boundary > 0 ? Int(ns.character(at: boundary - 1)) : -1
    let keepsBoundary = beforeBoundary == 10 || beforeBoundary == 13
    if !keepsBoundary, suffix.first == boundary { suffix.removeFirst() }

    var middle: [Int] = []
    let middleText = ns.substring(with: NSRange(location: location, length: newLength))
    let middleNS = middleText as NSString
    var index = 0
    while index < middleNS.length {
      let unit = middleNS.character(at: index)
      if unit == 10 {
        middle.append(location + index + 1)
      } else if unit == 13 {
        if index + 1 < middleNS.length && middleNS.character(at: index + 1) == 10 {
          index += 1
        }
        middle.append(location + index + 1)
      }
      index += 1
    }

    if let first = suffix.first, prefix.last == first { suffix.removeFirst() }
    if let first = suffix.first, middle.last == first { suffix.removeFirst() }

    var result = prefix
    result.append(contentsOf: middle)
    result.append(contentsOf: suffix)
    if result.first != 0 { result.insert(0, at: 0) }
    starts = result
  }

  private func lineNumber(for offset: Int) -> Int {
    guard !starts.isEmpty else { return 0 }
    var low = 0
    var high = starts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if starts[middle] <= offset { low = middle } else { high = middle - 1 }
    }
    return low
  }

  private func contentEnd(for line: Int, in ns: NSString) -> Int {
    guard line + 1 < starts.count else { return ns.length }
    let next = starts[line + 1]
    guard next > 0 else { return next }
    let last = ns.character(at: next - 1)
    if last == 10, next >= 2, ns.character(at: next - 2) == 13 { return next - 2 }
    if last == 10 || last == 13 { return next - 1 }
    return next
  }
}
