import AppKit
import HyprdarwinConfig
import HyprdarwinControl
import HyprdarwinCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, binds, windowRules, workspaceRules, errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .binds: return "Binds"
        case .windowRules: return "Window Rules"
        case .workspaceRules: return "Workspace Rules"
        case .errors: return "Errors"
        }
    }
}

/// What the settings window shows: the active config and the last load.
struct SettingsState: Equatable {
    enum Status: Equatable {
        /// The file loaded; this is it.
        case loaded
        /// The last load failed; the previous config is still active.
        case rejected
        /// No load ever succeeded; the built-in default config is active.
        case failed
    }

    var configPath = ""
    var files: [String] = []
    var loadedAt: Date?
    var status = Status.loaded
    var report = ConfigReport(config: Config())
    var messages: [ConfigMessage] = []
}

final class SettingsModel: ObservableObject {
    @Published var state = SettingsState()
    @Published var tab = SettingsTab.general
    /// The Binds tab's filter text. (Not @State: on macOS 26 that is a
    /// macro, and Command Line Tools ship no SwiftUI macro plugin.)
    @Published var bindFilter = ""
}

/// The read-only settings window (menu > Settings…): effective options,
/// binds, window and workspace rules, and the config's errors. It never
/// writes the config; Open Config and Reload are the only actions.
final class SettingsWindow: NSObject, NSWindowDelegate {
    var onReload: (() -> Void)?
    var onOpenConfig: (() -> Void)?

    private let model = SettingsModel()
    private var window: NSWindow?

    var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }

    func update(_ state: SettingsState) {
        guard model.state != state else { return }
        model.state = state
    }

    func show(tab: SettingsTab?) {
        let window = self.window ?? makeWindow()
        self.window = window
        if let tab { model.tab = tab }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(model: model,
                                onReload: { [weak self] in self?.onReload?() },
                                onOpenConfig: { [weak self] in self?.onOpenConfig?() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "hyprdarwin Settings"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        // the window keeps its size across tabs; SwiftUI only sets the minimum
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.contentMinSize = NSSize(width: 900, height: 460)
        window.setFrameAutosaveName("hyprdarwin.settings")
        if window.frame.origin == .zero { window.center() }
        window.delegate = self
        return window
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onReload: () -> Void
    var onOpenConfig: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(state: model.state, onReload: onReload, onOpenConfig: onOpenConfig)
            Divider()
            Picker("Section", selection: $model.tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(title(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 12)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom], 20)
        }
        .frame(minWidth: 900, minHeight: 460)
        .background(SwiftUI.Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        let report = model.state.report
        switch model.tab {
        case .general: OptionsTab(options: report.options)
        case .binds: BindsTab(binds: report.binds, submaps: report.submaps, filter: $model.bindFilter)
        case .windowRules: WindowRulesTab(rules: report.windowRules)
        case .workspaceRules: WorkspaceRulesTab(rules: report.workspaceRules)
        case .errors: MessagesTab(messages: model.state.messages)
        }
    }

    /// Counts on the tabs: binds, rules, and errors plus warnings.
    private func title(_ tab: SettingsTab) -> String {
        let report = model.state.report
        let count: Int
        switch tab {
        case .general: return tab.title
        case .binds: count = report.binds.count
        case .windowRules: count = report.windowRules.count
        case .workspaceRules: count = report.workspaceRules.count
        case .errors: count = model.state.messages.filter { $0.severity != .info }.count
        }
        return count == 0 ? tab.title : "\(tab.title) (\(count))"
    }
}

private let mono = Font.system(.body, design: .monospaced)

struct SettingsHeader: View {
    var state: SettingsState
    var onReload: () -> Void
    var onOpenConfig: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.configPath)
                    .font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Open Config", action: onOpenConfig)
            Button("Reload", action: onReload)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var symbol: String {
        switch state.status {
        case .loaded: return "checkmark.circle.fill"
        case .rejected: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var color: SwiftUI.Color {
        switch state.status {
        case .loaded: return .green
        case .rejected: return .orange
        case .failed: return .red
        }
    }

    private var summary: String {
        var parts: [String] = []
        switch state.status {
        case .loaded:
            if let date = state.loadedAt { parts.append("Loaded at \(date.formatted(date: .omitted, time: .standard))") }
        case .rejected:
            parts.append("The last load failed: the previous config stays active")
        case .failed:
            parts.append("The config never loaded: the built-in default config is active")
        }
        if state.files.count > 1 { parts.append("\(state.files.count) files") }
        parts.append("read-only: edit the Lua file to change settings")
        return parts.joined(separator: " · ")
    }
}

struct OptionsTab: View {
    var options: [ConfigReport.Option]

    var body: some View {
        Table(options) {
            TableColumn("Option") { option in
                Text(option.name).font(mono).textSelection(.enabled)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Value") { option in
                Text(option.value)
                    .font(mono)
                    .foregroundStyle(option.isSet ? .primary : .secondary)
                    .textSelection(.enabled)
                    .help(option.value)
            }
            .width(min: 200, ideal: 330)
            // the built-in default, where the config changed it
            TableColumn("Default") { option in
                Text(option.isSet ? option.defaultValue : "")
                    .font(mono)
                    .foregroundStyle(.secondary)
                    .help(option.isSet ? "built-in default: \(option.defaultValue)" : "")
            }
            .width(min: 80, ideal: 190)
        }
    }
}

struct BindsTab: View {
    var binds: [ConfigReport.Bind]
    var submaps: [String]
    @Binding var filter: String

    private var shown: [ConfigReport.Bind] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return binds }
        return binds.filter { bind in
            [bind.keys, bind.action, bind.description, bind.submap].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Filter by keys, action, description or submap", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Spacer()
                Text(countText).foregroundStyle(.secondary)
            }
            if binds.isEmpty {
                ContentUnavailableView("No binds", systemImage: "keyboard", description: Text("Add some with hl.bind in the config."))
            } else {
                Table(shown) {
                    TableColumn("Keys") { bind in
                        Text(bind.keys).font(mono).foregroundStyle(bind.enabled ? .primary : .secondary).textSelection(.enabled)
                    }
                    .width(min: 120, ideal: 185)
                    TableColumn("Action") { bind in
                        Text(bind.action).font(mono).foregroundStyle(bind.enabled ? .primary : .secondary)
                            .textSelection(.enabled).help(bind.action)
                    }
                    .width(min: 160, ideal: 285)
                    TableColumn("Description") { bind in
                        Text(bind.description).foregroundStyle(bind.enabled ? .primary : .secondary)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Submap") { bind in
                        Text(bind.submap).font(mono).foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 60, max: 120)
                    TableColumn("Flags") { bind in
                        Text((bind.enabled ? [] : ["disabled"]) + bind.flags, format: .list(type: .and, width: .narrow))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 65, max: 140)
                }
            }
        }
    }

    private var countText: String {
        var text = shown.count == binds.count ? "\(binds.count) binds" : "\(shown.count) of \(binds.count) binds"
        if !submaps.isEmpty { text += " · submaps: \(submaps.joined(separator: ", "))" }
        return text
    }
}

struct WindowRulesTab: View {
    var rules: [ConfigReport.WindowRule]

    var body: some View {
        if rules.isEmpty {
            ContentUnavailableView("No window rules", systemImage: "macwindow", description: Text("Add some with hl.window_rule in the config."))
        } else {
            Table(rules) {
                TableColumn("#") { rule in
                    Text("\(rule.id + 1)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 24, ideal: 28, max: 40)
                TableColumn("Name") { rule in
                    Text(rule.name.isEmpty ? "-" : rule.name).foregroundStyle(rule.enabled ? .primary : .secondary)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Match") { rule in
                    wrapped(rule.match.joined(separator: "\n"), enabled: rule.enabled)
                }
                .width(min: 160, ideal: 300)
                TableColumn("Effects") { rule in
                    wrapped(rule.effects.joined(separator: "\n"), enabled: rule.enabled)
                }
                .width(min: 140, ideal: 240)
                TableColumn("State") { rule in
                    Text(([rule.enabled ? "enabled" : "disabled"] + (rule.dynamic ? ["dynamic"] : [])).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80, max: 140)
            }
        }
    }

    private func wrapped(_ text: String, enabled: Bool) -> some View {
        Text(text)
            .font(mono)
            .foregroundStyle(enabled ? .primary : .secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.vertical, 2)
    }
}

struct WorkspaceRulesTab: View {
    var rules: [ConfigReport.WorkspaceRule]

    var body: some View {
        if rules.isEmpty {
            ContentUnavailableView("No workspace rules", systemImage: "rectangle.3.group",
                                   description: Text("Add some with hl.workspace_rule in the config."))
        } else {
            Table(rules) {
                TableColumn("Workspace") { rule in
                    Text(rule.workspace).font(mono)
                }
                .width(min: 80, ideal: 120, max: 200)
                TableColumn("Settings") { rule in
                    Text(rule.settings.joined(separator: ", ")).font(mono).textSelection(.enabled)
                }
            }
        }
    }
}

struct MessagesTab: View {
    var messages: [ConfigMessage]

    var body: some View {
        if messages.isEmpty {
            ContentUnavailableView("No errors or warnings", systemImage: "checkmark.circle",
                                   description: Text("The config loaded cleanly."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.severity) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title).font(.headline).foregroundStyle(group.color)
                            ForEach(Array(group.messages.enumerated()), id: \.offset) { _, message in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: group.symbol).foregroundStyle(group.color)
                                    Text(message.text)
                                        .font(mono)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private struct Group {
        var severity: ConfigMessage.Severity
        var title: String
        var symbol: String
        var color: SwiftUI.Color
        var messages: [ConfigMessage]
    }

    private var groups: [Group] {
        let all: [Group] = [
            Group(severity: .error, title: "Errors (the previous config stays active)", symbol: "xmark.octagon.fill", color: .red, messages: []),
            Group(severity: .warning, title: "Warnings", symbol: "exclamationmark.triangle.fill", color: .orange, messages: []),
            Group(severity: .info, title: "Notes (Hyprland features macOS cannot honour, print output)", symbol: "info.circle",
                  color: .secondary, messages: []),
        ]
        return all.compactMap { group in
            var group = group
            group.messages = messages.filter { $0.severity == group.severity }
            return group.messages.isEmpty ? nil : group
        }
    }
}
