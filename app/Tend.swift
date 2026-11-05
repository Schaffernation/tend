// Tend: a menu bar app for the `tend` CLI. It lists tracked tmux sessions,
// shows which app runs in each one (Claude, or any app you add) and its
// status, and starts, stops, restarts, and opens them. All the work happens in `tend`; this app only
// calls it.
//
// Source: https://github.com/Schaffernation/tend
// Build and install with app/build.sh. The build copies bin/tend into the
// app's Resources folder, and the app runs that copy.

import ServiceManagement
import SwiftUI
import UserNotifications

/// The app tend recognized in a session.
struct AppInfo: Decodable, Hashable {
    let id: String
    let name: String
    let status: String?
}

/// An app tend knows how to recognize.
struct AppProfile: Decodable, Identifiable, Hashable {
    struct Match: Decodable, Hashable {
        let names: [String]?
        let paths: [String]?
    }
    let id: String
    let name: String?
    let enabled: Bool
    let builtin: Bool
    let match: Match?
    let launch: String?
    var title: String { name ?? id }
    var rules: String { ((match?.names ?? []) + (match?.paths ?? [])).joined(separator: ", ") }
}

/// How `tend open` opens a session: the terminal app and the attach command.
struct TerminalSettings: Decodable, Hashable {
    let app: String
    let attach: String
    let mode: String
    let apps: [String]
    let presets: [String: String]
}

/// Another account on this Mac that should run its own Tend. Decoded from
/// `tend accounts --json` with snake-case keys converted.
struct AccountStatus: Decodable, Identifiable, Hashable {
    let user: String
    let name: String
    let loggedIn: Bool
    let tendRunning: Bool
    let ok: Bool
    let problem: String?
    var id: String { user }
}

struct Accounts: Decodable {
    struct Available: Decodable, Hashable {
        let user: String
        let name: String
    }
    let watched: [AccountStatus]
    let available: [Available]
}

struct Service: Decodable, Identifiable, Hashable {
    let name: String
    let dir: String
    let command: String?
    let resume: String?
    let autostart: Bool
    let managed: Bool
    let state: String
    let attached: Bool
    let app: AppInfo?
    var id: String { name }
}

@MainActor
final class Model: ObservableObject {
    @Published var services: [Service] = []
    @Published var error: String?
    @Published var apps: [AppProfile] = []
    @Published var terminal: TerminalSettings?
    @Published var accounts: Accounts?

    /// When each watched account's problem started, and which problems Tend
    /// has already posted a notification for.
    private var problemSince: [String: Date] = [:]
    private var notified: Set<String> = []
    /// How long a problem lasts before Tend posts a notification. It gives
    /// someone time to log in after a restart before Tend nags.
    static let notifyAfter: TimeInterval = 60
    @Published var busy = false
    /// The new-session form. Kept here, not in the view, so it survives the
    /// panel closing while a folder picker is open.
    @Published var draft: Draft?

    struct Draft {
        var appID: String?  // nil means a custom command
        var dir = ""
        var name = ""
        var command = ""
        var autostart = true
    }
    @AppStorage("restoreOnLaunch") var restoreOnLaunch = true

    nonisolated static let tend = Bundle.main.url(forResource: "tend", withExtension: nil)?.path
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/tend").path

    /// Where "Install command-line tool" links `tend`.
    nonisolated static let cliLink = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/tend")

    nonisolated static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// Why tend can't run on this Mac, or nil if it can. tend is a Python
    /// script, and macOS only ships Python with the developer tools.
    static let setupProblem: String? = {
        let fm = FileManager.default
        if ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].contains(where: fm.isExecutableFile) {
            return nil
        }
        // /usr/bin/python3 is a stub until the developer tools are installed.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
        }
        return "Tend needs Python 3. Install the Command Line Tools with xcode-select --install, or install Python with Homebrew: brew install python"
    }()

    init() {
        if let problem = Model.setupProblem {
            error = problem
            return
        }
        Task {
            // Restore only on the first launch since the Mac started. A
            // relaunch, like after a crash, checks in and changes nothing.
            if restoreOnLaunch { await run(["restore", "--once"]) }
            await loadTerminal()
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var runningCount: Int { services.filter { $0.state == "running" }.count }
    var anyBusy: Bool { services.contains { $0.app?.status == "busy" } }
    var accountProblems: [AccountStatus] { accounts?.watched.filter { !$0.ok } ?? [] }

    @discardableResult
    func run(_ args: [String]) async -> Data? {
        let result = await Task.detached { () -> (Int32, Data, String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Model.tend)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Model.path
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                return (-1, Data(), "Couldn't run \(Model.tend): \(error.localizedDescription)")
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, data, String(decoding: errData, as: UTF8.self))
        }.value
        if result.0 != 0 {
            error = result.2.trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }
        return result.1
    }

    func refresh() async {
        guard let data = await run(["ls", "--json"]),
              let appData = await run(["apps", "--json"]),
              let accountData = await run(["accounts", "--json"]) else { return }
        do {
            services = try JSONDecoder().decode([Service].self, from: data)
            apps = try JSONDecoder().decode([AppProfile].self, from: appData)
            let snake = JSONDecoder()
            snake.keyDecodingStrategy = .convertFromSnakeCase
            accounts = try snake.decode(Accounts.self, from: accountData)
            checkAccounts()
            error = nil
        } catch {
            self.error = "Couldn't read tend's output: \(error.localizedDescription)"
        }
    }

    /// Post one notification for each account problem that lasts longer
    /// than `notifyAfter`. Once the account is fine again, a new problem
    /// notifies again.
    func checkAccounts() {
        let now = Date()
        for account in accounts?.watched ?? [] {
            guard !account.ok, let problem = account.problem else {
                problemSince[account.user] = nil
                notified.remove(account.user)
                continue
            }
            let since = problemSince[account.user] ?? now
            problemSince[account.user] = since
            if now.timeIntervalSince(since) >= Model.notifyAfter && !notified.contains(account.user) {
                notified.insert(account.user)
                Model.notify(id: "account-\(account.user)", title: "Log in \(account.name)", body: problem
                    + " To log in, choose their account from the user menu in the menu bar or Control Center.")
            }
        }
    }

    static func notify(id: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func watchAccount(_ user: String, _ on: Bool) {
        act(["accounts", on ? "add" : "rm", user])
    }

    func loadTerminal() async {
        guard let data = await run(["terminal", "--json"]) else { return }
        terminal = try? JSONDecoder().decode(TerminalSettings.self, from: data)
    }

    /// Change the terminal app or the attach command (a preset name or a command).
    func setTerminal(app: String? = nil, attach: String? = nil) {
        var args = ["terminal"]
        if let app { args += ["--app", app] }
        if let attach { args += ["--attach", attach] }
        Task {
            busy = true
            error = nil
            await run(args)
            await loadTerminal()
            busy = false
        }
    }

    /// Link `tend` into ~/.local/bin, so you can run it in a terminal.
    func installCLI() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Model.cliLink.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: Model.cliLink.path, withDestinationPath: Model.tend)
            error = nil
        } catch {
            self.error = "Couldn't link \(Model.cliLink.path): \(error.localizedDescription)"
        }
    }

    /// Start a new session from the draft. Closes the form if it worked.
    func create() {
        guard let d = draft else { return }
        var args = ["new"]
        if let id = d.appID { args.append(id) }
        args += ["--dir", d.dir]
        if !d.name.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--name", d.name] }
        if !d.autostart { args.append("--no-autostart") }
        let launch = apps.first { $0.id == d.appID }?.launch
        if d.command != launch { args += ["--command", d.command] }
        Task {
            busy = true
            error = nil
            if await run(args) != nil {
                draft = nil
                UserDefaults.standard.set(d.dir, forKey: "lastDir")
                UserDefaults.standard.set(d.appID ?? "", forKey: "lastApp")
            }
            await refresh()
            busy = false
        }
    }

    func act(_ args: [String]) {
        Task {
            busy = true
            error = nil
            await run(args)
            await refresh()
            busy = false
        }
    }
}

@main
struct TendApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Image(systemName: model.anyBusy ? "terminal.fill" : "terminal")
            if !model.accountProblems.isEmpty {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
            }
            if model.runningCount > 0 { Text("\(model.runningCount)") }
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var tracked: [Service] { model.services.filter(\.managed) }
    var untracked: [Service] { model.services.filter { !$0.managed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tend").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.draft == nil ? newDraft() : (model.draft = nil) } label: {
                    Image(systemName: model.draft == nil ? "plus" : "xmark")
                }
                .buttonStyle(.borderless)
                .help(model.draft == nil
                      ? "Start a new session: pick an app and a folder."
                      : "Cancel the new session.")
                Button { model.act(["ls"]) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check every session now, and save the latest session ID of apps that can resume, like Claude. Tend also does this every 5 seconds.")
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            ForEach(model.accountProblems) { account in
                Label(account.problem ?? "", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .help("To log \(account.name) in, choose their account from the user menu in the menu bar or Control Center. Their Tend then restarts their sessions.")
            }

            if model.services.isEmpty {
                Text("No services. Start a tmux session, then choose Track running sessions.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if model.draft != nil {
                NewSessionForm()
                Divider()
            }

            ForEach(tracked) { ServiceRow(service: $0) }

            if !untracked.isEmpty {
                Text("Not tracked").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(untracked) { ServiceRow(service: $0) }
            }

            Divider()

            HStack {
                Button("Restore all") { model.act(["restore"]) }
                    .help("Start every tracked session that's set to restore and isn't running. Sessions that can resume, like Claude, reattach to their last conversation.")
                Button("Track running sessions") { model.act(["snapshot"]) }
                    .disabled(untracked.isEmpty)
                    .help(untracked.isEmpty
                        ? "Every running tmux session is already tracked."
                        : "Add every untracked tmux session to the list, so Tend restores it.")
            }

            AppsSection()
            TerminalSection()
            AccountsSection()

            Toggle("Restore after the Mac starts", isOn: model.$restoreOnLaunch)
                .help("The first time Tend opens after the Mac starts, start every tracked session that's set to restore. If you quit Tend or it crashes, your sessions keep running, and opening Tend again doesn't start or stop anything.")
            Toggle("Open Tend at login", isOn: $openAtLogin)
                .help("Open Tend when you log in. With the setting above, this restores your sessions after the Mac starts.")
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        model.error = "Couldn't change the login item: \(error.localizedDescription)"
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            if Model.setupProblem == nil
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: Model.cliLink.path)) == nil
                && !FileManager.default.fileExists(atPath: Model.cliLink.path) {
                Button("Install command-line tool") { model.installCLI() }
                    .help("Link tend into ~/.local/bin, so you can run it in a terminal and over ssh. Add ~/.local/bin to your PATH if it isn't there already.")
            }

            HStack {
                Button("Edit config") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".config/tend/services.json")
                    NSWorkspace.shared.open(url)
                }
                .help("Open ~/.config/tend/services.json, the list of tracked sessions.")
                Spacer()
                Button("Quit Tend") { NSApp.terminate(nil) }
                    .help("Quit the menu bar app. Your tmux sessions keep running.")
            }

        }
        .padding(12)
        .frame(width: 400)
    }
}

extension ContentView {
    func newDraft() {
        let defaults = UserDefaults.standard
        let launchable = model.apps.filter { $0.enabled && $0.launch != nil }
        let lastApp = defaults.string(forKey: "lastApp")
        let app = launchable.first { $0.id == lastApp } ?? (lastApp == "" ? nil : launchable.first)
        model.draft = Model.Draft(
            appID: app?.id,
            dir: defaults.string(forKey: "lastDir")
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            command: app?.launch ?? "")
    }
}

/// The form behind the plus button. It runs `tend new`, which tracks the
/// session and starts it, like rc-spawn but for any app.
struct NewSessionForm: View {
    @EnvironmentObject var model: Model

    var launchable: [AppProfile] { model.apps.filter { $0.enabled && $0.launch != nil } }

    /// Folders you've used, and the folders next to them (your other projects).
    var suggestions: (recent: [String], nearby: [String]) {
        let recent = Array(Set(model.services.map(\.dir))).sorted()
        let fm = FileManager.default
        var nearby = Set<String>()
        for parent in Set(recent.map { ($0 as NSString).deletingLastPathComponent }) {
            for child in (try? fm.contentsOfDirectory(atPath: parent)) ?? [] where !child.hasPrefix(".") {
                let path = (parent as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                   !recent.contains(path) { nearby.insert(path) }
            }
        }
        return (recent, Array(nearby).sorted().prefix(40).map { $0 })
    }

    func short(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var body: some View {
        if let draft = model.draft {
            let binding = Binding { model.draft ?? draft } set: { model.draft = $0 }
            VStack(alignment: .leading, spacing: 8) {
                Text("New session").font(.subheadline).fontWeight(.medium)

                Picker("App", selection: binding.appID) {
                    ForEach(launchable) { Text($0.title).tag(Optional($0.id)) }
                    Text("Other command").tag(String?.none)
                }
                .onChange(of: draft.appID) { _, id in
                    model.draft?.command = launchable.first { $0.id == id }?.launch ?? ""
                }
                .help("The app to run. Add apps, and their launch commands, in the Apps section.")

                HStack {
                    Text("Folder")
                    Text(short(draft.dir)).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu("Pick") {
                        let s = suggestions
                        Section("Recent") {
                            ForEach(s.recent, id: \.self) { d in Button(short(d)) { model.draft?.dir = d } }
                        }
                        Section("Nearby") {
                            ForEach(s.nearby, id: \.self) { d in Button(short(d)) { model.draft?.dir = d } }
                        }
                        Divider()
                        Button("Choose…", action: chooseFolder)
                    }
                    .fixedSize()
                    .help("Recent folders, the folders next to them, or any folder")
                }

                TextField("Name", text: binding.name,
                          prompt: Text((draft.dir as NSString).lastPathComponent))
                    .help("The tmux session name. If you leave it empty, Tend uses the folder name, plus a number if that name is taken.")
                TextField("Command", text: binding.command)
                    .font(.system(.body, design: .monospaced))
                    .help("The command Tend types into the new session's shell")
                Toggle("Restore at login", isOn: binding.autostart)
                    .help("Start this session again when Tend restores sessions")

                HStack {
                    Spacer()
                    Button("Cancel") { model.draft = nil }
                    Button("Start") { model.create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.dir.isEmpty || draft.command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the new session"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.draft?.dir ?? NSHomeDirectory())
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { model.draft?.dir = url.path }
    }
}

struct ServiceRow: View {
    @EnvironmentObject var model: Model
    let service: Service

    var color: Color {
        switch service.state {
        case "running": .green
        case "exited": .orange
        default: .secondary
        }
    }

    var stateHint: String {
        switch service.state {
        case "running": "\(service.name) is running."
        case "exited": "\(service.name)'s command exited. The tmux session is still open at a shell prompt."
        default: "\(service.name) isn't running."
        }
    }

    var subtitle: String {
        let dir = service.dir.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return "\(dir) · \(service.command ?? "shell")"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .help(stateHint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(service.name).fontWeight(.medium)
                    if let c = service.app {
                        Text([c.name, c.status].compactMap { $0 }.joined(separator: " "))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                (c.status == "busy" ? Color.blue : Color.gray).opacity(0.2),
                                in: Capsule())
                    }
                    if service.state == "exited" {
                        Text("exited").font(.caption2).foregroundStyle(.orange)
                    }
                    if service.managed && !service.autostart {
                        Text("manual").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            buttons
        }
        .contextMenu { menu }
    }

    @ViewBuilder var buttons: some View {
        HStack(spacing: 4) {
            if service.state == "stopped" {
                icon("play.fill", service.resume != nil
                     ? "Start \(service.name) and reattach to its last session: \(service.resume!)"
                     : "Start \(service.name).") { model.act(["start", service.name]) }
            } else {
                icon("macwindow", "Open \(service.name) in a new terminal window.") { model.act(["open", service.name]) }
                if service.managed {
                    icon("arrow.clockwise", service.resume != nil
                         ? "Restart \(service.name) and reattach to the same session. Right-click to start fresh."
                         : "Restart \(service.name).") { model.act(["restart", service.name]) }
                }
                icon("stop.fill", "Stop \(service.name) by closing its tmux session." + (service.managed ? " It stays on the list." : "")) { model.act(["stop", service.name]) }
            }
            if !service.managed {
                icon("plus.circle", "Track \(service.name), so Tend restores it.") { model.act(["snapshot", service.name]) }
            }
        }
    }

    @ViewBuilder var menu: some View {
        if service.managed {
            Button("Start fresh") {
                model.act(["restart", service.name, "--fresh"])
            }
            Button(service.autostart ? "Don't restore at login" : "Restore at login") {
                model.act(["autostart", service.name, service.autostart ? "off" : "on"])
            }
            Divider()
            Button("Stop tracking") { model.act(["rm", service.name]) }
        } else {
            Button("Track") { model.act(["snapshot", service.name]) }
        }
    }

    func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// The apps tend recognizes. Turn one off to stop recognizing it, or add any
/// program by choosing its executable.
struct AppsSection: View {
    @EnvironmentObject var model: Model
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.apps) { app in
                    Toggle(isOn: Binding(
                        get: { app.enabled },
                        set: { model.act(["apps", $0 ? "enable" : "disable", app.id]) }
                    )) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.title + (app.builtin ? " (built in)" : ""))
                            Text(app.rules).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .help("Recognize processes that match: \(app.rules)")
                    .contextMenu {
                        if !app.builtin {
                            Button("Remove") { model.act(["apps", "rm", app.id]) }
                        }
                    }
                }
                Button("Add app…", action: addApp)
                    .help("Choose a program. Tend then recognizes it when it runs in a tmux session.")
            }
            .padding(.top, 4)
        } label: {
            Text("Apps").help("The programs Tend looks for in each tmux session")
        }
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose a program for Tend to recognize"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // For a .app bundle, use its main executable.
        if url.pathExtension == "app", let exe = Bundle(url: url)?.executableURL { url = exe }
        model.act(["apps", "add", url.path])
    }
}

/// How the open button opens a session: which terminal app, and which
/// command it runs there. Use tmux control mode for iTerm2's tmux integration.
struct TerminalSection: View {
    @EnvironmentObject var model: Model
    @State private var expanded = false
    @State private var custom = ""
    @State private var editingCustom = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let t = model.terminal {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("App", selection: Binding(
                        get: { t.app },
                        set: { model.setTerminal(app: $0) }
                    )) {
                        ForEach(t.apps, id: \.self) { Text($0).tag($0) }
                    }
                    .help("The terminal app that the open button opens sessions in")

                    Picker("Attach with", selection: Binding(
                        get: { editingCustom ? "custom" : t.mode },
                        set: { mode in
                            if mode == "custom" {
                                custom = t.attach
                                editingCustom = true
                            } else {
                                editingCustom = false
                                model.setTerminal(attach: mode)
                            }
                        }
                    )) {
                        Text("tmux attach").tag("tmux")
                        Text("iTerm2 tmux integration (tmux -CC)").tag("control")
                        Text("Custom command").tag("custom")
                    }
                    .help("tmux attach shows the session in one terminal window. tmux -CC uses control mode: iTerm2 shows each tmux window as a native window or tab.")

                    if t.mode == "control" && t.app != "iTerm" {
                        Text("tmux -CC needs iTerm2. Terminal shows control mode as raw text.")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    if editingCustom || t.mode == "custom" {
                        HStack {
                            TextField("Command", text: $custom)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit(saveCustom)
                            Button("Save", action: saveCustom)
                                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty
                                          || custom == t.attach)
                        }
                        .help("The command to run in the new window. {tmux} is the path to tmux, {target} is the session's tmux target, and {name} is the session name.")
                    }
                }
                .padding(.top, 4)
                .onAppear { if t.mode == "custom" { custom = t.attach } }
            }
        } label: {
            Text("Terminal").help("How the open button opens a session in a terminal")
        }
    }

    func saveCustom() {
        editingCustom = false
        model.setTerminal(attach: custom)
    }
}

/// Other accounts on this Mac, like a family member's under fast user switching.
/// Tend warns when a watched account isn't logged in or isn't running Tend,
/// because then that account's sessions aren't running.
struct AccountsSection: View {
    @EnvironmentObject var model: Model
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.accounts?.watched ?? []) { account in
                    HStack {
                        Circle().fill(account.ok ? Color.green : Color.orange).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(account.name)
                            Text(account.ok ? "Tend is running."
                                 : account.loggedIn ? "Logged in, but Tend isn't running." : "Not logged in.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.watchAccount(account.user, false) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop watching \(account.name)'s account")
                    }
                }
                let available = model.accounts?.available ?? []
                if available.isEmpty && (model.accounts?.watched.isEmpty ?? true) {
                    Text("This Mac has no other accounts.").font(.caption).foregroundStyle(.secondary)
                } else if !available.isEmpty {
                    Menu("Watch an account") {
                        ForEach(available, id: \.self) { a in
                            Button(a.name) { model.watchAccount(a.user, true) }
                        }
                    }
                    .fixedSize()
                    .help("Warn me when this account isn't logged in or isn't running Tend. Install Tend in that account too, with Open Tend at login on.")
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Other accounts").help("Check that Tend runs in other accounts on this Mac, so their sessions run too")
        }
    }
}
