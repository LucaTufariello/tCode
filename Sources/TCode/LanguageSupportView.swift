import AppKit
import Combine
import SwiftUI
import TCodeCore
import UniformTypeIdentifiers

/// Shared registry state. Merely loading this object reads configuration; it never starts a tool.
@MainActor final class LanguageEnvironment: ObservableObject {
  static let shared = LanguageEnvironment()
  let registry: LanguagePackRegistry
  @Published private(set) var packs: [LanguagePack] = []
  @Published private(set) var issues: [String] = []
  @Published private(set) var catalog: [LanguageCatalogEntry] = []
  @Published private(set) var catalogStatus =
    "Bundled catalog · refresh to check for published updates"
  @Published private(set) var operation: String?
  @Published private(set) var operationFraction: Double = 0
  @Published private(set) var message: String?
  @Published private(set) var validation: [String: [String]] = [:]
  @Published var installation: LanguageInstallationRequest?
  @Published var removal: LanguageRemovalRequest?
  private let catalogStore: LanguageCatalogStore
  private let installer: ToolInstaller
  private(set) var grammarInstaller: SyntaxGrammarInstaller
  private(set) var grammarArtifacts: [SyntaxGrammarArtifact]
  private let bundledGrammarArtifacts: [SyntaxGrammarArtifact]
  private var cachedCatalogLoaded = false
  @Published private(set) var installedGrammarIDs = Set<String>()
  @Published private(set) var activeGrammarIDs = Set<String>()
  private var task: Task<Void, Never>?
  private var operationToken = UUID()

  init() {
    registry = LanguagePackRegistry(bundledPacks: LanguagePack.bundled())
    catalogStore = LanguageCatalogStore()
    installer = ToolInstaller(directory: ToolInstaller.defaultDirectory)
    let resourceFolder = Bundle.module.url(forResource: "Resources", withExtension: nil)
    grammarArtifacts =
      resourceFolder.flatMap {
        try? Data(contentsOf: $0.appendingPathComponent("Syntax/grammars.json"))
      }
      .flatMap { try? JSONDecoder().decode([SyntaxGrammarArtifact].self, from: $0) } ?? []
    bundledGrammarArtifacts = grammarArtifacts
    grammarInstaller = SyntaxGrammarInstaller(artifacts: grammarArtifacts)
    packs = registry.reload()
    issues = registry.issues.map(\.message)
    catalog = LanguageCatalog.starter.entries
    // Loading a trusted cached catalog keeps newly added languages available after restart, offline.
    Task { await loadCachedCatalog() }
  }

  func reload() {
    packs = registry.reload()
    issues = registry.issues.map(\.message)
  }

  private func changed() {
    reload()
    NotificationCenter.default.post(name: .tcodeToolSettingsChanged, object: nil)
  }

  func loadCachedCatalog() async {
    guard !cachedCatalogLoaded else { return }
    cachedCatalogLoaded = true
    do {
      let cached = try await catalogStore.cached()
      try await applyCatalog(cached)
      catalogStatus = cached.publication
    } catch {
      catalogStatus = "Bundled catalog · \(error.localizedDescription)"
    }
  }

  private func applyCatalog(_ value: LanguageCatalog) async throws {
    try value.validate()
    var byID = Dictionary(
      bundledGrammarArtifacts.map { ($0.descriptor.id, $0) },
      uniquingKeysWith: { first, _ in first })
    for artifact in value.grammarArtifacts { byID[artifact.descriptor.id] = artifact }
    grammarArtifacts = byID.values.sorted { $0.descriptor.id < $1.descriptor.id }
    grammarInstaller = SyntaxGrammarInstaller(artifacts: grammarArtifacts)
    catalog = value.entries
    await SyntaxClient.shared.configure(artifacts: grammarArtifacts)
    await refreshGrammarStatus()
  }

  func refreshGrammarStatus() async {
    let installer = grammarInstaller
    let status = await Task.detached(priority: .utility) {
      let current = Set(
        installer.artifacts.filter { installer.installed($0.descriptor.id) }.map {
          $0.descriptor.id
        })
      var active = current
      for artifact in installer.artifacts where !current.contains(artifact.descriptor.id) {
        if let descriptor = try? SyntaxGrammarStore.activatedDescriptor(
          id: artifact.descriptor.id, root: installer.root),
          (try? SyntaxGrammarStore.read(descriptor, root: installer.root)) != nil
        {
          active.insert(artifact.descriptor.id)
        }
      }
      return (current, active)
    }.value
    installedGrammarIDs = status.0
    activeGrammarIDs = status.1
  }

  func refreshCatalog() {
    guard task == nil else { return }
    operation = "Refreshing catalog…"
    task = Task {
      defer {
        operation = nil
        task = nil
      }
      do {
        let refreshed = try await catalogStore.refresh()
        try await applyCatalog(refreshed)
        catalogStatus = refreshed.publication + " · cached for offline browsing"
        message = nil
      } catch {
        message =
          "Catalog refresh failed. Installed support remains available. \(error.localizedDescription)"
      }
    }
  }

  func setEnabled(_ pack: LanguagePack, enabled: Bool) {
    UserDefaults.standard.set(!enabled, forKey: "disabled." + pack.id)
    changed()
  }

  func importPack(_ url: URL) {
    guard task == nil else { return }
    operation = "Importing configuration…"
    task = Task {
      defer {
        operation = nil
        task = nil
      }
      do {
        let bytes = try await Background.run {
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= 1_048_576 else {
            throw TCodeError.message("Language pack exceeds the 1 MB configuration limit.")
          }
          return try Data(contentsOf: url)
        }
        try Task.checkCancellation()
        let preview = try LanguagePackRegistry.decode(bytes)
        let replacing = registry.isUserInstalled(id: preview.id)
        if replacing {
          let alert = NSAlert()
          alert.messageText = "Replace \(preview.name) configuration?"
          alert.informativeText =
            "The current installed configuration will be replaced. Importing does not install or start tools."
          alert.addButton(withTitle: "Replace")
          alert.addButton(withTitle: "Cancel")
          guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let pack = try registry.importPack(data: bytes, replace: replacing)
        changed()
        message =
          "Imported \(pack.name). No tools were installed or started. Enable tools explicitly in a workspace when ready."
      } catch { message = error.localizedDescription }
    }
  }

  func exportPack(_ pack: LanguagePack, to url: URL) {
    do {
      let bytes = try registry.exportPack(id: pack.id)
      try bytes.write(to: url, options: .atomic)
      message =
        "Exported \(pack.name) configuration without installed tools or machine-specific paths."
    } catch { message = error.localizedDescription }
  }

  func removePack(_ pack: LanguagePack) {
    do {
      try registry.removePack(id: pack.id)
      validation.removeValue(forKey: pack.id)
      changed()
      message = "Removed the installed \(pack.name) configuration. Existing tools were retained."
    } catch { message = error.localizedDescription }
  }

  func validate(_ pack: LanguagePack) {
    guard task == nil else { return }
    operation = "Validating \(pack.name)…"
    task = Task {
      defer {
        operation = nil
        task = nil
      }
      var results: [String] = []
      let names = Self.toolNames(pack)
      for name in names {
        if Task.isCancelled { return }
        guard let path = ToolLocator.find(name) else {
          results.append("\(name): missing. Install support or configure an existing executable.")
          continue
        }
        let report = await ToolHealth.check(executable: path)
        if name == "sourcekit-lsp", !report.isHealthy {
          let help = await ToolHealth.check(executable: path, arguments: ["--help"])
          if help.isHealthy {
            results.append(
              "sourcekit-lsp: available · this Xcode build responds to --help, but does not expose --version. Connect in a workspace to validate code intelligence."
            )
            continue
          }
        }
        results.append(
          "\(name): \(report.isHealthy ? "healthy" : "failed") · \(report.version ?? report.detail)"
        )
      }
      if names.isEmpty {
        results.append("This pack provides editing support without external tools.")
      }
      if Task.isCancelled { return }
      validation[pack.id] = results
    }
  }

  func prepareInstallation(id: String, update: Bool = false) {
    guard task == nil, let entry = catalog.first(where: { $0.id == id }) else { return }
    operation = "Preparing \(entry.name) installation plan…"
    task = Task {
      defer {
        operation = nil
        task = nil
      }
      do {
        try Task.checkCancellation()
        var plans: [ToolInstallPlan] = []
        var planIssues: [String] = []
        for recipe in entry.toolRecipeIDs {
          try Task.checkCancellation()
          do { plans.append(try await installer.plan(recipeID: recipe)) } catch {
            planIssues.append(error.localizedDescription)
          }
        }
        var grammarPlan: SyntaxGrammarInstallPlan?
        var grammarIssue: String?
        do { grammarPlan = try grammarInstaller.plan(ids: entry.grammarArtifactIDs) } catch {
          grammarIssue = error.localizedDescription
        }
        installation = LanguageInstallationRequest(
          entry: entry, plans: plans, update: update,
          grammarPlan: grammarPlan, grammarIssue: grammarIssue, planIssues: planIssues)
      } catch is CancellationError {
        message = "Installation planning cancelled."
      } catch { message = error.localizedDescription }
    }
  }

  func install(
    _ request: LanguageInstallationRequest, recipeIDs: Set<String> = [],
    includeGrammars: Bool = false
  ) {
    guard task == nil else { return }
    installation = nil
    operationFraction = 0
    operation = "Installing \(request.entry.name)…"
    let token = UUID()
    operationToken = token
    task = Task {
      defer {
        operation = nil
        operationFraction = 0
        task = nil
      }
      do {
        let data: Data
        if let folder = Bundle.module.url(forResource: "Resources", withExtension: nil),
          let bundled = try LanguageCatalogStore.bundledPack(
            entry: request.entry, resourceDirectory: folder)
        {
          data = bundled
        } else {
          data = try await catalogStore.fetchPack(entry: request.entry)
        }
        // Validate configuration before making any changes. Registry import performs the same validation again.
        _ = try LanguagePackRegistry.decode(data)
        let selected = request.plans.filter { recipeIDs.contains($0.id) }
        for (index, plan) in selected.enumerated() {
          try Task.checkCancellation()
          _ = try await installer.install(plan, approval: { _ in true }) { [weak self] progress in
            Task { @MainActor in
              guard self?.operationToken == token, self?.task?.isCancelled == false else { return }
              self?.operation = progress.message
              self?.operationFraction =
                (Double(index) + progress.fraction) / Double(max(1, selected.count))
            }
          }
        }
        try Task.checkCancellation()
        if includeGrammars, let plan = request.grammarPlan {
          try await grammarInstaller.install(plan) { [weak self] text in
            Task { @MainActor in
              guard self?.operationToken == token, self?.task?.isCancelled == false else { return }
              self?.operation = text
            }
          }
          await SyntaxClient.shared.configure(artifacts: grammarArtifacts)
          await refreshGrammarStatus()
        }
        try Task.checkCancellation()
        let pack = try registry.importPack(
          data: data, replace: request.update || registry.isUserInstalled(id: request.entry.id))
        changed()
        message =
          !recipeIDs.isEmpty || includeGrammars
          ? "Installed \(pack.name). Enable Language Tools in the workspace to start its server."
          : "Installed \(pack.name) configuration only. Tool and grammar downloads were skipped; configure existing tools or install them when ready."
      } catch is CancellationError {
        message = "Installation cancelled. Previously active versions remain available."
      } catch { message = error.localizedDescription }
    }
  }

  func prepareRemoval(_ pack: LanguagePack) {
    guard task == nil else { return }
    operation = "Reviewing managed downloads…"
    task = Task {
      defer {
        operation = nil
        task = nil
      }
      do {
        let ids = Set(
          pack.toolRecipeIDs + (catalog.first { $0.id == pack.id }?.toolRecipeIDs ?? []))
        let receipts = try await installer.receipts().filter { ids.contains($0.recipeID) }
        let owned = receipts.filter { receipt in
          guard receipt.owned, let path = receipt.managedDirectory else { return false }
          return ToolInstaller.isDescendant(
            URL(fileURLWithPath: path),
            of: ToolInstaller.defaultDirectory.appendingPathComponent("versions"))
        }
        await refreshGrammarStatus()
        let grammars = pack.grammarIDs.filter { activeGrammarIDs.contains($0) }
        guard !owned.isEmpty || !grammars.isEmpty else {
          message =
            "No tCode-owned downloads are installed for \(pack.name). External tools, interpreters, and SDKs are retained."
          return
        }
        let otherPacks = packs.filter { $0.id != pack.id }
        var impacts: [String] = []
        for receipt in owned {
          let shared = otherPacks.filter { other in
            let otherIDs =
              other.toolRecipeIDs + (catalog.first { $0.id == other.id }?.toolRecipeIDs ?? [])
            return otherIDs.contains(receipt.recipeID)
          }
          if !shared.isEmpty {
            impacts.append(
              "\(receipt.recipeID) is also referenced by "
                + shared.map(\.name).joined(separator: ", "))
          }
        }
        for grammar in grammars {
          let shared = otherPacks.filter { $0.grammarIDs.contains(grammar) }
          if !shared.isEmpty {
            impacts.append(
              "\(grammar) grammar is also referenced by "
                + shared.map(\.name).joined(separator: ", "))
          }
        }
        try Task.checkCancellation()
        removal = LanguageRemovalRequest(
          pack: pack, receipts: owned, grammarIDs: grammars,
          externalRecipeIDs: receipts.filter { !$0.owned }.map(\.recipeID), sharedImpact: impacts)
      } catch is CancellationError { message = "Download removal review cancelled." } catch {
        message = error.localizedDescription
      }
    }
  }

  func removeDownloads(
    _ request: LanguageRemovalRequest, recipeIDs: Set<String>, grammarIDs: Set<String>
  ) {
    guard task == nil else { return }
    removal = nil
    operation = "Removing selected managed downloads…"
    task = Task {
      defer {
        operation = nil
        operationFraction = 0
        task = nil
      }
      var removed: [String] = []
      do {
        let expected = request.receipts.filter { recipeIDs.contains($0.recipeID) }
        let current = try await installer.receipts()
        for receipt in expected {
          try Task.checkCancellation()
          guard let fresh = current.first(where: { $0.recipeID == receipt.recipeID }), fresh.owned,
            fresh.managedDirectory == receipt.managedDirectory, fresh.version == receipt.version
          else {
            throw TCodeError.message(
              "The installation changed after review. Open Remove Managed Downloads again to review the current version."
            )
          }
          try await installer.remove(recipeID: receipt.recipeID)
          removed.append(receipt.recipeID)
        }
        let managedGrammarIDs = request.grammarIDs.filter { grammarIDs.contains($0) }
        for id in managedGrammarIDs {
          try Task.checkCancellation()
          try grammarInstaller.remove(id: id)
          removed.append(id + " grammar")
        }
        await SyntaxClient.shared.configure(artifacts: grammarArtifacts)
        await refreshGrammarStatus()
        changed()
        message =
          "Removed " + removed.joined(separator: ", ")
          + ". Configurations and project files were retained."
      } catch {
        await SyntaxClient.shared.configure(artifacts: grammarArtifacts)
        await refreshGrammarStatus()
        changed()
        let prefix =
          removed.isEmpty ? "" : "Already removed: " + removed.joined(separator: ", ") + ". "
        message =
          prefix
          + (error is CancellationError
            ? "Removal cancelled. Remaining downloads were retained." : error.localizedDescription)
      }
    }
  }

  func cancel() { task?.cancel() }
  func dismissMessage() { message = nil }

  static func toolNames(_ pack: LanguagePack) -> [String] {
    Array(
      Set(
        ([pack.server, pack.formatter, pack.adapter]
          + pack.tasks.values.flatMap(\.steps).map(\.executable))
          .filter { !$0.isEmpty && !$0.contains("${") })
    ).sorted()
  }
}

struct LanguageInstallationRequest: Identifiable {
  let id = UUID()
  let entry: LanguageCatalogEntry
  let plans: [ToolInstallPlan]
  let update: Bool
  let grammarPlan: SyntaxGrammarInstallPlan?
  let grammarIssue: String?
  let planIssues: [String]
}

struct LanguageRemovalRequest: Identifiable {
  let id = UUID()
  let pack: LanguagePack
  let receipts: [ToolInstallReceipt]
  let grammarIDs: [String]
  let externalRecipeIDs: [String]
  let sharedImpact: [String]
}

struct LanguageSupportView: View {
  @ObservedObject private var environment = LanguageEnvironment.shared
  @State private var section = "installed"
  @State private var selection: String?
  @State private var configuration: LanguagePack?
  @State private var confirmingRemoval: LanguagePack?

  private var visibleIDs: [String] {
    section == "installed" ? environment.packs.map(\.id) : environment.catalog.map(\.id)
  }
  private var selectedID: String? {
    selection.flatMap { visibleIDs.contains($0) ? $0 : nil } ?? visibleIDs.first
  }
  private var selectedPack: LanguagePack? { environment.packs.first { $0.id == selectedID } }
  private var selectedEntry: LanguageCatalogEntry? {
    environment.catalog.first { $0.id == selectedID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker("Language support", selection: $section) {
          Text("Installed").tag("installed")
          Text("Catalog").tag("catalog")
        }.pickerStyle(.segmented).frame(width: 220)
        Spacer()
        Button("Import…", action: importPack)
        Button("Refresh", action: environment.refreshCatalog)
          .help("Download the curated catalog. This does not install or start tools.")
      }.disabled(environment.operation != nil)
      HStack(alignment: .top, spacing: 0) {
        List(selection: $selection) {
          if section == "installed" {
            ForEach(environment.packs, id: \.id) { pack in
              VStack(alignment: .leading, spacing: 3) {
                Text(pack.name)
                Text(pack.enabled ? "Enabled" : "Disabled").font(.caption).foregroundStyle(
                  .secondary)
              }.tag(pack.id)
            }
          } else {
            ForEach(environment.catalog, id: \.id) { entry in
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                Text(environment.packs.contains { $0.id == entry.id } ? "Installed" : "Available")
                  .font(.caption).foregroundStyle(.secondary)
              }.tag(entry.id)
            }
          }
        }
        .listStyle(.sidebar).frame(width: 165)
        .accessibilityLabel(section == "installed" ? "Installed languages" : "Language catalog")
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if section == "catalog", let entry = selectedEntry {
              catalogDetail(entry)
            } else if let pack = selectedPack {
              installedDetail(pack)
            } else {
              ContentUnavailableView(
                "No Language Selected", systemImage: "curlybraces",
                description: Text("Choose a language or import a configuration."))
            }
          }.padding(.leading, 14).padding(.trailing, 8).frame(
            maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity)
      }
      .frame(maxHeight: .infinity).disabled(environment.operation != nil)
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
            .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      }
      if !environment.issues.isEmpty {
        Text(environment.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
          .lineLimit(3).help(environment.issues.joined(separator: "\n"))
      }
      Text(
        section == "catalog"
          ? environment.catalogStatus
          : "Opening folders and importing configurations never installs or starts tools."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(10)
    .onChange(of: visibleIDs) { _, ids in
      if selection.map({ !ids.contains($0) }) ?? true { selection = ids.first }
    }
    .onChange(of: section) { _, _ in
      if selection.map({ !visibleIDs.contains($0) }) ?? true { selection = visibleIDs.first }
    }
    .task {
      environment.reload()
      selection = visibleIDs.first
      await environment.loadCachedCatalog()
      await environment.refreshGrammarStatus()
    }
    .sheet(item: $configuration) { pack in
      LanguageConfigurationView(pack: pack, environment: environment)
    }
    .sheet(item: $environment.installation) { request in
      LanguageInstallationView(request: request, environment: environment)
    }
    .sheet(item: $environment.removal) { request in
      LanguageDownloadRemovalView(request: request, environment: environment)
    }
    .alert(
      "Remove installed configuration?",
      isPresented: Binding(
        get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } })
    ) {
      Button("Cancel", role: .cancel) { confirmingRemoval = nil }
      Button("Remove", role: .destructive) {
        if let pack = confirmingRemoval { environment.removePack(pack) }
        confirmingRemoval = nil
      }
    } message: {
      Text(
        "tCode removes its installed configuration and restores any bundled default. External tools and project files are retained."
      )
    }
  }

  @ViewBuilder private func installedDetail(_ pack: LanguagePack) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(pack.name).font(.title2).fontWeight(.semibold)
      Spacer()
      Toggle(
        "Enabled",
        isOn: Binding(get: { pack.enabled }, set: { environment.setEnabled(pack, enabled: $0) })
      )
      .toggleStyle(.switch).controlSize(.small)
    }
    Text("Pack \(pack.id) · version \(pack.version) · interface \(pack.interfaceVersion)")
      .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    VStack(alignment: .leading, spacing: 8) {
      feature(
        "Recognition",
        state: "\(pack.associations.count) association\(pack.associations.count == 1 ? "" : "s")",
        symbol: "doc.text.magnifyingglass")
      feature("Highlighting", state: highlightingState(pack), symbol: "paintbrush")
      feature("Code intelligence", state: toolState(pack.server), symbol: "sparkle.magnifyingglass")
      feature("Formatting", state: toolState(pack.formatter), symbol: "text.alignleft")
      feature(
        "Tasks",
        state: pack.tasks.isEmpty
          ? "No task configuration" : pack.tasks.keys.sorted().joined(separator: ", "),
        symbol: "play.circle")
      feature("Debugging", state: toolState(pack.adapter), symbol: "ladybug")
    }
    HStack {
      Button("Configure…") { configuration = pack }
      Button("Validate") { environment.validate(pack) }
        .help("Explicitly run version probes for this pack’s configured tools.")
      Menu("More") {
        Button("Update…") { environment.prepareInstallation(id: pack.id, update: true) }
          .disabled(!environment.catalog.contains { $0.id == pack.id })
        Button("Export…") { exportPack(pack) }
        Button("Show Tool Versions and Logs", action: showLogs)
        Button("Remove Managed Downloads…") { environment.prepareRemoval(pack) }
        Button("Remove Configuration…", role: .destructive) { confirmingRemoval = pack }
          .disabled(!environment.registry.isUserInstalled(id: pack.id))
      }
    }.controlSize(.small)
    if let lines = environment.validation[pack.id] {
      GroupBox("Validation results") {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
      }
    }
    Text(
      "Tool locations are discovered locally. Select Validate to check that each executable runs; availability here does not mean a server is connected."
    )
    .font(.caption).foregroundStyle(.secondary)
  }

  @ViewBuilder private func catalogDetail(_ entry: LanguageCatalogEntry) -> some View {
    Text(entry.name).font(.title2).fontWeight(.semibold)
    Text(entry.summary).foregroundStyle(.secondary)
    Text("Version \(entry.version)").font(.caption)
    if entry.availability == .draft {
      Label("Bundled starter configuration", systemImage: "shippingbox")
        .font(.caption)
      Text(
        "Published catalog artifacts are not available yet. The bundled configuration can be installed; supported tools use their separately verified sources."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    Text(
      "Installation is optional. tCode checks prerequisites and shows downloads and expected changes before requesting approval."
    )
    .font(.caption).foregroundStyle(.secondary)
    if !entry.toolRecipeIDs.isEmpty {
      Text("Tool recipes: \(entry.toolRecipeIDs.joined(separator: ", "))")
        .font(.caption).textSelection(.enabled)
    }
    Button(
      environment.packs.contains { $0.id == entry.id } ? "Update / Install Tools…" : "Install…"
    ) {
      environment.prepareInstallation(
        id: entry.id, update: environment.packs.contains { $0.id == entry.id })
    }
  }

  private func feature(_ title: String, state: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.medium)
        Text(state).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func toolState(_ tool: String) -> String {
    guard !tool.isEmpty else { return "Not configured" }
    if tool.contains("${") { return "Uses the project interpreter / run configuration" }
    return ToolLocator.find(tool) == nil ? "\(tool) missing" : "\(tool) located · validate to check"
  }

  private func importPack() {
    let panel = NSOpenPanel()
    panel.title = "Import Language Configuration"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url { environment.importPack(url) }
  }

  private func exportPack(_ pack: LanguagePack) {
    let panel = NSSavePanel()
    panel.title = "Export Language Configuration"
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = pack.id + ".json"
    if panel.runModal() == .OK, let url = panel.url { environment.exportPack(pack, to: url) }
  }

  private func showLogs() {
    if let current = (NSApp.delegate as? AppDelegate)?.current {
      current.window?.makeKeyAndOrderFront(nil)
      current.perform("toolVersions")
    }
  }

  private func highlightingState(_ pack: LanguagePack) -> String {
    guard !pack.grammarIDs.isEmpty else { return "Basic editor highlighting" }
    let installed = pack.grammarIDs.filter { environment.installedGrammarIDs.contains($0) }
    if installed.count == pack.grammarIDs.count {
      return "Native parsers installed · " + installed.joined(separator: ", ")
    }
    let active = pack.grammarIDs.filter { environment.activeGrammarIDs.contains($0) }
    if active.count == pack.grammarIDs.count { return "Native parsers active · update available" }
    if !active.isEmpty {
      return "Partial parser support · install "
        + pack.grammarIDs.filter { !active.contains($0) }.joined(separator: ", ")
    }
    return "Basic fallback · install grammar support for "
      + pack.grammarIDs.filter { !installed.contains($0) }.joined(separator: ", ")
  }
}

private struct LanguageInstallationView: View {
  let request: LanguageInstallationRequest
  @ObservedObject var environment: LanguageEnvironment
  @State private var selectedRecipes = Set<String>()
  @State private var includeGrammars = false
  private var grammarDownloadsAvailable: Bool {
    guard let plan = request.grammarPlan else { return false }
    return request.entry.availability == .published || plan.items.allSatisfy { $0.url.isFileURL }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Install \(request.entry.name) Support").font(.title2)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Configuration: \(request.entry.name) \(request.entry.version)")
          Text(
            "Select optional components. Missing external prerequisites do not prevent configuration installation."
          )
          .font(.caption).foregroundStyle(.secondary)
          ForEach(Array(request.planIssues.enumerated()), id: \.offset) { _, issue in
            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
              .orange)
          }
          ForEach(request.plans) { plan in
            GroupBox {
              VStack(alignment: .leading, spacing: 7) {
                Toggle(
                  "\(plan.name) · \(plan.version)",
                  isOn: Binding(
                    get: { selectedRecipes.contains(plan.id) },
                    set: {
                      if $0 {
                        selectedRecipes.insert(plan.id)
                      } else {
                        selectedRecipes.remove(plan.id)
                      }
                    })
                )
                .disabled(!plan.canInstall)
                ForEach(Array(plan.prerequisites.enumerated()), id: \.offset) { _, prerequisite in
                  Label(
                    "\(prerequisite.name): \(prerequisite.detail)",
                    systemImage: prerequisite.satisfied
                      ? "checkmark.circle" : "exclamationmark.triangle"
                  )
                  .font(.caption)
                }
                ForEach(Array(plan.downloads.enumerated()), id: \.offset) { _, download in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(
                      "\(download.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(download.size), countStyle: .file))"
                    )
                    Text(download.url.absoluteString).textSelection(.enabled)
                    Text("SHA-256: " + download.sha256).textSelection(.enabled)
                  }.font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(plan.expectedChanges.enumerated()), id: \.offset) { _, change in
                  Text(change).font(.caption)
                }
                if let reason = plan.unavailableReason {
                  Text(reason).font(.caption).foregroundStyle(.orange)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
          }
          if let plan = request.grammarPlan, !plan.items.isEmpty {
            GroupBox {
              VStack(alignment: .leading, spacing: 8) {
                Toggle(
                  "Native syntax grammars · \(ByteCountFormatter.string(fromByteCount: Int64(plan.downloadBytes), countStyle: .file))",
                  isOn: $includeGrammars
                )
                .disabled(!grammarDownloadsAvailable)
                if !grammarDownloadsAvailable {
                  Text(
                    "Grammar release artifacts are prepared but have not been published. Existing grammars keep working; new downloads become available after a published catalog update."
                  )
                  .font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(plan.items.enumerated()), id: \.offset) { _, item in
                  Text("\(item.descriptor.id) · \(item.descriptor.version)").font(.caption)
                  Text(item.url.absoluteString).font(.caption).textSelection(.enabled)
                  Text("SHA-256: " + item.sha256).font(.caption).textSelection(.enabled)
                }
                ForEach(Array(plan.destinations.enumerated()), id: \.offset) { _, destination in
                  Text("Destination: " + destination.path).font(.caption).foregroundStyle(
                    .secondary
                  ).textSelection(.enabled)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
          } else if let issue = request.grammarIssue {
            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
              .orange)
          } else {
            Text("Requested native grammars are already installed.").font(.caption).foregroundStyle(
              .secondary)
          }
          Text(
            "Approval allows only the selected components to be installed or reused. Compilers and SDKs remain externally managed. Workspace servers are started separately with Enable Language Tools."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack {
        Button("Configuration Only") { environment.install(request) }
          .help(
            "Install recognition and editing configuration without downloading tools or grammars.")
        Spacer()
        Button("Cancel") { environment.installation = nil }.keyboardShortcut(.cancelAction)
        Button("Approve Installation") {
          environment.install(
            request, recipeIDs: selectedRecipes,
            includeGrammars: includeGrammars && request.grammarPlan != nil)
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(22).frame(width: 560, height: 480)
      .onAppear {
        selectedRecipes = Set(request.plans.filter(\.canInstall).map(\.id))
        includeGrammars = grammarDownloadsAvailable
      }
  }
}

private struct LanguageDownloadRemovalView: View {
  let request: LanguageRemovalRequest
  @ObservedObject var environment: LanguageEnvironment
  @State private var recipeIDs = Set<String>()
  @State private var grammarIDs = Set<String>()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Remove Managed Downloads").font(.title2)
      Text(
        "Select tCode-owned resources to remove for \(request.pack.name). Other projects may use these shared downloads."
      )
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(request.receipts.enumerated()), id: \.offset) { _, receipt in
            VStack(alignment: .leading, spacing: 4) {
              Toggle(
                "\(receipt.recipeID) · \(receipt.version)",
                isOn: Binding(
                  get: { recipeIDs.contains(receipt.recipeID) },
                  set: {
                    if $0 {
                      recipeIDs.insert(receipt.recipeID)
                    } else {
                      recipeIDs.remove(receipt.recipeID)
                    }
                  }))
              Text(receipt.managedDirectory ?? "").font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }
          ForEach(request.grammarIDs, id: \.self) { id in
            VStack(alignment: .leading, spacing: 4) {
              Toggle(
                id + " syntax grammar",
                isOn: Binding(
                  get: { grammarIDs.contains(id) },
                  set: { if $0 { grammarIDs.insert(id) } else { grammarIDs.remove(id) } }))
              Text(environment.grammarInstaller.root.appendingPathComponent(id).path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          ForEach(request.sharedImpact, id: \.self) { impact in
            Label(impact, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
              .orange)
          }
          if !request.externalRecipeIDs.isEmpty {
            Text(
              "Retained external installations: "
                + request.externalRecipeIDs.joined(separator: ", ")
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Text(
            "All versions of the selected managed resources are removed. Language configurations and project files remain. Reused external tools, compilers, interpreters, and SDKs are retained."
          )
          .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Cancel") { environment.removal = nil }.keyboardShortcut(.cancelAction)
        Button("Remove Selected Downloads", role: .destructive) {
          environment.removeDownloads(request, recipeIDs: recipeIDs, grammarIDs: grammarIDs)
        }.disabled(recipeIDs.isEmpty && grammarIDs.isEmpty)
      }
    }.padding(22).frame(width: 550, height: 440)
  }
}

private struct LanguageConfigurationView: View {
  let pack: LanguagePack
  @ObservedObject var environment: LanguageEnvironment
  @Environment(\.dismiss) private var dismiss
  @State private var paths: [String: String] = [:]
  private var externalGuidance: [String] {
    let ids = Set(
      pack.toolRecipeIDs + (environment.catalog.first { $0.id == pack.id }?.toolRecipeIDs ?? []))
    return ToolRecipe.curated.filter { ids.contains($0.id) && $0.kind == .external }.map(\.guidance)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Configure \(pack.name)").font(.title2)
      Text(
        "Executable overrides apply to tCode on this Mac. They are excluded from exported packs."
      )
      .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(LanguageEnvironment.toolNames(pack), id: \.self) { tool in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                TextField(
                  tool + " executable override",
                  text: Binding(get: { paths[tool] ?? "" }, set: { paths[tool] = $0 })
                ).textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseExecutable(tool) }.controlSize(.small)
              }
              Text("Located: \(ToolLocator.find(tool) ?? "not found")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
          ForEach(externalGuidance, id: \.self) { guidance in
            Text(guidance).font(.caption).foregroundStyle(.secondary)
          }
          if LanguageEnvironment.toolNames(pack).isEmpty {
            Text("This language pack has no external tool commands.").foregroundStyle(.secondary)
          }
        }
      }
      Text(
        "Leave an override empty to use normal tool discovery. Saving settings does not start tools."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          for (tool, value) in paths {
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty {
              UserDefaults.standard.removeObject(forKey: "tool." + tool)
            } else {
              UserDefaults.standard.set(path, forKey: "tool." + tool)
            }
          }
          environment.reload()
          NotificationCenter.default.post(name: .tcodeToolSettingsChanged, object: nil)
          dismiss()
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(22).frame(width: 520, height: 370)
      .onAppear {
        for tool in LanguageEnvironment.toolNames(pack) {
          paths[tool] = UserDefaults.standard.string(forKey: "tool." + tool) ?? ""
        }
      }
  }

  private func chooseExecutable(_ tool: String) {
    let panel = NSOpenPanel()
    panel.title = "Choose \(tool) Executable"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { paths[tool] = url.path }
  }
}
