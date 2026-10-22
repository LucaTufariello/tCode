import AppKit
import TCodeCore

@MainActor final class CodeTextView: NSTextView {
  weak var codeDocument: CodeDocument?
  var onSelection: (() -> Void)?
  var indent = "    "
  var comment = "//"
  var additionalCursors: [Int] = []
  override var undoManager: UndoManager? { codeDocument?.undo }
  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    guard !additionalCursors.isEmpty, !hasMarkedText(),
      let value = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
    else {
      super.insertText(insertString, replacementRange: replacementRange)
      return
    }
    let main = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
    let ranges = ([main] + additionalCursors.map { NSRange(location: $0, length: 0) }).sorted {
      $0.location < $1.location
    }
    guard
      shouldChangeText(
        inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: ranges.map { _ in value })
    else { return }
    for range in ranges.reversed() { textStorage?.replaceCharacters(in: range, with: value) }
    didChangeText()
    var delta = 0
    var cursors: [Int] = []
    for range in ranges {
      cursors.append(range.location + delta + value.utf16.count)
      delta += value.utf16.count - range.length
    }
    additionalCursors = Array(cursors.dropFirst())
    setSelectedRange(NSRange(location: cursors[0], length: 0))
    needsDisplay = true
  }
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    additionalCursors.removeAll()
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
  }
  @objc func addCursorBelow(_ sender: Any?) { addCursor(direction: 1) }
  @objc func addCursorAbove(_ sender: Any?) { addCursor(direction: -1) }
  func addCursor(direction: Int) {
    let position = PositionMap.position(
      in: string,
      utf16Offset: direction > 0
        ? additionalCursors.max() ?? selectedRange().location
        : additionalCursors.min() ?? selectedRange().location)
    guard position.line + direction >= 0 else { return }
    let offset = PositionMap.offset(
      in: string, position: Position(line: position.line + direction, character: position.character)
    )
    if offset != selectedRange().location && !additionalCursors.contains(offset) {
      additionalCursors.append(offset)
      needsDisplay = true
    }
  }
  override func cancelOperation(_ sender: Any?) {
    additionalCursors.removeAll()
    (layoutManager as? FoldingLayoutManager)?.toggle(NSRange(location: 0, length: 0))
    needsDisplay = true
  }
  @objc func foldSelection(_ sender: Any?) {
    (layoutManager as? FoldingLayoutManager)?.toggle(selectedRange())
    setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let lm = layoutManager, let tc = textContainer else { return }
    insertionPointColor.setFill()
    for offset in additionalCursors where offset < (string as NSString).length {
      let glyph = lm.glyphIndexForCharacter(at: offset)
      let point = lm.location(forGlyphAt: glyph)
      let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      NSRect(
        x: point.x + textContainerOrigin.x, y: line.minY + textContainerOrigin.y, width: 1.5,
        height: line.height
      ).fill()
    }
    _ = tc
  }
  override func insertTab(_ sender: Any?) { insertText(indent, replacementRange: selectedRange()) }
  override func insertNewline(_ sender: Any?) {
    let ns = string as NSString
    let range = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
    let prefix = ns.substring(
      with: NSRange(location: range.location, length: selectedRange().location - range.location))
    let whitespace = String(prefix.prefix { $0 == " " || $0 == "\t" })
    let newline = string.contains("\r\n") ? "\r\n" : string.contains("\r") ? "\r" : "\n"
    insertText(
      newline + whitespace + ((prefix.hasSuffix("{") || prefix.hasSuffix(":")) ? indent : ""),
      replacementRange: selectedRange())
  }
  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    guard let lm = layoutManager, let tc = textContainer, selectedRange().length == 0,
      !string.isEmpty
    else { return }
    let index = min(selectedRange().location, max(0, (string as NSString).length - 1))
    let glyph = lm.glyphIndexForCharacter(at: index)
    var line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    line.origin.y += textContainerOrigin.y
    line.origin.x = 0
    line.size.width = bounds.width
    if line.intersects(rect) {
      Style.currentLine.setFill()
      line.fill()
    }
    _ = tc
  }
  @objc func toggleComment(_ sender: Any?) {
    guard !comment.isEmpty else {
      NSSound.beep()
      return
    }
    let ns = string as NSString
    let range = ns.lineRange(for: selectedRange())
    let lines = ns.substring(with: range).components(separatedBy: "\n")
    let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let remove =
      !nonempty.isEmpty
      && nonempty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(comment) }
    let replacement = lines.enumerated().map { index, line -> String in
      if line.isEmpty && index == lines.count - 1 { return line }
      let leading = String(line.prefix { $0 == " " || $0 == "\t" })
      var rest = String(line.dropFirst(leading.count))
      if remove && rest.hasPrefix(comment) {
        rest.removeFirst(comment.count)
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return leading + rest
      }
      return leading + comment + " " + rest
    }.joined(separator: "\n")
    replace(range, with: replacement, action: "Toggle Comment")
  }
  @objc func duplicateLine(_ sender: Any?) {
    let ns = string as NSString
    let range = ns.lineRange(for: selectedRange())
    var value = ns.substring(with: range)
    if !value.hasSuffix("\n") && !value.hasSuffix("\r") {
      value = (string.contains("\r\n") ? "\r\n" : string.contains("\r") ? "\r" : "\n") + value
    }
    replace(NSRange(location: NSMaxRange(range), length: 0), with: value, action: "Duplicate Line")
  }
  @objc func selectNextOccurrence(_ sender: Any?) {
    let ns = string as NSString
    if selectedRange().length == 0 {
      selectWord(sender)
      return
    }
    let value = ns.substring(with: selectedRange())
    let start = selectedRanges.map { NSMaxRange($0.rangeValue) }.max() ?? 0
    let found = ns.range(of: value, range: NSRange(location: start, length: ns.length - start))
    if found.location != NSNotFound { selectedRanges.append(NSValue(range: found)) }
  }
  func replace(_ range: NSRange, with text: String, action: String) {
    let manager = undoManager
    manager?.beginUndoGrouping()
    defer { manager?.endUndoGrouping() }
    guard shouldChangeText(in: range, replacementString: text) else { return }
    textStorage?.replaceCharacters(in: range, with: text)
    didChangeText()
    manager?.setActionName(action)
  }
}

@MainActor final class LineRuler: NSRulerView {
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  weak var editor: CodeTextView?
  var breakpoints = Set<Int>()
  var breakpointChanged: ((Int) -> Void)?
  init(scroll: NSScrollView, editor: CodeTextView) {
    self.editor = editor
    super.init(scrollView: scroll, orientation: .verticalRuler)
    clientView = editor
    ruleThickness = 58
    let recognizer = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
    recognizer.buttonMask = 1
    addGestureRecognizer(recognizer)
    setAccessibilityLabel("Line numbers and breakpoints")
  }
  required init(coder: NSCoder) { fatalError() }
  @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
    guard let editor, let scrollView, let lm = editor.layoutManager, let tc = editor.textContainer
    else { return }
    let y =
      recognizer.location(in: self).y + scrollView.contentView.bounds.origin.y
      - editor.textContainerOrigin.y
    let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc)
    let char = lm.characterIndexForGlyph(at: glyph)
    let line = PositionMap.position(in: editor.string, utf16Offset: char).line + 1
    if breakpoints.contains(line) { breakpoints.remove(line) } else { breakpoints.insert(line) }
    breakpointChanged?(line)
    needsDisplay = true
  }
  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let editor, let lm = editor.layoutManager, let tc = editor.textContainer, let scrollView
    else { return }
    Style.editorBackground.setFill()
    bounds.fill()
    let visible = scrollView.contentView.bounds
    let glyphs = lm.glyphRange(
      forBoundingRect: visible.offsetBy(
        dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y), in: tc)
    var glyph = glyphs.location
    let ns = editor.string as NSString
    let activeLine =
      editor.codeDocument?.large == true
      ? -1
      : PositionMap.position(in: editor.string, utf16Offset: editor.selectedRange().location).line
        + 1
    var line =
      PositionMap.position(
        in: editor.string,
        utf16Offset: lm.characterIndexForGlyph(at: min(glyph, max(lm.numberOfGlyphs - 1, 0)))
      ).line + 1
    while glyph < NSMaxRange(glyphs) && glyph < lm.numberOfGlyphs {
      var range = NSRange()
      let r = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
      let char = lm.characterIndexForGlyph(at: glyph)
      if char == 0
        || ["\n", "\r"].contains(ns.substring(with: NSRange(location: char - 1, length: 1)))
      {
        let y = r.minY + editor.textContainerOrigin.y - visible.minY
        if breakpoints.contains(line) {
          NSColor.systemRed.setFill()
          NSBezierPath(ovalIn: NSRect(x: 5, y: y + 3, width: 9, height: 9)).fill()
        }
        let label = String(line) as NSString
        let isActive = line == activeLine
        let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedDigitSystemFont(
            ofSize: 11, weight: isActive ? .medium : .regular),
          .foregroundColor: isActive ? Style.gutterActive : Style.gutter,
        ]
        label.draw(
          at: NSPoint(x: 48 - label.size(withAttributes: attributes).width, y: y + 2),
          withAttributes: attributes)
        line += 1
      }
      glyph = NSMaxRange(range)
    }
  }
}

@MainActor final class EditorPane: NSViewController, NSTextViewDelegate {
  let document: CodeDocument
  let editor: CodeTextView
  let scroll = NSScrollView()
  var ruler: LineRuler!
  var selectionChanged: ((Position) -> Void)?
  var syntaxChanged: (() -> Void)?
  private var highlightTask: Task<Void, Never>?
  init(document: CodeDocument) {
    self.document = document
    let lm = FoldingLayoutManager()
    let container = NSTextContainer(
      containerSize: NSSize(width: 10000, height: CGFloat.greatestFiniteMagnitude))
    document.storage.addLayoutManager(lm)
    lm.addTextContainer(container)
    editor = CodeTextView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 600), textContainer: container)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    editor.codeDocument = document
    editor.delegate = self
    editor.isRichText = false
    editor.importsGraphics = false
    editor.allowsUndo = true
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.isGrammarCheckingEnabled = false
    editor.usesFindBar = true
    editor.isIncrementalSearchingEnabled = true
    let fontSize = CGFloat(
      UserDefaults.standard.double(forKey: "fontSize") == 0
        ? 13 : UserDefaults.standard.double(forKey: "fontSize"))
    let candidate = NSFont(
      name: UserDefaults.standard.string(forKey: "fontName") ?? "SF Mono", size: fontSize)
    editor.font =
      candidate?.isFixedPitch == true
      ? candidate : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    editor.textColor = Style.editorText
    editor.backgroundColor = Style.editorBackground
    editor.insertionPointColor = .controlAccentColor
    // Reserve the gutter inside the text surface; macOS overlay rulers cover that area.
    editor.textContainerInset = NSSize(width: 72, height: 18)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.minSize = .zero
    editor.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.setAccessibilityLabel("Code editor, " + document.title)
    editor.comment = document.languageComment ?? ""
    let spaces = UserDefaults.standard.integer(forKey: "indentWidth")
    editor.indent = String(repeating: " ", count: spaces == 0 ? 4 : spaces)
    scroll.documentView = editor
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.backgroundColor = Style.editorBackground
    ruler = LineRuler(scroll: scroll, editor: editor)
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
      object: scroll.contentView)
    view = scroll
    highlight()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    let clip = scroll.contentView.bounds
    guard clip.width > 0, clip.height > 0 else { return }
    // The text surface has to cover the whole pane. TextKit grows it for long documents, but it
    // must never be left shorter or narrower than the clip view, otherwise a strip of dead
    // background shows under the last line when the pane grows.
    let width = editor.isHorizontallyResizable ? editor.frame.width : clip.width
    let height = max(editor.frame.height, clip.height)
    if abs(editor.frame.width - width) > 0.5 || abs(editor.frame.height - height) > 0.5 {
      editor.setFrameSize(NSSize(width: width, height: height))
    }
    if scroll.contentView.bounds.minX != 0 {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }
  @objc func scrolled() { ruler.needsDisplay = true }
  func detach() {
    highlightTask?.cancel()
    NotificationCenter.default.removeObserver(self)
    if let lm = editor.layoutManager { document.storage.removeLayoutManager(lm) }
  }
  func textDidChange(_ notification: Notification) {
    if let lm = editor.layoutManager as? FoldingLayoutManager, !lm.folded.isEmpty {
      lm.toggle(NSRange(location: 0, length: 0))
    }
    highlight()
    ruler.needsDisplay = true
  }
  func textViewDidChangeSelection(_ notification: Notification) {
    selectionChanged?(
      PositionMap.position(in: editor.string, utf16Offset: editor.selectedRange().location))
    ruler.needsDisplay = true
    editor.needsDisplay = true
    matchBracket()
  }
  func matchBracket() {
    guard let lm = editor.layoutManager else { return }
    lm.removeTemporaryAttribute(
      .backgroundColor, forCharacterRange: NSRange(location: 0, length: document.storage.length))
    let ns = editor.string as NSString
    let cursor = editor.selectedRange().location
    guard cursor > 0, cursor <= ns.length, !document.large else { return }
    let value = ns.character(at: cursor - 1)
    let opens: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
    let close = opens[value]
    let open = opens.first(where: { $0.value == value })?.key
    guard close != nil || open != nil else { return }
    let direction = close != nil ? 1 : -1
    let target = close ?? open!
    var depth = 1
    var i = cursor - 1 + direction
    var steps = 0
    while i >= 0 && i < ns.length && steps < 20000 {
      let c = ns.character(at: i)
      if c == value { depth += 1 }
      if c == target { depth -= 1 }
      if depth == 0 {
        for index in [i, cursor - 1] {
          lm.addTemporaryAttribute(
            .backgroundColor, value: Style.matchingBracket,
            forCharacterRange: NSRange(location: index, length: 1))
        }
        break
      }
      i += direction
      steps += 1
    }
  }
  func highlight() {
    highlightTask?.cancel()
    if document.languageOverride == "text" {
      editor.layoutManager?.removeTemporaryAttribute(
        .foregroundColor, forCharacterRange: NSRange(location: 0, length: document.storage.length))
      document.syntaxStatus = "Plain text"
      syntaxChanged?()
      return
    }
    guard !document.large else { return }
    let text = editor.string
    let version = document.version
    let grammarID = document.grammarID
    let query = document.highlightQuery
    highlightTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      if let grammarID {
        do {
          guard let id = self?.document.id else { return }
          let parsed = try await SyntaxClient.shared.highlight(
            documentID: id, version: version, text: text, grammarID: grammarID, queryOverride: query
          )
          guard let self, self.document.version == version, self.document.grammarID == grammarID,
            !Task.isCancelled, let lm = self.editor.layoutManager
          else { return }
          lm.removeTemporaryAttribute(
            .foregroundColor,
            forCharacterRange: NSRange(location: 0, length: self.document.storage.length))
          for span in parsed
          where span.location >= 0 && span.length >= 0
            && span.location <= self.document.storage.length
            && span.length <= self.document.storage.length - span.location
          {
            let color: NSColor
            switch span.capture.split(separator: ".").first.map(String.init) {
            case "keyword", "operator": color = Style.syntaxKeyword
            case "number", "boolean", "constant": color = Style.syntaxNumber
            case "type", "constructor": color = Style.syntaxType
            case "string", "character": color = Style.syntaxString
            case "comment": color = Style.syntaxComment
            default: color = Style.editorText
            }
            lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: span.range)
          }
          self.document.syntaxStatus = "Tree-sitter"
          self.syntaxChanged?()
          await SyntaxMetric.record(self.document, spanCount: parsed.count)
          return
        } catch is CancellationError { return } catch {
          guard let self, !Task.isCancelled else { return }
          self.document.syntaxStatus = error.localizedDescription
          self.syntaxChanged?()
          await SyntaxMetric.record(self.document)
        }
      }
      let spans = await Task.detached { () -> [(NSRange, Int)] in
        let patterns = [
          "\\b(func|let|var|class|struct|enum|import|return|if|else|for|while|def|from|try|except|public|private|static|void|int|float|double|const|auto|namespace|include|async|await|throws|throw|guard|self|True|False|None|true|false|nil)\\b",
          "\\b[0-9]+(?:\\.[0-9]+)?\\b",
          "\\b(?!(?:True|False|None)\\b)[A-Z][A-Za-z0-9_]*\\b",
          "\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'",
          "(?m)//.*$|(?m)#.*$",
        ]
        return patterns.enumerated().flatMap { index, pattern in
          (try? NSRegularExpression(pattern: pattern))?.matches(
            in: text, range: NSRange(location: 0, length: text.utf16.count)
          ).map { ($0.range, index) } ?? []
        }
      }.value
      guard let self, self.document.version == version, !Task.isCancelled,
        let lm = self.editor.layoutManager
      else { return }
      lm.removeTemporaryAttribute(
        .foregroundColor,
        forCharacterRange: NSRange(location: 0, length: self.document.storage.length))
      let colors: [NSColor] = [
        Style.syntaxKeyword, Style.syntaxNumber, Style.syntaxType, Style.syntaxString,
        Style.syntaxComment,
      ]
      for (range, index) in spans {
        lm.addTemporaryAttribute(.foregroundColor, value: colors[index], forCharacterRange: range)
      }
    }
  }
  func go(to position: Position, encoding: String = "utf-16") {
    let offset = PositionMap.offset(in: document.text, position: position, encoding: encoding)
    editor.setSelectedRange(NSRange(location: offset, length: 0))
    editor.scrollRangeToVisible(editor.selectedRange())
    view.window?.makeFirstResponder(editor)
  }
}
