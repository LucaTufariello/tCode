import AppKit
import SwiftUI
import TCodeCore
import UniformTypeIdentifiers

/// In-app marketplace for declarative packs. The browser keeps the same industrial language as
/// the rest of the chrome: a ruled category band, a flat search well, a two-column list/detail
/// split, squared toggles, and one signal accent. No stock sidebar list, rounded search field,
/// or pill switch appears here.
struct MarketplaceView: View {
  @ObservedObject private var environment = LanguageEnvironment.shared
  @ObservedObject private var themes = ThemeStore.shared
  @ObservedObject private var snippets = SnippetStore.shared
  @State private var category = "Languages"
  @State private var selection: String?
  @State private var themeSelection: String?
  @State private var snippetSelection: String?
  @State private var query = ""

  private let categories = ["Languages", "Tools", "Themes", "Snippets"]

  private var entries: [LanguageCatalogEntry] {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { return environment.catalog }
    return environment.catalog.filter {
      $0.name.lowercased().contains(value) || $0.summary.lowercased().contains(value)
    }
  }

  private var selectedEntry: LanguageCatalogEntry? {
    entries.first { $0.id == selection } ?? entries.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      IndustrialTabBar(
        options: categories.map { ($0, $0) }, selection: $category)
      Group {
        switch category {
        case "Languages": languages
        case "Tools": tools
        case "Themes": themesView
        default: snippetsView
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      status
      footer
    }
    .tint(Color(nsColor: Style.accent))
    .task {
      environment.reload()
      await environment.loadCachedCatalog()
    }
  }

  // MARK: - Frame

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Marketplace")
        .font(.system(size: 15, weight: .semibold))
      Spacer()
      IndustrialSwiftButton(title: "Refresh", action: environment.refreshCatalog)
        .help("Download the curated catalog. This does not install or start tools.")
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }

  @ViewBuilder private var status: some View {
    if let operation = environment.operation {
      HStack(spacing: 10) {
        IndustrialProgressBar(fraction: environment.operationFraction)
        Text(operation)
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
        IndustrialSwiftButton(title: "Cancel", action: environment.cancel)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    if let message = environment.message {
      HStack(alignment: .top, spacing: 10) {
        Text(message)
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button(action: environment.dismissMessage) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss message")
      }
      .padding(10)
      .background(Color(nsColor: Style.control))
      .overlay {
        RoundedRectangle(cornerRadius: Style.radius)
          .stroke(Color(nsColor: Style.hairline), lineWidth: 1)
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 8)
    }
    if !environment.issues.isEmpty {
      Text(environment.issues.joined(separator: "\n"))
        .font(.system(size: 10.5))
        .foregroundStyle(.orange)
        .lineLimit(3)
        .help(environment.issues.joined(separator: "\n"))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
  }

  private var footer: some View {
    Text(
      "Marketplace packs are reviewed, hashed downloads. Installing a pack never starts a tool or runs project code."
    )
    .font(.system(size: 10.5))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  /// The shared browser frame: a fixed list column, a hairline, and a scrolling detail pane.
  private func browser<List: View, Detail: View>(
    @ViewBuilder list: () -> List, @ViewBuilder detail: () -> Detail
  ) -> some View {
    HStack(alignment: .top, spacing: 0) {
      list()
        .frame(width: 210)
      Rectangle()
        .fill(Color(nsColor: Style.hairline))
        .frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          detail()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxHeight: .infinity)
  }

  private func rows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) { content() }
    }
  }

  // MARK: - Languages

  private var languages: some View {
    browser {
      VStack(spacing: 0) {
        IndustrialSearchField(
          text: $query, placeholder: "Search languages", width: 186)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
        SettingsRule()
        rows {
          ForEach(entries) { entry in
            IndustrialListRow(
              title: entry.name,
              detail: environment.packs.contains { $0.id == entry.id }
                ? "Installed" : "Available",
              selected: selectedEntry?.id == entry.id
            ) { selection = entry.id }
          }
        }
      }
    } detail: {
      if let entry = selectedEntry {
        languageDetail(entry)
      } else {
        emptyDetail("No Language Selected", "Choose a language pack to inspect it.")
      }
    }
    .disabled(environment.operation != nil)
  }

  @ViewBuilder private func languageDetail(_ entry: LanguageCatalogEntry) -> some View {
    detailHeader(entry.name, status: entry.availability.rawValue)
    Text(entry.summary)
      .font(.system(size: 11.5))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    VStack(spacing: 0) {
      IndustrialKeyValue(label: "Version", value: entry.version, mono: true)
      SettingsRule()
      IndustrialKeyValue(
        label: "Status",
        value: environment.packs.contains { $0.id == entry.id } ? "Installed" : "Available")
      if let pack = environment.packs.first(where: { $0.id == entry.id }) {
        SettingsRule()
        HStack {
          Text("Enabled")
            .font(.system(size: 11.5))
          Spacer()
          SquareCheckbox(
            isOn: Binding(
              get: { pack.enabled }, set: { environment.setEnabled(pack, enabled: $0) }),
            label: "Enable \(pack.name)")
        }
        .frame(height: 34)
      }
    }
    .padding(.top, 2)
    HStack(spacing: 8) {
      IndustrialSwiftButton(
        title: environment.packs.contains { $0.id == entry.id } ? "Reinstall…" : "Install…",
        kind: .primary
      ) {
        environment.prepareInstallation(id: entry.id)
      }
      .disabled(environment.operation != nil)
      if environment.packs.contains(where: { $0.id == entry.id }) {
        IndustrialSwiftButton(title: "Validate") {
          if let pack = environment.packs.first(where: { $0.id == entry.id }) {
            environment.validate(pack)
          }
        }
        .disabled(environment.operation != nil)
      }
    }
    detailNote(
      "You will review downloads, hashes, prerequisites, destinations, and expected changes before anything is installed."
    )
  }

  // MARK: - Tools

  private var selectedRecipe: ToolRecipe? {
    ToolRecipe.curated.first { $0.id == selection } ?? ToolRecipe.curated.first
  }

  private var tools: some View {
    browser {
      rows {
        ForEach(ToolRecipe.curated, id: \.id) { recipe in
          IndustrialListRow(
            title: recipe.name, detail: recipe.version,
            selected: selectedRecipe?.id == recipe.id
          ) { selection = recipe.id }
        }
      }
    } detail: {
      if let recipe = selectedRecipe {
        detailHeader(recipe.name, status: recipe.kind.rawValue)
        Text(recipe.guidance)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
          IndustrialKeyValue(label: "Version", value: recipe.version, mono: true)
          SettingsRule()
          IndustrialKeyValue(label: "Kind", value: recipe.kind.rawValue)
          SettingsRule()
          IndustrialKeyValue(
            label: "Downloads", value: "\(recipe.downloads.count)", mono: true)
          if !recipe.prerequisiteTools.isEmpty {
            SettingsRule()
            IndustrialKeyValue(
              label: "Requires",
              value: recipe.prerequisiteTools.joined(separator: ", "), mono: true)
          }
        }
        .padding(.top, 2)
        detailNote(
          "Tool recipes are compiled into tCode and installed through reviewed plans. Language Support remains the place to configure existing executables."
        )
      }
    }
  }

  // MARK: - Themes

  private var selectedTheme: ThemePack? {
    themes.themes.first { $0.id == themeSelection } ?? themes.themes.first
  }

  private var themesView: some View {
    browser {
      rows {
        ForEach(themes.themes) { pack in
          IndustrialListRow(
            title: pack.name,
            detail: themes.activeID == pack.id ? "Active" : "Available",
            selected: selectedTheme?.id == pack.id
          ) { themeSelection = pack.id }
        }
      }
    } detail: {
      if let pack = selectedTheme {
        themeDetail(pack)
      } else {
        emptyDetail("No Theme Selected", "Choose a theme pack to inspect it.")
      }
    }
  }

  @ViewBuilder private func themeDetail(_ pack: ThemePack) -> some View {
    detailHeader(pack.name, status: pack.version)
    if let author = pack.author, !author.isEmpty {
      Text(author)
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
    }
    if let summary = pack.summary, !summary.isEmpty {
      Text(summary)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    HStack(spacing: 6) {
      ForEach(ThemeRole.allCases, id: \.self) { role in
        swatch(pack.colors.value(role))
          .help(role.rawValue)
      }
    }
    .padding(.vertical, 2)
    HStack(spacing: 8) {
      IndustrialSwiftButton(
        title: themes.activeID == pack.id ? "Active" : "Apply",
        kind: themes.activeID == pack.id ? .secondary : .primary
      ) {
        themes.apply(pack)
      }
      .disabled(themes.activeID == pack.id)
      IndustrialSwiftButton(title: "Use Default") { themes.useDefault() }
      IndustrialSwiftButton(title: "Import Theme…", action: importTheme)
      if themes.isUserInstalled(pack.id) {
        IndustrialSwiftButton(title: "Remove") {
          do { try themes.remove(pack) } catch { report(error) }
        }
      }
    }
    detailNote("Theme packs are data only. They change editor colors; they do not run code.")
  }

  // MARK: - Snippets

  private var selectedSnippetPack: SnippetPack? {
    snippets.packs.first { $0.id == snippetSelection } ?? snippets.packs.first
  }

  private var snippetsView: some View {
    browser {
      rows {
        ForEach(snippets.packs) { pack in
          IndustrialListRow(
            title: pack.name, detail: pack.languageID,
            selected: selectedSnippetPack?.id == pack.id
          ) { snippetSelection = pack.id }
        }
      }
    } detail: {
      if let pack = selectedSnippetPack {
        snippetDetail(pack)
      } else {
        emptyDetail("No Snippet Pack Selected", "Choose a snippet pack to inspect it.")
      }
    }
  }

  @ViewBuilder private func snippetDetail(_ pack: SnippetPack) -> some View {
    detailHeader(pack.name, status: pack.version)
    VStack(spacing: 0) {
      IndustrialKeyValue(label: "Language", value: pack.languageID, mono: true)
      if let summary = pack.summary, !summary.isEmpty {
        SettingsRule()
        IndustrialKeyValue(label: "Summary", value: summary)
      }
    }
    if !pack.snippets.isEmpty {
      SettingsHeading("Snippets")
        .padding(.top, 10)
      VStack(spacing: 0) {
        SettingsRule()
        ForEach(pack.snippets, id: \.name) { snippet in
          VStack(alignment: .leading, spacing: 3) {
            Text(snippet.name)
              .font(.system(size: 11.5, weight: .medium))
            Text(snippet.text)
              .font(.system(size: 10.5, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(4)
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 7)
          SettingsRule()
        }
      }
    }
    HStack(spacing: 8) {
      IndustrialSwiftButton(title: "Import Snippets…", action: importSnippets)
      if snippets.isUserInstalled(pack.id) {
        IndustrialSwiftButton(title: "Remove") {
          do { try snippets.remove(pack) } catch { report(error) }
        }
      }
    }
    .padding(.top, 4)
    detailNote("Snippet packs merge into Editor → Insert Snippet for their language.")
  }

  // MARK: - Pieces

  private func detailHeader(_ title: String, status: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
      Spacer(minLength: 0)
      Text(status.uppercased())
        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        .tracking(0.7)
        .foregroundStyle(.tertiary)
    }
  }

  private func detailNote(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10.5))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 2)
  }

  private func emptyDetail(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(systemName: "square.grid.2x2")
        .font(.system(size: 18, weight: .light))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.system(size: 13, weight: .medium))
      Text(detail)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .padding(.top, 8)
  }

  private func swatch(_ hex: String) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(Color(nsColor: NSColor(themeHex: hex) ?? .textBackgroundColor))
      .frame(width: 22, height: 22)
      .overlay {
        RoundedRectangle(cornerRadius: 2)
          .stroke(Color(nsColor: Style.hairlineStrong), lineWidth: 1)
      }
  }

  private func importTheme() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let pack = try themes.importPack(from: url)
      themeSelection = pack.id
    } catch { report(error) }
  }

  private func importSnippets() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let pack = try snippets.importPack(from: url)
      snippetSelection = pack.id
    } catch { report(error) }
  }

  private func report(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.runModal()
  }
}
