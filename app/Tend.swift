// Tend: a menu bar app for the `tend` CLI. It lists tracked tmux sessions,
// shows which app runs in each one (Claude, or any app you add) and its
// status, and starts, stops, restarts, and opens them. All the work happens in `tend`; this app only
// calls it.
//
// Source: https://github.com/schaffernation/tend
// Build and install with app/build.sh. The build copies bin/tend into the
// app's Resources folder, and the app runs that copy.

import ServiceManagement
import SwiftUI
import UserNotifications

/// The app tend recognized in a session.
struct AppInfo: Decodable, Hashable {
    /// A prompt the app stopped on, like Claude asking to trust a folder.
    struct Question: Decodable, Hashable {
        struct Answer: Decodable, Hashable {
            let id: String
            let label: String
        }
        let id: String
        let text: String
        let answers: [Answer]
    }
    let id: String
    let name: String
    let icon: String?
    let status: String?
    let question: Question?
}

/// A saved setup that `tend new --recipe` runs in a new session's folder.
struct Recipe: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let setup: String
    let input: String?
    var title: String { name ?? id }
    var needsInput: Bool { setup.contains("{input}") }
}

/// Pictures for apps, from a profile's `icon`: a bundle ID, or the path to a
/// .app or an image file. An icon that's found is kept; one that isn't is
/// looked up again a minute later, in case you install the app meanwhile.
@MainActor
enum AppIcons {
    private static var found: [String: NSImage] = [:]
    private static var missing: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 60

    static func image(_ spec: String?, size: CGFloat = 16) -> NSImage? {
        guard let spec, !spec.isEmpty else { return nil }
        let key = "\(spec)@\(size)"
        if let hit = found[key] { return hit }
        if let since = missing[key], Date().timeIntervalSince(since) < retryAfter { return nil }
        guard let image = load(spec)?.copy() as? NSImage else {
            missing[key] = Date()
            return nil
        }
        image.size = NSSize(width: size, height: size)
        found[key] = image
        missing[key] = nil
        return image
    }

    private static func load(_ spec: String) -> NSImage? {
        let path = (spec as NSString).expandingTildeInPath
        if path.hasPrefix("/") {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            if path.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: path) }
            return NSImage(contentsOfFile: path)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spec) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// An app's icon, or nothing if it has none or it can't be found.
struct AppIconView: View {
    let spec: String?
    var size: CGFloat = 16

    var body: some View {
        if let image = AppIcons.image(spec, size: size) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        }
    }
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
    let icon: String?
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

/// A conversation that was dropped when its session restarted, from
/// `tend dropped --json` with snake-case keys converted.
struct DroppedChat: Decodable, Identifiable, Hashable {
    let session: String
    let id: String
    let label: String?
    let droppedAt: Int
}

/// Folders to suggest for a new session, from `tend folders --json`.
struct Folders: Decodable {
    let recent: [String]
    let nearby: [String]
    let parents: [String]
}

/// Where tend keeps its files, from `tend config --json`.
struct ConfigPaths: Decodable {
    let config: String
    let state: String
}

/// A session's state: running, its command exited (the tmux session is
/// still open at a shell prompt), or stopped (no tmux session).
enum SessionState: String, Decodable {
    case running, exited, stopped
}

/// A tracked session, or a tmux session tend doesn't track, from
/// `tend ls --json`.
struct Session: Decodable, Identifiable, Hashable {
    let name: String
    let dir: String
    /// Whether the session is named after its folder.
    let namedAfterDir: Bool
    let command: String?
    let resume: String?
    let autostart: Bool
    /// Whether Tend brings back the session's conversation when it restarts.
    /// When it doesn't, the session starts its plain command every time.
    let restoreConversation: Bool
    let managed: Bool
    let state: SessionState
    let attached: Bool
    let app: AppInfo?
    var id: String { name }
}

/// What a run of `tend` printed, and whether it worked.
struct TendResult {
    /// Standard output, if tend exited with status 0.
    let output: Data?
    /// Standard error, if tend failed.
    let error: String?
}

/// Decode tend's JSON, which uses snake_case keys.
func decodeTend<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data)
}

@MainActor
final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    /// Why the last action failed, like a start or a new session. It stays
    /// until you close it or take another action.
    @Published var error: String?
    /// Why Tend can't read its sessions. It clears once a refresh works.
    @Published var refreshError: String?
    @Published var apps: [AppProfile] = []
    @Published var recipes: [Recipe] = []
    @Published var terminal: TerminalSettings?
    @Published var accounts: Accounts?
    @Published var dropped: [DroppedChat] = []
    /// Suggestions for the new-session form, loaded when the form opens.
    @Published var folders: Folders?
    @Published var configPaths: ConfigPaths?

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
        var restoreConversation = true
        /// "" for no setup, "custom" for setupText as a command, or a recipe ID.
        var setupID = ""
        /// The custom setup command, or the recipe's input, like a URL.
        var setupText = ""
        /// Whether the form shows Name, Command, Setup, and the restore toggles.
        var showOptions = false
    }

    /// The "Restore sessions after the Mac starts" setting. GeneralPane
    /// changes it with @AppStorage, which only updates views, so the model
    /// reads it from UserDefaults when it needs it.
    static let restoreOnLaunchKey = "restoreOnLaunch"
    var restoreOnLaunch: Bool {
        UserDefaults.standard.object(forKey: Model.restoreOnLaunchKey) as? Bool ?? true
    }

    nonisolated static let tend = Bundle.main.url(forResource: "tend", withExtension: nil)?.path
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/tend").path

    /// Where "Install command-line tool" links `tend`.
    nonisolated static let cliLink = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/tend")

    /// The PATH tend runs with: Homebrew's folders, so `/usr/bin/env python3`
    /// finds Homebrew's Python first, then the app's own PATH. tend adds
    /// the other folders it needs itself.
    nonisolated static let path = (["/opt/homebrew/bin", "/usr/local/bin"]
        + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        .joined(separator: ":")

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
            refreshError = problem
            return
        }
        Task {
            // Restore only on the first launch since the Mac started. A
            // relaunch, like after a crash, checks in and changes nothing.
            if restoreOnLaunch { await run(["restore", "--once"]) }
            await loadSettings()
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    var tracked: [Session] { sessions.filter(\.managed) }
    var untracked: [Session] { sessions.filter { !$0.managed } }
    var runningCount: Int { sessions.filter { $0.state == .running }.count }
    /// Tracked sessions that `tend restore` would start.
    var restorable: [Session] { tracked.filter { $0.autostart && $0.state == .stopped } }
    var waitingCount: Int { sessions.filter { $0.app?.question != nil }.count }
    var anyBusy: Bool { sessions.contains { $0.app?.status == "busy" } }
    var anyQuestion: Bool { waitingCount > 0 }
    var accountProblems: [AccountStatus] { accounts?.watched.filter { !$0.ok } ?? [] }

    var cliInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: Model.cliLink.path)) != nil
            || FileManager.default.fileExists(atPath: Model.cliLink.path)
    }

    /// Run tend. Returns its output, or the error it printed.
    func call(_ args: [String]) async -> TendResult {
        await Task.detached { () -> TendResult in
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
                return TendResult(output: nil, error: "Couldn't run \(Model.tend): \(error.localizedDescription)")
            }
            // Read standard error on another thread, so a full stderr pipe
            // can't block tend while this thread waits for stdout to end.
            let errReader = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = await errReader.value
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let message = String(decoding: errData, as: UTF8.self)
                return TendResult(output: nil, error: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return TendResult(output: data, error: nil)
        }.value
    }

    /// Run tend for an action. If it fails, show its error until you close
    /// it or take another action.
    @discardableResult
    func run(_ args: [String]) async -> Data? {
        let result = await call(args)
        if let message = result.error { error = message }
        return result.output
    }

    /// Read what changes on its own: the sessions, other accounts, and
    /// dropped conversations. Tend runs this every 5 seconds.
    func refresh() async {
        var outputs: [Data] = []
        for args in [["ls", "--json"], ["accounts", "--json"], ["dropped", "--json"]] {
            let result = await call(args)
            guard let data = result.output else {
                refreshError = result.error
                return
            }
            outputs.append(data)
        }
        do {
            sessions = try decodeTend([Session].self, from: outputs[0])
            accounts = try decodeTend(Accounts.self, from: outputs[1])
            dropped = try decodeTend([DroppedChat].self, from: outputs[2])
            checkAccounts()
            refreshError = nil
        } catch {
            refreshError = "Couldn't read tend's output: \(error.localizedDescription)"
        }
    }

    /// Read what changes only when you change it: the apps, recipes,
    /// terminal settings, and where the config is. Tend runs this when it
    /// opens and after each action.
    func loadSettings() async {
        if let data = await run(["apps", "--json"]) { apps = (try? decodeTend([AppProfile].self, from: data)) ?? apps }
        if let data = await run(["recipes", "--json"]) { recipes = (try? decodeTend([Recipe].self, from: data)) ?? recipes }
        if let data = await run(["config", "--json"]) { configPaths = try? decodeTend(ConfigPaths.self, from: data) }
        await loadTerminal()
    }

    /// Load the new-session form's folder suggestions.
    func loadFolders() async {
        guard let data = await run(["folders", "--json"]) else { return }
        folders = try? decodeTend(Folders.self, from: data)
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
        terminal = try? decodeTend(TerminalSettings.self, from: data)
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
        if d.appID != nil && !d.restoreConversation { args.append("--no-restore-conversation") }
        let launch = apps.first { $0.id == d.appID }?.launch
        if d.command != launch { args += ["--command", d.command] }
        let text = d.setupText.trimmingCharacters(in: .whitespaces)
        switch d.setupID {
        case "": break
        case "custom": if !text.isEmpty { args += ["--setup", text] }
        default:
            args += ["--recipe", d.setupID]
            if !text.isEmpty { args += ["--input", text] }
        }
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
            // Actions on apps and recipes change the settings.
            if ["apps", "recipes"].contains(args.first) { await loadSettings() }
            busy = false
        }
    }

    /// Start the new-session form with the app and folder you used last.
    func newDraft() {
        let defaults = UserDefaults.standard
        let launchable = apps.filter { $0.enabled && $0.launch != nil }
        let lastApp = defaults.string(forKey: "lastApp")
        let app = launchable.first { $0.id == lastApp } ?? (lastApp == "" ? nil : launchable.first)
        draft = Draft(
            appID: app?.id,
            dir: defaults.string(forKey: "lastDir")
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            command: app?.launch ?? "",
            showOptions: app == nil)
        Task { await loadFolders() }
    }
}

/// A path with the home folder shown as ~.
func shortPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

@main
struct TendApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Image(systemName: model.anyBusy ? "terminal.fill" : "terminal")
            if model.anyQuestion {
                Image(systemName: "questionmark.bubble")
            }
            if !model.accountProblems.isEmpty {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
            }
            if model.runningCount > 0 { Text("\(model.runningCount)") }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

// MARK: - Panel

/// The menu bar panel: messages, the new-session form, and the sessions.
/// Settings live in their own window.
struct ContentView: View {
    @EnvironmentObject var model: Model
    @Environment(\.openSettings) private var openSettings
    @State private var spins = 0.0

    /// The Restore button's tooltip, which names the sessions it starts.
    var restoreHelp: String {
        let names = model.restorable.map(\.name).joined(separator: ", ")
        let which = model.restorable.count == 1
            ? "the tracked session that's set to restore and isn't running"
            : "the \(model.restorable.count) tracked sessions that are set to restore and aren't running"
        return "Start \(which): \(names). Sessions that can resume, like Claude, reattach to their last conversation."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            messages

            if model.draft != nil { NewSessionForm() }

            if model.sessions.isEmpty && model.draft == nil && model.refreshError == nil {
                emptyState
            }

            if !model.tracked.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Sessions") {
                        if !model.restorable.isEmpty {
                            Button("Restore \(model.restorable.count)") { model.act(["restore"]) }
                                .help(restoreHelp)
                        }
                    }
                    ForEach(model.tracked) { SessionRow(session: $0) }
                }
            }

            if !model.untracked.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Not tracked") {
                        Button("Track all") { model.act(["snapshot"]) }
                            .help("Add every untracked tmux session to the list, so Tend restores it.")
                    }
                    ForEach(model.untracked) { SessionRow(session: $0) }
                }
            }

            if let watched = model.accounts?.watched, !watched.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader("Other accounts") { EmptyView() }
                    ForEach(watched) { AccountRow(account: $0) }
                }
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 400)
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("Tend").font(.headline)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button {
                withAnimation(.easeInOut(duration: 0.6)) { spins += 1 }
                model.act(["ls"])
            } label: {
                Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spins * 360))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Check every session now, and save the latest session ID of apps that can resume, like Claude. Tend also does this every 5 seconds.")
            Button { model.draft == nil ? model.newDraft() : (model.draft = nil) } label: {
                Image(systemName: model.draft == nil ? "plus" : "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("n")
            .help(model.draft == nil
                  ? "Start a new session: pick an app and a folder."
                  : "Cancel the new session.")
        }
    }

    @ViewBuilder var messages: some View {
        let any = model.refreshError != nil || model.error != nil || !model.accountProblems.isEmpty
            || !model.dropped.isEmpty
        if any {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = model.refreshError {
                    Banner(text: problem, systemImage: "exclamationmark.triangle.fill", tint: .red,
                           help: "Tend can't read its sessions. It tries again every 5 seconds.")
                }
                if let error = model.error {
                    Banner(text: error, systemImage: "xmark.octagon.fill", tint: .red,
                           help: "The last action failed.") { model.error = nil }
                }
                if !model.dropped.isEmpty { DroppedBanner(chats: model.dropped) }
                ForEach(model.accountProblems) { account in
                    Banner(text: account.problem ?? "\(account.name) needs attention.",
                           systemImage: "person.crop.circle.badge.exclamationmark", tint: .orange,
                           help: "To log \(account.name) in, choose their account from the user menu in the menu bar or Control Center. Their Tend then restarts their sessions.")
                }
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 6) {
            Text("No sessions yet").font(.callout).fontWeight(.medium)
            Text("Start an app in a folder. Tend also lists tmux sessions you start yourself.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New session") { model.newDraft() }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    var footer: some View {
        HStack {
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            .help("The apps Tend recognizes, the terminal it opens sessions in, startup, and other accounts")
            Spacer()
            Button("Quit Tend") { NSApp.terminate(nil) }
                .help("Quit the menu bar app. Your tmux sessions keep running.")
        }
        .buttonStyle(.borderless)
    }
}

/// A message across the top of the panel, with an optional close button.
struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    var help: String = ""
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close this message.")
            }
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
    }
}

/// Conversations that lost their connection when their session restarted,
/// as Claude Remote Control chats do after a reboot, with a way back.
struct DroppedBanner: View {
    @EnvironmentObject var model: Model
    let chats: [DroppedChat]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                    .foregroundStyle(.orange)
                Text(chats.count == 1
                     ? "A chat lost its connection when its session restarted."
                     : "\(chats.count) chats lost their connection when their sessions restarted.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if chats.count > 1 {
                    Button("Dismiss all") { model.act(["dismiss", "--all"]) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .help("Take every chat off this list. Their conversations stay on this Mac.")
                }
            }
            ForEach(chats) { chat in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.label ?? chat.id).lineLimit(1)
                        Text("\(chat.session) · \(ago(chat.droppedAt))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .help(chat.id)
                    Spacer(minLength: 8)
                    Button("Recover") { model.act(["recover", chat.session, chat.id]) }
                        .controlSize(.small)
                        .help("Reopen this conversation in a new session in the same folder, connected to the Claude app. Tasks it was running in the background don't come back, so ask it to start them again.")
                    Button { model.act(["dismiss", chat.session, chat.id]) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Take this chat off the list. Its conversation stays on this Mac.")
                }
                .padding(.leading, 24)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    func ago(_ t: Int) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(t)), relativeTo: Date())
    }
}

/// A small heading over a group of rows, with room for a button.
/// A quiet line for a watched account in the panel: whether it's logged in,
/// and a light that's green while its Tend runs. Problems also show as
/// banners at the top of the panel.
struct AccountRow: View {
    let account: AccountStatus

    var body: some View {
        HStack(spacing: 6) {
            Text(account.name)
            Text(account.loggedIn ? "logged in" : "not logged in")
            Spacer()
            if account.loggedIn {
                Circle().fill(account.tendRunning ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(account.tendRunning ? "Tend running" : "Tend not running")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .help(account.problem ?? "\(account.name) is logged in and their Tend is running, so their sessions restart if they stop.")
    }
}

/// The Restore conversation icon: a speech bubble, slashed when the setting is
/// off. It's drawn at 90% and one weight heavier, so it matches the
/// `autostartstop` icon beside it in size and stroke.
struct ConversationIcon: View {
    let off: Bool

    var body: some View {
        Group {
            if off {
                SlashedSymbol(name: "bubble.left", strokeScale: 1 / 0.9)
            } else {
                Image(systemName: "bubble.left")
            }
        }
        .fontWeight(.medium)
        .scaleEffect(0.9)
    }
}

/// An SF Symbol with a slash drawn like Apple's `.slash` variants, for
/// symbols that have none, like `bubble.left`. The geometry was measured from
/// `flag.slash`, `bell.slash`, and `autostartstop.slash`: a round-capped
/// stroke at 45 degrees, 0.072 of the point size wide, with a gap of 0.07 cut
/// on each side. It starts a little above the symbol's top edge and runs
/// into the bottom-right corner.
struct SlashedSymbol: View {
    let name: String
    /// Multiplies the slash's stroke width, to match a symbol drawn heavier.
    var strokeScale: CGFloat = 1

    /// The point size the symbol was drawn at, from its rendered height.
    static func pointSize(of name: String, height: CGFloat) -> CGFloat {
        let probe: CGFloat = 100
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: probe, weight: .regular)),
              image.size.height > 0 else { return height }
        return height / (image.size.height / probe)
    }

    /// The slash's center line, stroke width, and gap, for a symbol of this size.
    func slash(_ size: CGSize) -> (line: Path, stroke: CGFloat, gap: CGFloat) {
        let pt = SlashedSymbol.pointSize(of: name, height: size.height)
        let half = pt * 0.6 / 2.squareRoot()
        let extra = pt * 0.1 / 2.squareRoot()
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - pt * 0.13)
        let line = Path { p in
            p.move(to: CGPoint(x: center.x - half, y: center.y - half))
            p.addLine(to: CGPoint(x: center.x + half + extra, y: center.y + half + extra))
        }
        return (line, pt * 0.072 * strokeScale, pt * 0.07)
    }

    var body: some View {
        Image(systemName: name)
            .mask {
                Canvas { context, size in
                    let s = slash(size)
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    context.blendMode = .destinationOut
                    context.stroke(s.line, with: .color(.black),
                                   style: StrokeStyle(lineWidth: s.stroke + 2 * s.gap, lineCap: .round))
                }
            }
            .overlay {
                GeometryReader { g in
                    let s = slash(g.size)
                    s.line.stroke(style: StrokeStyle(lineWidth: s.stroke, lineCap: .round))
                }
            }
            .accessibilityLabel("\(name), off")
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Spacer()
            trailing.font(.caption).buttonStyle(.borderless)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}

/// The form behind the plus button. It runs `tend new`, which tracks the
/// session and starts it.
struct NewSessionForm: View {
    @EnvironmentObject var model: Model

    /// The width of the form's label column, so the fields line up.
    static let labelWidth: CGFloat = 64

    var launchable: [AppProfile] { model.apps.filter { $0.enabled && $0.launch != nil } }

    /// Folders you've used, and the folders next to them (your other
    /// projects), most recently changed first, from `tend folders`.
    var suggestions: (recent: [String], nearby: [String]) {
        (model.folders?.recent ?? [], Array((model.folders?.nearby ?? []).prefix(40)))
    }

    var body: some View {
        if let draft = model.draft {
            let binding = Binding { model.draft ?? draft } set: { model.draft = $0 }
            VStack(alignment: .leading, spacing: 10) {
                Text("New session").font(.subheadline).fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("App")
                        Picker("App", selection: binding.appID) {
                            ForEach(launchable) { app in
                                if let image = AppIcons.image(app.icon) {
                                    Label { Text(app.title) } icon: { Image(nsImage: image) }.tag(Optional(app.id))
                                } else {
                                    Text(app.title).tag(Optional(app.id))
                                }
                            }
                            Text("Other command").tag(String?.none)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: draft.appID) { _, id in
                            model.draft?.command = launchable.first { $0.id == id }?.launch ?? ""
                            if id == nil { model.draft?.showOptions = true }
                        }
                        .help("The app to run. Add apps, and their launch commands, in Settings.")
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("Folder")
                        HStack {
                            Text(shortPath(draft.dir)).lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(draft.dir)
                            Menu("Choose") {
                                let s = suggestions
                                Section("Recent") {
                                    ForEach(s.recent, id: \.self) { d in Button(shortPath(d)) { model.draft?.dir = d } }
                                }
                                Section("Nearby") {
                                    ForEach(s.nearby, id: \.self) { d in Button(shortPath(d)) { model.draft?.dir = d } }
                                }
                                Divider()
                                Button("Other folder…", action: chooseFolder)
                            }
                            .fixedSize()
                            .help("Recent folders, the folders next to them, or any folder")
                        }
                    }

                    if draft.showOptions {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            label("Name")
                            TextField("Name", text: binding.name,
                                      prompt: Text((draft.dir as NSString).lastPathComponent))
                                .labelsHidden()
                                .help("The tmux session name. If you leave it empty, Tend uses the folder name, plus a number if that name is taken.")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            label("Command")
                            TextField("Command", text: binding.command)
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                                .help("The command Tend types into the new session's shell")
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            label("Setup")
                            Picker("Setup", selection: binding.setupID) {
                                Text("None").tag("")
                                ForEach(model.recipes) { Text($0.title).tag($0.id) }
                                Text("Custom command").tag("custom")
                            }
                            .labelsHidden()
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: draft.setupID) { _, _ in model.draft?.setupText = "" }
                            .help("Something to run once in the folder before the app starts, like cloning a repository. Restarts don't run it again.")
                        }
                        if let field = setupField {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                label(field.label)
                                TextField(field.label, text: binding.setupText, prompt: Text(field.prompt))
                                    .labelsHidden()
                                    .font(.system(.body, design: .monospaced))
                                    .help(field.help)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Color.clear.frame(width: NewSessionForm.labelWidth, height: 0)
                            Toggle(isOn: binding.autostart) { Label("Restore at login", systemImage: "autostartstop") }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("Start this session again when Tend restores sessions")
                        }
                        if draft.appID != nil {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Color.clear.frame(width: NewSessionForm.labelWidth, height: 0)
                                Toggle(isOn: binding.restoreConversation) { Label("Restore conversation", systemImage: "bubble.left") }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("Bring back the conversation when the session restarts. Turn this off to start the plain command every time, with nothing to recover if a conversation is lost.")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button {
                        model.draft?.showOptions.toggle()
                    } label: {
                        Label("Options", systemImage: draft.showOptions ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Name, command, setup, and what to restore")
                    Spacer()
                    Button("Cancel") { model.draft = nil }
                    Button("Start") { model.create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.dir.isEmpty || draft.command.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (setupField != nil && draft.setupText.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
            .frame(width: NewSessionForm.labelWidth, alignment: .trailing)
    }

    /// The text field the chosen setup needs, if any.
    var setupField: (label: String, prompt: String, help: String)? {
        guard let id = model.draft?.setupID, !id.isEmpty else { return nil }
        if id == "custom" {
            return ("Setup", "git init", "A shell command Tend runs in the folder before the app starts")
        }
        guard let r = model.recipes.first(where: { $0.id == id }), r.needsInput else { return nil }
        let label = r.input ?? "Input"
        return (label, label, "Fills in {input} in: \(r.setup)")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the new session"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.draft?.dir ?? NSHomeDirectory())
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { model.draft?.dir = url.path }
    }
}

/// One session. The leading icon shows the app and, in its badge, the
/// state. The main action always shows; the others show on hover, or always
/// if you turn that on in Settings. Restart and Start fresh ask first.
struct SessionRow: View {
    @EnvironmentObject var model: Model
    @AppStorage("alwaysShowRowButtons") private var alwaysShowButtons = false
    @State private var hovering = false
    @State private var confirming: Confirm?
    let session: Session

    enum Confirm { case restart, fresh }

    var question: AppInfo.Question? { session.app?.question }

    /// Orange means the session needs you. Nothing else uses it.
    var badge: Color {
        if question != nil { return .orange }
        switch session.state {
        case .running: return .green
        case .exited: return .yellow
        default: return .gray
        }
    }

    var status: (text: String, color: Color) {
        switch session.state {
        case .running:
            if let s = session.app?.status { return (s, s == "busy" ? .blue : .secondary) }
            return ("running", .secondary)
        case .exited: return ("exited", .secondary)
        default: return ("stopped", .secondary)
        }
    }

    var stateHint: String {
        var hint: String
        switch session.state {
        case .running: hint = "\(session.name) is running."
        case .exited: hint = "\(session.name)'s command exited. The tmux session is still open at a shell prompt."
        default: hint = "\(session.name) isn't running."
        }
        if let app = session.app {
            hint += " It runs \(app.name)" + (app.status.map { ", which is \($0)." } ?? ".")
        }
        if question != nil { hint += " It's waiting for your answer." }
        return hint
    }

    /// The folder, or its parent when the folder's name is the session's name.
    var folder: String {
        if session.namedAfterDir {
            return shortPath((session.dir as NSString).deletingLastPathComponent) + "/"
        }
        return shortPath(session.dir)
    }

    var details: String {
        "Folder: \(shortPath(session.dir))\nCommand: \(session.command ?? "shell")"
            + (!session.restoreConversation
                ? "\nStarts its command every time. Tend doesn't bring back its conversation."
                : session.resume.map { "\nResumes with: \($0)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(session.name).fontWeight(.medium).lineLimit(1)
                        settingIcons
                    }
                    Text(folder).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                        .help(details)
                }
                Spacer(minLength: 8)
                trailing
            }
            if let q = question { questionCard(q) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering ? Color.primary.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .task(id: confirming) {
            // A confirmation you don't act on goes away by itself.
            guard confirming != nil, (try? await Task.sleep(for: .seconds(6))) != nil else { return }
            confirming = nil
        }
    }

    var leading: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = AppIcons.image(session.app?.icon, size: 18) {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "terminal").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .opacity(session.state == .stopped ? 0.45 : 1)
            // Cut a gap around the dot out of the icon, rather than drawing a
            // ring, so the panel's material shows through.
            .mask {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle()
                    Circle().frame(width: 10, height: 10)
                        .offset(x: 3.5, y: 3.5)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            Circle().fill(badge)
                .frame(width: 7, height: 7)
                .offset(x: 2, y: 2)
        }
        .help(stateHint)
    }

    @ViewBuilder var trailing: some View {
        if let c = confirming {
            HStack(spacing: 6) {
                Button("Cancel") { confirming = nil }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button(c == .fresh ? "Start fresh" : "Restart", role: .destructive) {
                    confirming = nil
                    model.act(c == .fresh ? ["restart", session.name, "--fresh"] : ["restart", session.name])
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help(c == .fresh
                      ? "Stop \(session.name) and start its command again, without reattaching to its last session."
                      : restartHelp)
            }
        } else {
            HStack(spacing: 4) {
                // Hidden, not removed, so the row doesn't shift on hover.
                let show = hovering || alwaysShowButtons
                HStack(spacing: 4) { secondaryButtons }
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
                Text(status.text).font(.caption).foregroundStyle(status.color)
                    .padding(.horizontal, 2)
                primaryButton
            }
        }
    }

    var restartHelp: String {
        session.resume != nil
            ? "Stop \(session.name) and start it again, reattached to the same session."
            : "Stop \(session.name) and start it again."
    }

    @ViewBuilder var primaryButton: some View {
        if session.state == .stopped {
            icon("play.fill", session.resume != nil
                 ? "Start \(session.name) and reattach to its last session: \(session.resume!)"
                 : "Start \(session.name).") { model.act(["start", session.name]) }
        } else {
            icon("macwindow", "Open \(session.name) in a new terminal window.") { model.act(["open", session.name]) }
        }
    }

    @ViewBuilder var secondaryButtons: some View {
        if session.state != .stopped {
            if session.managed {
                icon("arrow.triangle.2.circlepath", restartHelp + " Tend asks first.") { confirming = .restart }
            } else {
                icon("plus.circle", "Track \(session.name), so Tend restores it.") { model.act(["snapshot", session.name]) }
            }
            icon("stop.fill", "Stop \(session.name) by closing its tmux session." + (session.managed ? " It stays on the list." : "")) { model.act(["stop", session.name]) }
        }
    }

    func questionCard(_ q: AppInfo.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(q.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.bubble").foregroundStyle(.orange)
            }
            .font(.callout)
            HStack(spacing: 6) {
                Spacer()
                ForEach(q.answers, id: \.id) { a in
                    Button(a.label) { model.act(["answer", session.name, a.id]) }
                        .controlSize(.small)
                        .help("Answer \(session.name)'s question: \(a.label)")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder var menu: some View {
        if session.state == .stopped {
            Button("Start") { model.act(["start", session.name]) }
        } else {
            Button("Open in terminal") { model.act(["open", session.name]) }
        }
        if session.managed {
            Divider()
            if session.state != .stopped {
                Button("Restart") { confirming = .restart }
            }
            Button("Start fresh") { confirming = .fresh }
            Button(session.autostart ? "Don't restore at login" : "Restore at login") {
                model.act(["autostart", session.name, session.autostart ? "off" : "on"])
            }
            if session.app != nil || !session.restoreConversation {
                Button(session.restoreConversation ? "Don't restore conversation" : "Restore conversation") {
                    model.act(["restore-conversation", session.name, session.restoreConversation ? "off" : "on"])
                }
            }
        }
        if session.state != .stopped {
            Button("Stop") { model.act(["stop", session.name]) }
        }
        Divider()
        if session.managed {
            Button("Stop tracking") { model.act(["rm", session.name]) }
        } else {
            Button("Track") { model.act(["snapshot", session.name]) }
        }
    }

    /// Whether the session can resume, so Restore conversation means something.
    var canResume: Bool { session.app != nil || session.resume != nil || !session.restoreConversation }

    /// An icon for each restore setting. A setting that's off always shows,
    /// slashed. Settings that are on show, lighter, while you hover.
    @ViewBuilder var settingIcons: some View {
        if session.managed {
            let show = hovering || alwaysShowButtons
            HStack(spacing: 3) {
                if !session.autostart {
                    Image(systemName: "autostartstop.slash")
                        .help("Tend doesn't start \(session.name) when it restores sessions. Right-click the row to change that.")
                } else if show {
                    Image(systemName: "autostartstop").foregroundStyle(.tertiary)
                        .help("Tend starts \(session.name) when it restores sessions, like after the Mac restarts.")
                }
                if !session.restoreConversation {
                    ConversationIcon(off: true)
                        .help("\(session.name) starts its command every time. Tend doesn't bring back its conversation or list it as dropped. Right-click the row to change that.")
                } else if show && canResume {
                    ConversationIcon(off: false).foregroundStyle(.tertiary)
                        .help("Tend brings back \(session.name)'s conversation when it restarts.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Banner(text: error, systemImage: "xmark.octagon.fill", tint: .red,
                       help: "The last action failed.") { model.error = nil }
                    .padding([.horizontal, .top], 12)
            }
            TabView {
                GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
                AppsPane().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                TerminalPane().tabItem { Label("Terminal", systemImage: "terminal") }
                AccountsPane().tabItem { Label("Accounts", systemImage: "person.2") }
            }
        }
        .frame(width: 500, height: 380)
    }
}

struct GeneralPane: View {
    @EnvironmentObject var model: Model
    @AppStorage("alwaysShowRowButtons") private var alwaysShowButtons = false
    @AppStorage(Model.restoreOnLaunchKey) private var restoreOnLaunch = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cliInstalled = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Tend at login", isOn: $openAtLogin)
                    .help("Open Tend when you log in. With the setting below, this restores your sessions after the Mac starts.")
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.error = "Couldn't change the login item: \(error.localizedDescription)"
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Restore sessions after the Mac starts", isOn: $restoreOnLaunch)
                    .help("The first time Tend opens after the Mac starts, start every tracked session that's set to restore. If you quit Tend or it crashes, your sessions keep running, and opening Tend again doesn't start or stop anything.")
            }
            Section("Panel") {
                Toggle("Always show session buttons", isOn: $alwaysShowButtons)
                    .help("Show every row's buttons all the time, not only when the pointer is over the row. The Open or Start button always shows.")
            }
            Section("Command line") {
                LabeledContent("tend") {
                    if cliInstalled {
                        Text(shortPath(Model.cliLink.path)).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Button("Install") {
                            model.installCLI()
                            cliInstalled = model.cliInstalled
                        }
                        .disabled(Model.setupProblem != nil)
                        .help("Link tend into ~/.local/bin, so you can run it in a terminal and over ssh. Add ~/.local/bin to your PATH if it isn't there already.")
                    }
                }
                LabeledContent("Config") {
                    if let path = model.configPaths?.config {
                        let name = (path as NSString).lastPathComponent
                        Button("Open \(name)") {
                            if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                                model.error = "Couldn't open \(path). Tend creates it when you track a session."
                            }
                        }
                        .help("Open \(shortPath(path)), the list of tracked sessions, apps, and settings.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cliInstalled = model.cliInstalled }
    }
}

/// The apps tend recognizes. Turn one off to stop recognizing it, or add any
/// program by choosing its executable.
struct AppsPane: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Form {
            Section {
                ForEach(model.apps) { app in
                    Toggle(isOn: Binding(
                        get: { app.enabled },
                        set: { model.act(["apps", $0 ? "enable" : "disable", app.id]) }
                    )) {
                        HStack(spacing: 8) {
                            AppIconView(spec: app.icon, size: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 6) {
                                    Text(app.title)
                                    if app.builtin {
                                        Text("Built in").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(app.rules).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .help("Recognize processes that match: \(app.rules)" + (app.builtin ? "" : ". Right-click to remove it."))
                    .contextMenu {
                        if !app.builtin {
                            Button("Remove") { model.act(["apps", "rm", app.id]) }
                        }
                    }
                }
            } header: {
                Text("The programs Tend looks for in each tmux session")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add app…", action: addApp)
                        .help("Choose a program. Tend then recognizes it when it runs in a tmux session.")
                }
            }
        }
        .formStyle(.grouped)
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
        // For a .app bundle, use its main executable, and its icon.
        var icon: [String] = []
        if url.pathExtension == "app", let bundle = Bundle(url: url), let exe = bundle.executableURL {
            icon = ["--icon", bundle.bundleIdentifier ?? url.path]
            url = exe
        }
        model.act(["apps", "add", url.path] + icon)
    }
}

/// How the open button opens a session: which terminal app, and which
/// command it runs there. Use tmux control mode for iTerm2's tmux integration.
struct TerminalPane: View {
    @EnvironmentObject var model: Model
    @State private var custom = ""
    @State private var editingCustom = false

    var body: some View {
        Form {
            if let t = model.terminal {
                Section {
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
                } header: {
                    Text("How the open button opens a session")
                } footer: {
                    if t.mode == "control" && t.app != "iTerm" {
                        Label("tmux -CC needs iTerm2. Terminal shows control mode as raw text.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .onAppear { if t.mode == "custom" { custom = t.attach } }
            } else {
                Text("Tend couldn't read its terminal settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func saveCustom() {
        editingCustom = false
        model.setTerminal(attach: custom)
    }
}

/// Other accounts on this Mac, like a family member's under fast user switching.
/// Tend warns when a watched account isn't logged in or isn't running Tend,
/// because then that account's sessions aren't running.
struct AccountsPane: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Form {
            Section {
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
                    Text("This Mac has no other accounts.").foregroundStyle(.secondary)
                } else if !available.isEmpty {
                    Menu("Watch an account") {
                        ForEach(available, id: \.self) { a in
                            Button(a.name) { model.watchAccount(a.user, true) }
                        }
                    }
                    .fixedSize()
                    .help("Warn me when this account isn't logged in or isn't running Tend. Install Tend in that account too, with Open Tend at login on.")
                }
            } header: {
                Text("Other accounts on this Mac")
            } footer: {
                Text("Tend warns you when a watched account isn't logged in or isn't running Tend, because then that account's sessions aren't running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
