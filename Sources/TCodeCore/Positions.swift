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
