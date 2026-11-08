import AppKit
import SwiftUI

/// The settings window: a flat control panel rather than a stack of system forms. A ruled
/// rail names the sections; the content pane keeps the same type scale, hairlines, and
/// squared controls as the rest of the chrome.
struct SettingsView: View {
  @ObservedObject private var languageEnvironment = LanguageEnvironment.shared
  @State private var section: SettingsSection = {
    // Temporary visual-check hook.
    SettingsSection(rawValue: ProcessInfo.processInfo.environment["TCODE_SETTINGS_SECTION"] ?? "")
      ?? .general
  }()

  var body: some View {
    HStack(spacing: 0) {
      rail
      Rectangle().fill(Color(nsColor: Style.hairline)).frame(width: 1)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: Style.chrome))
    }
    .background(Color(nsColor: Style.chrome))
    .tint(Color(nsColor: Style.accent))
    .frame(width: 860, height: 620)
    .sheet(item: $languageEnvironment.installation) { request in
      LanguageInstallationView(request: request, environment: languageEnvironment)
    }
  }

  private var rail: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("tCode")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
      ForEach(SettingsSection.allCases) { item in
        Button { section = item } label: {
          HStack(spacing: 9) {
            Image(systemName: item.symbol)
              .font(.system(size: 11, weight: .medium))
              .frame(width: 14)
            Text(item.title)
              .font(.system(size: 12, weight: section == item ? .medium : .regular))
            Spacer(minLength: 0)
          }
          .foregroundStyle(section == item ? Color.primary : Color.secondary)
          .padding(.horizontal, 16)
          .frame(height: 32)
          .background {
            if section == item {
              Color(nsColor: Style.rowSelected)
            } else {
              Color.clear
            }
          }
          .overlay(alignment: .leading) {
            if section == item {
              Rectangle().fill(Color(nsColor: Style.accent)).frame(width: 2)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(section == item ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
    .frame(width: 190)
    .background(Color(nsColor: Style.chrome))
  }

  @ViewBuilder private var content: some View {
    switch section {
    case .general:
      GeneralSettingsView()
    case .language:
      LanguageSupportView().padding(20)
    case .marketplace:
      MarketplaceView().padding(20)
    case .agent:
      AgentSettingsView()
    case .shortcuts:
      ShortcutsView().padding(20)
    }
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case general, language, marketplace, agent, shortcuts
  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: return "General"
    case .language: return "Language Support"
    case .marketplace: return "Marketplace"
    case .agent: return "Agent"
    case .shortcuts: return "Shortcuts"
    }
  }
  var symbol: String {
    switch self {
    case .general: return "gearshape"
    case .language: return "puzzlepiece.extension"
    case .marketplace: return "square.grid.2x2"
    case .agent: return "sparkles"
    case .shortcuts: return "keyboard"
    }
  }
}

// MARK: - General

private struct GeneralSettingsView: View {
  @AppStorage("fontSize") private var fontSize = 13.0
  @AppStorage("indentWidth") private var indentWidth = 4
  @AppStorage("autosave") private var autosave = false
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage("fontName") private var fontName = "SF Mono"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        SettingsHeading("Editor")
        VStack(spacing: 0) {
          SettingsRow("Font size") {
            SquareStepper(value: Binding(
              get: { Int(fontSize) }, set: { fontSize = Double($0) }), range: 10...24)
          }
          SettingsRule()
          SettingsRow("Monospaced font") {
            IndustrialTextField(text: $fontName, width: 170)
          }
          SettingsRule()
          SettingsRow("Indentation") {
            HStack(spacing: 8) {
              SquareStepper(value: $indentWidth, range: 1...8)
              Text("spaces")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
          }
          SettingsRule()
          SettingsRow("Autosave after edits") {
            SquareCheckbox(isOn: $autosave, label: "Autosave after edits")
          }
          SettingsRule()
          SettingsRow("Appearance") {
            SquareSegmented(
              options: [("System", "system"), ("Light", "light"), ("Dark", "dark")],
              selection: $appearance)
              .onChange(of: appearance) { _, value in
                NSApp.appearance =
                  value == "light"
                  ? NSAppearance(named: .aqua)
                  : value == "dark" ? NSAppearance(named: .darkAqua) : nil
              }
          }
        }
        .overlay(alignment: .top) { SettingsRule() }
        .overlay(alignment: .bottom) { SettingsRule() }
        Text(
          "New editor panes use the configured font and indentation. Recovery copies are always enabled."
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.top, 10)

        SettingsHeading("Privacy").padding(.top, 26)
        Text(
          "Editing works offline. tCode has no account, telemetry, or source upload. Language tools run locally when you choose Enable Language Tools in a workspace."
        )
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Shared pieces

/// A squared button for SwiftUI surfaces. Mirrors the AppKit industrial button: a filled
/// signal for the primary action, a ruled face for everything else.
struct IndustrialSwiftButton: View {
  enum Kind { case primary, secondary, quiet }
  let title: String
  var kind: Kind = .secondary
  var action: () -> Void

  @State private var hovered = false
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11.5, weight: kind == .primary ? .semibold : .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, kind == .quiet ? 6 : 12)
        .frame(height: kind == .quiet ? 22 : 26)
        .background {
          RoundedRectangle(cornerRadius: Style.radius)
            .fill(fill)
        }
        .overlay {
          if kind == .secondary || (kind == .primary && !isEnabled) {
            RoundedRectangle(cornerRadius: Style.radius)
              .stroke(Color(nsColor: Style.hairlineStrong), lineWidth: 1)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }

  private var foreground: Color {
    guard isEnabled else { return Color(nsColor: .tertiaryLabelColor) }
    if kind == .primary { return .white }
    return hovered ? .primary : Color(nsColor: .secondaryLabelColor)
  }

  private var fill: Color {
    if kind == .primary {
      return isEnabled ? Color(nsColor: Style.accent) : Color(nsColor: Style.control)
    }
    return hovered && isEnabled && kind != .quiet
      ? Color(nsColor: Style.rowHover) : Color.clear
  }
}

/// A flat, ruled list row used by the settings panes. Selection is a quiet wash with a
/// two-pixel signal bar, matching the file tree and the palette.
struct IndustrialListRow: View {
  let title: String
  let detail: String
  let selected: Bool
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 12, weight: selected ? .medium : .regular))
          .foregroundStyle(selected ? Color.primary : Color(nsColor: .secondaryLabelColor))
          .lineLimit(1)
        Text(detail)
          .font(.system(size: 10.5))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 40)
      .background {
        if selected {
          Color(nsColor: Style.rowSelected)
        } else if hovered {
          Color(nsColor: Style.rowHover)
        } else {
          Color.clear
        }
      }
      .overlay(alignment: .leading) {
        if selected {
          Rectangle().fill(Color(nsColor: Style.accent)).frame(width: 2)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }
}

/// A ruled block for notes and validation output.
struct IndustrialNote: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 10.5))
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color(nsColor: Style.control))
      .overlay {
        RoundedRectangle(cornerRadius: Style.radius)
          .stroke(Color(nsColor: Style.hairline), lineWidth: 1)
      }
  }
}

struct SettingsHeading: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title)
      .font(.system(size: 10, weight: .semibold))
      .tracking(0.9)
      .textCase(.uppercase)
      .foregroundStyle(.tertiary)
      .padding(.bottom, 8)
  }
}

struct SettingsRule: View {
  var body: some View {
    Rectangle()
      .fill(Color(nsColor: Style.hairline))
      .frame(height: 1)
  }
}

struct SettingsRow<Control: View>: View {
  let title: String
  @ViewBuilder let control: Control

  init(_ title: String, @ViewBuilder control: () -> Control) {
    self.title = title
    self.control = control()
  }

  var body: some View {
    HStack(spacing: 24) {
      Text(title)
        .font(.system(size: 12))
        .foregroundStyle(.primary)
      Spacer(minLength: 0)
      control
    }
    .padding(.horizontal, 14)
    .frame(height: 44)
  }
}

/// A squared stepper: two ruled buttons around a tabular readout.
struct SquareStepper: View {
  @Binding var value: Int
  let range: ClosedRange<Int>

  var body: some View {
    HStack(spacing: 0) {
      step("minus", enabled: value > range.lowerBound) { value -= 1 }
      Text("\(value)")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.primary)
        .frame(width: 34)
      step("plus", enabled: value < range.upperBound) { value += 1 }
    }
    .overlay {
      RoundedRectangle(cornerRadius: Style.radius)
        .stroke(Color(nsColor: Style.hairlineStrong), lineWidth: 1)
    }
  }

  private func step(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(enabled ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: .tertiaryLabelColor))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}

/// A square check box. The switch is the one rounded control the industrial language avoids.
struct SquareCheckbox: View {
  @Binding var isOn: Bool
  var label = "Toggle"

  var body: some View {
    Button { isOn.toggle() } label: {
      ZStack {
        RoundedRectangle(cornerRadius: 2)
          .fill(isOn ? Color(nsColor: Style.accent) : Color(nsColor: Style.control))
        RoundedRectangle(cornerRadius: 2)
          .stroke(
            isOn ? Color(nsColor: Style.accent) : Color(nsColor: Style.hairlineStrong),
            lineWidth: 1)
        if isOn {
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: 16, height: 16)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// A flat segmented control with a signal underline on the selected segment.
struct SquareSegmented: View {
  let options: [(String, String)]
  @Binding var selection: String
  var segmentWidth: CGFloat = 58

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.1) { label, value in
        Button { selection = value } label: {
          Text(label)
            .font(.system(size: 11, weight: selection == value ? .medium : .regular))
            .foregroundStyle(selection == value ? Color.primary : Color.secondary)
            .frame(width: segmentWidth, height: 24)
            .background {
              if selection == value {
                Color(nsColor: Style.rowSelected)
              } else {
                Color.clear
              }
            }
            .overlay(alignment: .bottom) {
              if selection == value {
                Rectangle().fill(Color(nsColor: Style.accent)).frame(height: 2)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: Style.radius)
        .stroke(Color(nsColor: Style.hairlineStrong), lineWidth: 1)
    }
  }
}

/// A plain text field in a squared well.
struct IndustrialTextField: View {
  @Binding var text: String
  var width: CGFloat = 170
  var placeholder = ""
  var secure = false
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if secure {
        SecureField("", text: $text, prompt: Text(placeholder))
      } else {
        TextField("", text: $text, prompt: Text(placeholder))
      }
    }
    .textFieldStyle(.plain)
    .focused($focused)
    .focusEffectDisabled()
    .font(.system(size: 11.5, design: .monospaced))
    .padding(.horizontal, 8)
    .frame(width: width, height: 26)
    .background {
      RoundedRectangle(cornerRadius: Style.radius)
        .fill(Color(nsColor: Style.control))
    }
    .overlay {
      RoundedRectangle(cornerRadius: Style.radius)
        .stroke(
          focused ? Color(nsColor: Style.accent) : Color(nsColor: Style.hairlineStrong),
          lineWidth: 1)
    }
  }
}

/// A flat filter well: magnifier, borderless field, squared control surface.
struct IndustrialSearchField: View {
  @Binding var text: String
  var placeholder = "Search"
  var width: CGFloat = 220
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
      TextField("", text: $text, prompt: Text(placeholder))
        .textFieldStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .font(.system(size: 11.5))
    }
    .padding(.horizontal, 8)
    .frame(width: width, height: 26)
    .background {
      RoundedRectangle(cornerRadius: Style.radius)
        .fill(Color(nsColor: Style.control))
    }
    .overlay {
      RoundedRectangle(cornerRadius: Style.radius)
        .stroke(
          focused ? Color(nsColor: Style.accent) : Color(nsColor: Style.hairlineStrong),
          lineWidth: 1)
    }
  }
}

/// A flat horizontal tab bar: tracked labels on a ruled band, a signal underline on the
/// active segment. Used by the marketplace categories.
struct IndustrialTabBar: View {
  let options: [(String, String)]
  @Binding var selection: String

  var body: some View {
    HStack(spacing: 22) {
      ForEach(options, id: \.1) { label, value in
        Button { selection = value } label: {
          VStack(spacing: 0) {
            Text(label)
              .font(.system(size: 10, weight: .semibold))
              .tracking(0.9)
              .textCase(.uppercase)
              .foregroundStyle(
                selection == value
                  ? Color.primary : Color(nsColor: .tertiaryLabelColor))
              .padding(.vertical, 9)
            Rectangle()
              .fill(
                selection == value ? Color(nsColor: Style.accent) : Color.clear
              )
              .frame(height: 2)
          }
          .fixedSize(horizontal: true, vertical: false)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .background(Color(nsColor: Style.chrome))
    .overlay(alignment: .bottom) { SettingsRule() }
  }
}

/// A two-pixel progress track for long operations.
struct IndustrialProgressBar: View {
  let fraction: Double
  var width: CGFloat = 90

  var body: some View {
    ZStack(alignment: .leading) {
      Rectangle().fill(Color(nsColor: Style.hairline)).frame(width: width, height: 2)
      Rectangle()
        .fill(Color(nsColor: Style.accent))
        .frame(width: width * min(max(fraction, 0), 1), height: 2)
    }
    .frame(width: width, height: 2)
  }
}

/// A flat menu button: a ruled face with a title and a chevron. Replaces the system popup
/// button in SwiftUI surfaces.
struct IndustrialMenuButton<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    Menu {
      content
    } label: {
      HStack(spacing: 5) {
        Text(title).font(.system(size: 11.5, weight: .medium))
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .foregroundStyle(Color(nsColor: .secondaryLabelColor))
      .padding(.horizontal, 12)
      .frame(height: 26)
      .overlay {
        RoundedRectangle(cornerRadius: Style.radius)
          .stroke(Color(nsColor: Style.hairlineStrong), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .tint(Color(nsColor: .secondaryLabelColor))
    .fixedSize()
  }
}

/// A flat multiline editor in a squared well.
struct IndustrialTextEditor: View {
  @Binding var text: String
  var height: CGFloat = 120
  var monospaced = false

  var body: some View {
    TextEditor(text: $text)
      .font(
        monospaced
          ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
      .scrollContentBackground(.hidden)
      .focusEffectDisabled()
      .padding(6)
      .frame(height: height)
      .background {
        RoundedRectangle(cornerRadius: Style.radius)
          .fill(Color(nsColor: Style.control))
      }
      .overlay {
        RoundedRectangle(cornerRadius: Style.radius)
          .stroke(Color(nsColor: Style.hairlineStrong), lineWidth: 1)
      }
  }
}

/// A ruled label/value row for detail panes. Values are readouts, not prose.
struct IndustrialKeyValue: View {
  let label: String
  let value: String
  var mono = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .frame(width: 92, alignment: .leading)
      Text(value)
        .font(
          mono
            ? .system(size: 10.5, design: .monospaced) : .system(size: 11.5))
        .foregroundStyle(mono ? Color.secondary : Color.primary)
        .textSelection(.enabled)
        .lineLimit(2)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .frame(height: 24)
  }
}
