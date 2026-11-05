import SwiftUI

struct AgentSettingsView: View {
  @State private var endpoint = AgentSettings.load().endpoint
  @State private var model = AgentSettings.load().model
  @State private var systemPrompt = AgentSettings.load().systemPrompt
  @State private var allowTools = AgentSettings.load().allowTools
  @State private var maxIterations = AgentSettings.load().maxIterations
  @State private var apiKey = AgentSettings.apiKey
  @State private var status = ""

  var body: some View {
    Form {
      Section("Provider") {
        TextField("Endpoint", text: $endpoint, prompt: Text("https://api.openai.com/v1"))
        TextField("Model", text: $model, prompt: Text("gpt-4o-mini"))
        SecureField("API key", text: $apiKey)
        Text("The key is stored in the macOS Keychain, not in the project or UserDefaults.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Agent") {
        Toggle("Allow file writes and commands (each requires approval)", isOn: $allowTools)
        Stepper("Maximum tool steps: \(maxIterations)", value: $maxIterations, in: 1...20)
        Text("The agent runs only when you send a message. It never polls or runs in the background.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("System prompt") {
        TextEditor(text: $systemPrompt)
          .font(.body)
          .frame(minHeight: 110)
      }
      Section {
        HStack {
          Button("Save") { save() }
          Text(status).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .padding()
  }

  private func save() {
    var configuration = AgentConfiguration()
    configuration.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    configuration.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    configuration.systemPrompt = systemPrompt
    configuration.allowTools = allowTools
    configuration.maxIterations = maxIterations
    AgentSettings.save(configuration)
    AgentSettings.setAPIKey(apiKey)
    status = "Saved."
  }
}
