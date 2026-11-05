import Foundation

struct AgentToolCall: Sendable {
  struct Function: Sendable {
    let name: String
    let arguments: String
  }
  let id: String
  let function: Function
}

enum AgentEvent: Sendable {
  case delta(String)
  case toolCalls([AgentToolCall])
  case done
}

enum AgentError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let value) = self { return value }
    return nil
  }
}

/// OpenAI-compatible chat completions with SSE streaming and function-call accumulation.
struct AgentClient {
  let configuration: AgentConfiguration
  let apiKey: String

  private var completionURL: URL? {
    var base = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    guard !base.isEmpty else { return nil }
    let value = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
    return URL(string: value)
  }

  func stream(messages: [[String: Any]], tools: [[String: Any]]?)
    -> AsyncThrowingStream<AgentEvent, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let url = completionURL else {
            throw AgentError.message("Set a valid provider endpoint in Settings → Agent.")
          }
          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.timeoutInterval = 120
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "stream": true,
            "temperature": 0.2,
          ]
          if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
          }
          request.httpBody = try JSONSerialization.data(withJSONObject: body)
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            throw AgentError.message("The provider returned an invalid response.")
          }
          guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let text = String(decoding: data, as: UTF8.self)
            throw AgentError.message(
              "Provider returned \(http.statusCode): \(text.prefix(600))")
          }
          var calls: [Int: (id: String, name: String, arguments: String)] = [:]
          for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let error = object["error"] as? [String: Any] {
              throw AgentError.message(error["message"] as? String ?? "Provider error")
            }
            guard let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let delta = choice["delta"] as? [String: Any]
            else { continue }
            if let content = delta["content"] as? String, !content.isEmpty {
              continuation.yield(.delta(content))
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
              let index = call["index"] as? Int ?? 0
              var current = calls[index] ?? ("", "", "")
              if let id = call["id"] as? String, !id.isEmpty { current.id = id }
              if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String { current.name += name }
                if let arguments = function["arguments"] as? String {
                  current.arguments += arguments
                }
              }
              calls[index] = current
            }
          }
          let resolved = calls.sorted { $0.key < $1.key }.map { item in
            AgentToolCall(
              id: item.value.id.isEmpty ? UUID().uuidString : item.value.id,
              function: .init(name: item.value.name, arguments: item.value.arguments))
          }
          if !resolved.isEmpty { continuation.yield(.toolCalls(resolved)) }
          continuation.yield(.done)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

enum AgentTools {
  static let definitions: [[String: Any]] = [
    [
      "type": "function",
      "function": [
        "name": "read_file",
        "description": "Read a UTF-8 text file inside the workspace.",
        "parameters": [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Workspace-relative path"]
          ],
          "required": ["path"],
        ],
      ],
    ],
    [
      "type": "function",
      "function": [
        "name": "list_files",
        "description": "List files and folders at a workspace-relative path.",
        "parameters": [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Workspace-relative path; defaults to root"]
          ],
        ],
      ],
    ],
    [
      "type": "function",
      "function": [
        "name": "search_workspace",
        "description": "Search workspace text files with a regular expression.",
        "parameters": [
          "type": "object",
          "properties": [
            "pattern": ["type": "string", "description": "Regular expression"]
          ],
          "required": ["pattern"],
        ],
      ],
    ],
    [
      "type": "function",
      "function": [
        "name": "write_file",
        "description":
          "Replace a UTF-8 file inside the workspace. Requires user approval and refuses to overwrite a file that changed on disk.",
        "parameters": [
          "type": "object",
          "properties": [
            "path": ["type": "string", "description": "Workspace-relative path"],
            "content": ["type": "string", "description": "Full new file content"],
          ],
          "required": ["path", "content"],
        ],
      ],
    ],
    [
      "type": "function",
      "function": [
        "name": "run_command",
        "description":
          "Run a shell command in the workspace root. Requires user approval; output is captured.",
        "parameters": [
          "type": "object",
          "properties": [
            "command": ["type": "string", "description": "Command line"]
          ],
          "required": ["command"],
        ],
      ],
    ],
  ]
}
