import Foundation

struct AgentConfiguration: Codable, Equatable {
  var endpoint = "https://api.openai.com/v1"
  var model = "gpt-4o-mini"
  var systemPrompt =
    "You are tCode's coding agent. Work inside the open workspace, prefer small focused changes, read files before editing, and explain what you changed. Use tools only when they help; ask before destructive actions."
  var allowTools = true
  var maxIterations = 8
}

enum AgentSettings {
  static let configurationKey = "agent.configuration"
  static let apiKeyAccount = "agent.apiKey"

  static func load() -> AgentConfiguration {
    guard let data = UserDefaults.standard.data(forKey: configurationKey),
      let value = try? JSONDecoder().decode(AgentConfiguration.self, from: data)
    else { return AgentConfiguration() }
    return value
  }

  static func save(_ configuration: AgentConfiguration) {
    guard let data = try? JSONEncoder().encode(configuration) else { return }
    UserDefaults.standard.set(data, forKey: configurationKey)
  }

  static var apiKey: String { Keychain.read(apiKeyAccount) ?? "" }

  static func setAPIKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      Keychain.delete(apiKeyAccount)
    } else {
      Keychain.write(trimmed, account: apiKeyAccount)
    }
  }
}
