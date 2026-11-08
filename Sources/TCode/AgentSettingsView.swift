import SwiftUI

/// Agent configuration in the same control-panel language as the rest of Settings: ruled
/// blocks, squared fields, a square checkbox, and a monospaced readout for saved state.
struct AgentSettingsView: View {
  @State private var endpoint = AgentSettings.load().endpoint
  @State private var model = AgentSettings.load().model
  @State private var systemPrompt = AgentSettings.load().systemPrompt
  @State private var allowTools = AgentSettings.load().allowTools
  @State private var maxIterations = AgentSettings.load().maxIterations
  @State private var apiKey = AgentSettings.apiKey
  @State private var status = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        SettingsHeading("Provider")
        VStack(spacing: 0) {
          SettingsRow("Endpoint") {
            IndustrialTextField(
              text: $endpoint, width: 300, placeholder: "https://api.openai.com/v1")
          }
          SettingsRule()
          SettingsRow("Model") {
            IndustrialTextField(text: $model, width: 220, placeholder: "gpt-4o-mini")
          }
          SettingsRule()
          SettingsRow("API key") {
            IndustrialTextField(
              text: $apiKey, width: 300, placeholder: "Stored in the Keychain", secure: true)
          }
        }
        .overlay(alignment: .top) { SettingsRule() }
        .overlay(alignment: .bottom) { SettingsRule() }
        note("The key is stored in the macOS Keychain, not in the project or UserDefaults.")

        SettingsHeading("Agent")
          .padding(.top, 26)
        VStack(spacing: 0) {
          SettingsRow("Allow file writes and commands (each requires approval)") {
            SquareCheckbox(isOn: $allowTools, label: "Allow file writes and commands")
          }
          SettingsRule()
          SettingsRow("Maximum tool steps") {
            SquareStepper(value: $maxIterations, range: 1...20)
          }
        }
        .overlay(alignment: .top) { SettingsRule() }
        .overlay(alignment: .bottom) { SettingsRule() }
        note("The agent runs only when you send a message. It never polls or runs in the background.")

        SettingsHeading("System prompt")
          .padding(.top, 26)
        IndustrialTextEditor(text: $systemPrompt, height: 132)
          .padding(.bottom, 14)

        HStack(spacing: 12) {
          IndustrialSwiftButton(title: "Save", kind: .primary, action: save)
          Text(status)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
          Spacer(minLength: 0)
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10.5))
      .foregroundStyle(.tertiary)
      .padding(.top, 10)
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
