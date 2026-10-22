import Foundation

/// Portable configuration values. Packs contain data, never executable plugin code.
public enum LanguageValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([LanguageValue])
  case object([String: LanguageValue])
  case null
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([LanguageValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: LanguageValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  public var foundation: Any {
    switch self {
    case .string(let v): return v
    case .number(let v): return v
    case .bool(let v): return v
    case .array(let v): return v.map(\.foundation)
    case .object(let v): return v.mapValues(\.foundation)
    case .null: return NSNull()
    }
  }
  public func expanding(_ context: [String: String]) throws -> LanguageValue {
    switch self {
    case .string(let v): return .string(try LanguageCommand.expand(v, context: context))
    case .array(let v): return .array(try v.map { try $0.expanding(context) })
    case .object(let v): return .object(try v.mapValues { try $0.expanding(context) })
    default: return self
    }
  }
}

public struct LanguageAssociation: Codable, Equatable, Sendable {
  public var languageID: String
  public var extensions: [String]
  public var filenames: [String]
  public var firstLinePattern: String?
  public var grammarID: String?
  public var highlightQuery: String?
  public init(
    languageID: String, extensions: [String] = [], filenames: [String] = [],
    firstLinePattern: String? = nil, grammarID: String? = nil, highlightQuery: String? = nil
  ) {
    self.languageID = languageID
    self.extensions = extensions
    self.filenames = filenames
    self.firstLinePattern = firstLinePattern
    self.grammarID = grammarID
    self.highlightQuery = highlightQuery
  }
  enum CodingKeys: String, CodingKey {
    case languageID, extensions, filenames, firstLinePattern, grammarID, highlightQuery
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    languageID = try c.decode(String.self, forKey: .languageID)
    extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
    filenames = try c.decodeIfPresent([String].self, forKey: .filenames) ?? []
    firstLinePattern = try c.decodeIfPresent(String.self, forKey: .firstLinePattern)
    grammarID = try c.decodeIfPresent(String.self, forKey: .grammarID)
    highlightQuery = try c.decodeIfPresent(String.self, forKey: .highlightQuery)
  }
}

public struct LanguageSnippet: Codable, Equatable, Sendable {
  public var name: String
  public var text: String
  public init(name: String, text: String) {
    self.name = name
    self.text = text
  }
}

public struct LanguageEditorConfiguration: Codable, Equatable, Sendable {
  public var lineComment: String?
  public var snippets: [LanguageSnippet]
  public var indentSize: Int?
  public var useTabs: Bool?
  public init(
    lineComment: String? = nil, snippets: [LanguageSnippet] = [], indentSize: Int? = nil,
    useTabs: Bool? = nil
  ) {
    self.lineComment = lineComment
    self.snippets = snippets
    self.indentSize = indentSize
    self.useTabs = useTabs
  }
  enum CodingKeys: String, CodingKey { case lineComment, snippets, indentSize, useTabs }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    lineComment = try c.decodeIfPresent(String.self, forKey: .lineComment)
    snippets = try c.decodeIfPresent([LanguageSnippet].self, forKey: .snippets) ?? []
    indentSize = try c.decodeIfPresent(Int.self, forKey: .indentSize)
    useTabs = try c.decodeIfPresent(Bool.self, forKey: .useTabs)
  }
}

public struct LanguageCommand: Codable, Equatable, Sendable {
  public var executable: String
  public var arguments: [String]
  public var workingDirectory: String?
  public var environment: [String: String]
  public init(
    executable: String, arguments: [String] = [], workingDirectory: String? = nil,
    environment: [String: String] = [:]
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
  enum CodingKeys: String, CodingKey { case executable, arguments, workingDirectory, environment }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    executable = try c.decode(String.self, forKey: .executable)
    arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
    workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
    environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
  }
  public static let placeholders: Set<String> = [
    "workspace", "file", "fileName", "fileStem", "python", "program", "buildDir", "interpreter",
  ]
  public static func expand(_ value: String, context: [String: String]) throws -> String {
    let regex = try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
    var result = value
    for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
    {
      guard let keyRange = Range(match.range(at: 1), in: value),
        let range = Range(match.range, in: result)
      else { continue }
      let key = String(value[keyRange])
      guard placeholders.contains(key), let replacement = context[key] else {
        throw TCodeError.message("Unknown or unavailable language placeholder: \(key)")
      }
      result.replaceSubrange(range, with: replacement)
    }
    return result
  }
  public func resolved(_ context: [String: String]) throws -> LanguageCommand {
    LanguageCommand(
      executable: try Self.expand(executable, context: context),
      arguments: try arguments.map { try Self.expand($0, context: context) },
      workingDirectory: try workingDirectory.map { try Self.expand($0, context: context) },
      environment: try environment.mapValues { try Self.expand($0, context: context) })
  }
}

public struct LanguageServerConfiguration: Codable, Equatable, Sendable {
  public var command: LanguageCommand
  public var initializationOptions: LanguageValue?
  public var settings: LanguageValue?
  public var rootMarkers: [String]
  public init(
    command: LanguageCommand, initializationOptions: LanguageValue? = nil,
    settings: LanguageValue? = nil, rootMarkers: [String] = []
  ) {
    self.command = command
    self.initializationOptions = initializationOptions
    self.settings = settings
    self.rootMarkers = rootMarkers
  }
  enum CodingKeys: String, CodingKey { case command, initializationOptions, settings, rootMarkers }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    command = try c.decode(LanguageCommand.self, forKey: .command)
    initializationOptions = try c.decodeIfPresent(
      LanguageValue.self, forKey: .initializationOptions)
    settings = try c.decodeIfPresent(LanguageValue.self, forKey: .settings)
    rootMarkers = try c.decodeIfPresent([String].self, forKey: .rootMarkers) ?? []
  }
}

public struct LanguageTask: Codable, Equatable, Sendable {
  public var steps: [LanguageCommand]
  public var rootMarkers: [String]
  public var resultParser: String?
  public init(steps: [LanguageCommand], rootMarkers: [String] = [], resultParser: String? = nil) {
    self.steps = steps
    self.rootMarkers = rootMarkers
    self.resultParser = resultParser
  }
  enum CodingKeys: String, CodingKey { case steps, rootMarkers, resultParser }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    steps = try c.decode([LanguageCommand].self, forKey: .steps)
    rootMarkers = try c.decodeIfPresent([String].self, forKey: .rootMarkers) ?? []
    resultParser = try c.decodeIfPresent(String.self, forKey: .resultParser)
  }
}

public struct LanguageDebugConfiguration: Codable, Equatable, Sendable {
  public var adapterID: String
  public var command: LanguageCommand
  public var launch: [String: LanguageValue]
  public init(adapterID: String, command: LanguageCommand, launch: [String: LanguageValue] = [:]) {
    self.adapterID = adapterID
    self.command = command
    self.launch = launch
  }
}

public struct LanguagePack: Codable, Equatable, Sendable, Identifiable {
  public var interfaceVersion: Int = 2
  public var id: String
  public var name: String
  public var version: String
  public var associations: [LanguageAssociation]
  public var editor: LanguageEditorConfiguration
  public var languageServer: LanguageServerConfiguration?
  public var formatterCommand: LanguageCommand?
  public var tasks: [String: LanguageTask]
  public var debugger: LanguageDebugConfiguration?
  public var toolRecipeIDs: [String]
  public var diagnosticAdapter: String?
  public var extensions: [String] { Array(Set(associations.flatMap(\.extensions))).sorted() }
  public var grammarIDs: [String] { Array(Set(associations.compactMap(\.grammarID))).sorted() }
  public var server: String { languageServer?.command.executable ?? "" }
  public var serverArguments: [String] { languageServer?.command.arguments ?? [] }
  public var formatter: String { formatterCommand?.executable ?? "" }
  public var adapter: String { debugger?.command.executable ?? "" }
  public var enabled: Bool { !UserDefaults.standard.bool(forKey: "disabled." + id) }
  public init(
    id: String, name: String, version: String = "1.0.0", associations: [LanguageAssociation],
    editor: LanguageEditorConfiguration = .init(),
    languageServer: LanguageServerConfiguration? = nil, formatterCommand: LanguageCommand? = nil,
    tasks: [String: LanguageTask] = [:], debugger: LanguageDebugConfiguration? = nil,
    toolRecipeIDs: [String] = [], diagnosticAdapter: String? = nil
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.associations = associations
    self.editor = editor
    self.languageServer = languageServer
    self.formatterCommand = formatterCommand
    self.tasks = tasks
    self.debugger = debugger
    self.toolRecipeIDs = toolRecipeIDs
    self.diagnosticAdapter = diagnosticAdapter
  }
  enum CodingKeys: String, CodingKey {
    case interfaceVersion, id, name, version, associations, editor, languageServer,
      formatterCommand, tasks, debugger, toolRecipeIDs, diagnosticAdapter, extensions, server,
      serverArguments, formatter, adapter
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let schema = try c.decode(Int.self, forKey: .interfaceVersion)
    guard [1, 2].contains(schema) else {
      throw TCodeError.message("Unsupported language pack interface version: \(schema)")
    }
    let id = try c.decode(String.self, forKey: .id)
    let name = try c.decode(String.self, forKey: .name)
    if schema == 1 {
      self = Self.legacy(
        id: id, name: name, extensions: try c.decode([String].self, forKey: .extensions),
        server: try c.decode(String.self, forKey: .server),
        serverArguments: try c.decode([String].self, forKey: .serverArguments),
        formatter: try c.decode(String.self, forKey: .formatter),
        adapter: try c.decode(String.self, forKey: .adapter))
    } else {
      self.init(
        id: id, name: name, version: try c.decode(String.self, forKey: .version),
        associations: try c.decode([LanguageAssociation].self, forKey: .associations),
        editor: try c.decodeIfPresent(LanguageEditorConfiguration.self, forKey: .editor) ?? .init(),
        languageServer: try c.decodeIfPresent(
          LanguageServerConfiguration.self, forKey: .languageServer),
        formatterCommand: try c.decodeIfPresent(LanguageCommand.self, forKey: .formatterCommand),
        tasks: try c.decodeIfPresent([String: LanguageTask].self, forKey: .tasks) ?? [:],
        debugger: try c.decodeIfPresent(LanguageDebugConfiguration.self, forKey: .debugger),
        toolRecipeIDs: try c.decodeIfPresent([String].self, forKey: .toolRecipeIDs) ?? [],
        diagnosticAdapter: try c.decodeIfPresent(String.self, forKey: .diagnosticAdapter))
    }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(2, forKey: .interfaceVersion)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(version, forKey: .version)
    try c.encode(associations, forKey: .associations)
    try c.encode(editor, forKey: .editor)
    try c.encodeIfPresent(languageServer, forKey: .languageServer)
    try c.encodeIfPresent(formatterCommand, forKey: .formatterCommand)
    try c.encode(tasks, forKey: .tasks)
    try c.encodeIfPresent(debugger, forKey: .debugger)
    try c.encode(toolRecipeIDs, forKey: .toolRecipeIDs)
    try c.encodeIfPresent(diagnosticAdapter, forKey: .diagnosticAdapter)
  }
  public func validate() throws {
    let identifier = #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$"#
    func valid(_ s: String) -> Bool { s.range(of: identifier, options: .regularExpression) != nil }
    guard valid(id), !name.isEmpty, name.count <= 120, valid(version), !associations.isEmpty,
      associations.count <= 64
    else {
      throw TCodeError.message("A language pack needs a valid id/version, name, and associations.")
    }
    for a in associations {
      guard valid(a.languageID), a.grammarID.map(valid) ?? true,
        a.extensions.allSatisfy({
          !$0.isEmpty && !$0.contains("/") && !$0.contains(".") && $0.count <= 40
        }), a.filenames.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0.count <= 200 })
      else { throw TCodeError.message("Invalid file association in \(name).") }
      if let query = a.highlightQuery {
        guard a.grammarID != nil, query.utf8.count <= 1_048_576, !query.contains("\0") else {
          throw TCodeError.message(
            "Inline highlighting queries require a grammar identifier, valid text, and a maximum size of 1 MB."
          )
        }
      }
      if let pattern = a.firstLinePattern {
        guard pattern.count <= 512 else {
          throw TCodeError.message("Shebang recognition pattern is too long.")
        }
        _ = try NSRegularExpression(pattern: pattern)
      }
    }
    guard editor.indentSize.map({ (1...16).contains($0) }) ?? true, editor.snippets.count <= 200
    else { throw TCodeError.message("Invalid indentation/snippet configuration.") }
    guard toolRecipeIDs.allSatisfy(valid) else {
      throw TCodeError.message("Invalid managed tool recipe identifier.")
    }
    var commands = tasks.values.flatMap(\.steps)
    if let command = languageServer?.command { commands.append(command) }
    if let command = formatterCommand { commands.append(command) }
    if let command = debugger?.command { commands.append(command) }
    guard commands.count <= 100 else { throw TCodeError.message("Too many configured commands.") }
    for c in commands {
      guard !c.executable.isEmpty, !c.executable.contains("\0"), c.arguments.count <= 128,
        c.arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 32768 }),
        c.environment.keys.allSatisfy({ !$0.contains("=") && !$0.contains("\0") })
      else { throw TCodeError.message("Invalid command in \(name).") }
      let values =
        [c.executable] + c.arguments + Array(c.environment.values) + [c.workingDirectory ?? ""]
      let context = Dictionary(
        uniqueKeysWithValues: LanguageCommand.placeholders.map { ($0, "value") })
      for value in values { _ = try LanguageCommand.expand(value, context: context) }
    }
  }
  /// Export intentionally errs on the side of refusing local/private configuration.
  /// It cannot identify arbitrary secrets embedded in otherwise ordinary prose; users still review exports.
  public func portableData() throws -> Data {
    try validate()
    let message =
      "Export rejected a local path, environment, or credential setting. Use portable placeholders and local Settings overrides, and remove private values before exporting."
    func reject() throws { throw TCodeError.message(message) }
    func placeholder(_ text: String) -> Bool {
      LanguageCommand.placeholders.contains { text == "${" + $0 + "}" }
    }
    func inspectString(_ text: String) throws {
      let patterns = [
        #"(^|[\s=:"'\[,;(])(?:/(?!/)|~[/\\]|[A-Za-z]:[/\\]|\\\\)"#,
        #"(?i)\$(?:HOME|USERPROFILE)\b|\$\{(?:HOME|USERPROFILE)\}|%USERPROFILE%|\bfile://"#,
        #"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9+/=_-]{8,}|\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AKIA[A-Z0-9]{16})\b"#,
        #"(?i)(?:--|\b)(?:api[-_]?key|access[-_]?token|refresh[-_]?token|token|password|passwd|client[-_]?secret|secret|authorization|auth|credential)(?:\s|=|:|$)"#,
      ]
      if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
        try reject()
      }
      if let url = URLComponents(string: text), url.user != nil || url.password != nil {
        try reject()
      }
    }
    func isEmpty(_ value: LanguageValue) -> Bool {
      switch value {
      case .null: return true
      case .string(let text): return text.isEmpty
      case .array(let values): return values.isEmpty
      case .object(let values): return values.isEmpty
      default: return false
      }
    }
    func inspectValue(_ value: LanguageValue) throws {
      switch value {
      case .string(let text): try inspectString(text)
      case .array(let values): for value in values { try inspectValue(value) }
      case .object(let values):
        for (key, value) in values {
          try inspectString(key)
          let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
          let privateKeys: Set<String> = [
            "token", "accesstoken", "refreshtoken", "apikey", "clientsecret", "secret", "secrets",
            "password", "passwd", "credential", "credentials", "authorization", "authentication",
            "auth", "headers", "httpheaders", "envfile", "dotenv",
          ]
          if privateKeys.contains(normalized)
            || ["token", "password", "secret", "apikey", "credentials"].contains(where: {
              normalized.hasSuffix($0)
            }), !isEmpty(value)
          {
            try reject()
          }
          if ["env", "environment", "environmentvariables"].contains(normalized), !isEmpty(value) {
            // Existing Python Jedi configuration uses a portable interpreter placeholder under this key.
            if case .string(let text) = value, placeholder(text) {} else { try reject() }
          }
          try inspectValue(value)
        }
      default: break
      }
    }
    func inspectCommand(_ command: LanguageCommand) throws {
      guard command.environment.isEmpty else {
        try reject()
        return
      }
      try inspectString(command.executable)
      if let directory = command.workingDirectory { try inspectString(directory) }
      for argument in command.arguments { try inspectString(argument) }
    }
    for task in tasks.values { for command in task.steps { try inspectCommand(command) } }
    if let server = languageServer {
      try inspectCommand(server.command)
      if let value = server.initializationOptions { try inspectValue(value) }
      if let value = server.settings { try inspectValue(value) }
    }
    if let command = formatterCommand { try inspectCommand(command) }
    if let debugger {
      try inspectCommand(debugger.command)
      try inspectValue(.object(debugger.launch))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

}

public struct LanguageMatch: Equatable, Sendable {
  public var pack: LanguagePack
  public var association: LanguageAssociation
  public var score: Int
  public var key: String { pack.id + ":" + association.languageID }
}

public enum LanguageRecognition {
  public static func matches(
    packs: [LanguagePack], url: URL?, firstLine: String, override: String? = nil
  ) -> [LanguageMatch] {
    if override == "text" { return [] }
    // Imported expressions can be valid yet take exponential time to reject a line.
    // Share one deadline across all of them; filename/extension checks remain available.
    let clock = ContinuousClock()
    let regexDeadline = clock.now.advanced(by: .milliseconds(10))
    let line = String(firstLine.prefix(1024))
    let lineRange = NSRange(line.startIndex..., in: line)
    var matches: [LanguageMatch] = []
    for pack in packs where pack.enabled {
      for association in pack.associations {
        let key = pack.id + ":" + association.languageID
        var score = 0
        if let override, override == key {
          score = 100
        } else if let url, association.filenames.contains(url.lastPathComponent) {
          score = 30
        } else if let url,
          association.extensions.contains(where: {
            $0.caseInsensitiveCompare(url.pathExtension) == .orderedSame
          })
        {
          score = 20
        } else if let pattern = association.firstLinePattern, clock.now < regexDeadline,
          let expression = try? NSRegularExpression(pattern: pattern)
        {
          expression.enumerateMatches(in: line, options: .reportProgress, range: lineRange) {
            result, _, stop in
            if clock.now >= regexDeadline {
              stop.pointee = true
            } else if result != nil {
              score = 10
              stop.pointee = true
            }
          }
        }
        if score > 0 { matches.append(.init(pack: pack, association: association, score: score)) }
      }
    }
    if override != nil { matches.removeAll { $0.score != 100 } }
    let highest = matches.map(\.score).max() ?? 0
    return matches.filter { $0.score == highest }.sorted { $0.key < $1.key }
  }
}
