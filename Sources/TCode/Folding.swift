import AppKit

@MainActor
final class FoldingLayoutManager: NSLayoutManager, @preconcurrency NSLayoutManagerDelegate {
  var folded: [NSRange] = []
  override init() {
    super.init()
    delegate = self
  }
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    delegate = self
  }
  func toggle(_ range: NSRange) {
    if range.length == 0 {
      folded.removeAll()
    } else if let index = folded.firstIndex(of: range) {
      folded.remove(at: index)
    } else {
      folded.append(range)
    }
    invalidateAllGlyphs()
  }
  /// Restores folds saved with a document's view state without toggling them.
  func restore(_ ranges: [NSRange]) {
    folded = ranges.filter { $0.length > 0 }
    invalidateAllGlyphs()
  }
  private func invalidateAllGlyphs() {
    if let textStorage {
      invalidateGlyphs(
        forCharacterRange: NSRange(location: 0, length: textStorage.length), changeInLength: 0,
        actualCharacterRange: nil)
    }
  }
  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
    font: NSFont, forGlyphRange glyphRange: NSRange
  ) -> Int {
    guard !folded.isEmpty else { return 0 }
    var modified = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
    for index in 0..<glyphRange.length
    where folded.contains(where: { NSLocationInRange(characterIndexes[index], $0) }) {
      modified[index] = .null
    }
    modified.withUnsafeBufferPointer { pointer in
      setGlyphs(
        glyphs, properties: pointer.baseAddress!, characterIndexes: characterIndexes, font: font,
        forGlyphRange: glyphRange)
    }
    return glyphRange.length
  }
}
