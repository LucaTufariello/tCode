import AppKit
import SwiftUI
import TCodeCore
import UniformTypeIdentifiers

/// In-app marketplace for declarative packs. Language and tool packs are installable today;
/// themes and snippets use the same signed manifest path and are shown as the next categories.
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
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Marketplace").font(.title2).fontWeight(.semibold)
        Spacer()
        Button("Refresh", action: environment.refreshCatalog)
          .help("Download the curated catalog. This does not install or start tools.")
      }
      HStack(alignment: .top, spacing: 0) {
        List(selection: $category) {
          ForEach(categories, id: \.self) { name in
            Label(name, systemImage: symbol(for: name)).tag(name)
          }
        }
        .listStyle(.sidebar)
        .frame(width: 160)
        Divider()
        Group {
          if category == "Languages" {
            languages
          } else if category == "Tools" {
            tools
          } else if category == "Themes" {
            themesView
          } else {
            snippetsView
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      if let operation = environment.operation {
        HStack {
          ProgressView(value: environment.operationFraction).frame(width: 90)
          Text(operation).font(.caption).lineLimit(2)
          Spacer()
          Button("Cancel", action: environment.cancel)
        }
      }
      if let message = environment.message {
        HStack(alignment: .top) {
          Text(message).font(.caption).textSelection(.enabled)
          Spacer()
          Button(action: environment.dismissMessage) { Image(systemName: "xmark.circle") }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      }
      if !environment.issues.isEmpty {
        Text(environment.issues.joined(separator: "\n"))
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
      }
      Text(
        "Marketplace packs are reviewed, hashed downloads. Installing a pack never starts a tool or runs project code."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(10)
    .task {
      environment.reload()
      await environment.loadCachedCatalog()
    }
  }

  private var languages: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Search languages", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 280)
      HStack(alignment: .top, spacing: 0) {
        List(selection: $selection) {
          ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 3) {
              Text(entry.name)
              Text(environment.packs.contains { $0.id == entry.id } ? "Installed" : "Available")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(entry.id)
          }
        }
        .listStyle(.sidebar)
        .frame(width: 190)
        Divider()
        ScrollView {
          if let entry = selectedEntry {
            languageDetail(entry)
          } else {
            ContentUnavailableView(
              "No Language Selected", systemImage: "curlybraces",
              description: Text("Choose a language pack to inspect it."))
          }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private func languageDetail(_ entry: LanguageCatalogEntry) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(entry.name).font(.title2).fontWeight(.semibold)
        Spacer()
        Text(entry.availability.rawValue.capitalized)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(entry.summary).foregroundStyle(.secondary)
      LabeledContent("Version", value: entry.version)
      LabeledContent(
        "Status",
        value: environment.packs.contains { $0.id == entry.id } ? "Installed" : "Available")
      if let pack = environment.packs.first(where: { $0.id == entry.id }) {
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { pack.enabled }, set: { environment.setEnabled(pack, enabled: $0) })
        )
        .toggleStyle(.switch)
        .controlSize(.small)
      }
      HStack {
        Button(environment.packs.contains { $0.id == entry.id } ? "Reinstall…" : "Install…") {
          environment.prepareInstallation(id: entry.id)
        }
        .disabled(environment.operation != nil)
        if environment.packs.contains(where: { $0.id == entry.id }) {
          Button("Validate") {
            if let pack = environment.packs.first(where: { $0.id == entry.id }) {
              environment.validate(pack)
            }
          }
          .disabled(environment.operation != nil)
        }
      }
      Text(
        "You will review downloads, hashes, prerequisites, destinations, and expected changes before anything is installed."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private var tools: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Tool packs").font(.title2).fontWeight(.semibold)
        Text(
          "Tool recipes are compiled into tCode and installed through reviewed plans. Language Support remains the place to configure existing executables."
        )
        .foregroundStyle(.secondary)
        ForEach(ToolRecipe.curated, id: \.id) { recipe in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(recipe.name).fontWeight(.medium)
              Spacer()
              Text(recipe.version).font(.caption).foregroundStyle(.secondary)
            }
            Text(recipe.guidance).font(.caption).foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
          Divider()
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var selectedTheme: ThemePack? {
    themes.themes.first { $0.id == themeSelection } ?? themes.themes.first
  }

  private var selectedSnippetPack: SnippetPack? {
    snippets.packs.first { $0.id == snippetSelection } ?? snippets.packs.first
  }

  private var themesView: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Themes").font(.title2).fontWeight(.semibold)
        Spacer()
        Button("Import Theme…", action: importTheme)
      }
      HStack(alignment: .top, spacing: 0) {
        List(selection: $themeSelection) {
          ForEach(themes.themes) { pack in
            VStack(alignment: .leading, spacing: 3) {
              Text(pack.name)
              Text(themes.activeID == pack.id ? "Active" : "Available")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(pack.id)
          }
        }
        .listStyle(.sidebar)
        .frame(width: 190)
        Divider()
        ScrollView {
          if let pack = selectedTheme {
            themeDetail(pack)
          } else {
            ContentUnavailableView(
              "No Theme Selected", systemImage: "paintpalette",
              description: Text("Choose a theme pack to inspect it."))
          }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private func themeDetail(_ pack: ThemePack) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(pack.name).font(.title2).fontWeight(.semibold)
        Spacer()
        Text(pack.version).font(.caption).foregroundStyle(.secondary)
      }
      if let author = pack.author, !author.isEmpty {
        Text(author).font(.caption).foregroundStyle(.secondary)
      }
      if let summary = pack.summary, !summary.isEmpty {
        Text(summary).foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        ForEach(ThemeRole.allCases, id: \.self) { role in
          swatch(pack.colors.value(role))
            .help(role.rawValue)
        }
      }
      HStack {
        Button(themes.activeID == pack.id ? "Active" : "Apply") {
          themes.apply(pack)
        }
        .disabled(themes.activeID == pack.id)
        Button("Use Default") { themes.useDefault() }
        if themes.isUserInstalled(pack.id) {
          Button("Remove", role: .destructive) {
            do { try themes.remove(pack) } catch { report(error) }
          }
        }
      }
      Text("Theme packs are data only. They change editor colors; they do not run code.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private var snippetsView: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Snippets").font(.title2).fontWeight(.semibold)
        Spacer()
        Button("Import Snippets…", action: importSnippets)
      }
      HStack(alignment: .top, spacing: 0) {
        List(selection: $snippetSelection) {
          ForEach(snippets.packs) { pack in
            VStack(alignment: .leading, spacing: 3) {
              Text(pack.name)
              Text(pack.languageID).font(.caption).foregroundStyle(.secondary)
            }
            .tag(pack.id)
          }
        }
        .listStyle(.sidebar)
        .frame(width: 190)
        Divider()
        ScrollView {
          if let pack = selectedSnippetPack {
            snippetDetail(pack)
          } else {
            ContentUnavailableView(
              "No Snippet Pack Selected", systemImage: "text.badge.plus",
              description: Text("Choose a snippet pack to inspect it."))
          }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private func snippetDetail(_ pack: SnippetPack) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(pack.name).font(.title2).fontWeight(.semibold)
        Spacer()
        Text(pack.version).font(.caption).foregroundStyle(.secondary)
      }
      LabeledContent("Language", value: pack.languageID)
      if let summary = pack.summary, !summary.isEmpty {
        Text(summary).foregroundStyle(.secondary)
      }
      ForEach(pack.snippets, id: \.name) { snippet in
        VStack(alignment: .leading, spacing: 3) {
          Text(snippet.name).fontWeight(.medium)
          Text(snippet.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(4)
        }
        .padding(.vertical, 3)
        Divider()
      }
      HStack {
        Button("Import Snippets…", action: importSnippets)
        if snippets.isUserInstalled(pack.id) {
          Button("Remove", role: .destructive) {
            do { try snippets.remove(pack) } catch { report(error) }
          }
        }
      }
      Text("Snippet packs merge into Editor → Insert Snippet for their language.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
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

  private func swatch(_ hex: String) -> some View {
    RoundedRectangle(cornerRadius: 3)
      .fill(Color(nsColor: NSColor(themeHex: hex) ?? .textBackgroundColor))
      .frame(width: 20, height: 20)
      .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary, lineWidth: 1))
  }

  private func report(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.runModal()
  }

  private func symbol(for category: String) -> String {
    switch category {
    case "Languages": return "curlybraces"
    case "Tools": return "wrench.and.screwdriver"
    case "Themes": return "paintpalette"
    default: return "text.badge.plus"
    }
  }
}
