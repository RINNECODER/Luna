import Foundation
import Observation

/// Dev mode settings, shared by the panel views (UserDefaults keys).
enum DevPrefs {
    static let panelModeKey = "luna_ai_panel_mode"
    static let agentKey = "luna_dev_agent"
    static let projectKey = "luna_dev_project"
    static let recentProjectsKey = "luna_dev_recent_projects"
    static let modelKey = "luna_dev_model"
    static let resumeKey = "luna_dev_resume"
    static let terminalKey = "luna_dev_terminal"

    static func recentProjects(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: recentProjectsKey) ?? []
    }

    static func remember(project path: String, _ defaults: UserDefaults = .standard) {
        var list = recentProjects(defaults).filter { $0 != path }
        list.insert(path, at: 0)
        defaults.set(Array(list.prefix(8)), forKey: recentProjectsKey)
        defaults.set(path, forKey: projectKey)
    }
}

/// Owns the one active Dev mode CLI session and its thread. App-wide, so the session
/// survives tab switches and the panel being closed.
@MainActor
@Observable
final class DevSessionController {
    static let shared = DevSessionController()

    private(set) var thread: DevThreadState?
    private(set) var isStarting = false
    /// Error from the last start attempt (e.g. the CLI is not installed).
    private(set) var startError: AgentCLIError?
    private(set) var startErrorText: String?
    /// Whether this session was launched with Luna's browser tools (MCP bridge on).
    private(set) var hasBrowserTools = false
    private(set) var projectDir: URL?
    /// Path of each CLI on the login PATH; nil = not checked yet, "" = not found.
    private(set) var installed: [AgentCLIKind: String] = [:]

    private var session: AgentCLISession?
    private var pump: Task<Void, Never>?
    private var resumeStore = AgentCLIResumeStore()

    var isRunning: Bool { thread?.isAlive == true }

    func isInstalled(_ kind: AgentCLIKind) -> Bool? {
        installed[kind].map { !$0.isEmpty }
    }

    /// Looks the CLIs up on the login shell PATH (first call can take a few seconds).
    func refreshInstalled() {
        let names = AgentCLIKind.allCases.map { ($0, $0.executableName) }
        Task.detached(priority: .utility) {
            var found: [AgentCLIKind: String] = [:]
            for (kind, name) in names {
                found[kind] = LoginShellEnvironment.locate(name) ?? ""
            }
            let result = found
            await MainActor.run { DevSessionController.shared.installed = result }
        }
    }

    /// Starts a session, replacing the current one.
    func start(kind: AgentCLIKind, projectDir: URL, model: String?, resume: Bool) async {
        stop()
        isStarting = true
        startError = nil
        startErrorText = nil
        self.projectDir = projectDir
        hasBrowserTools = LunaMCPBridge.shared.isEnabled
        let session = AgentCLISessions.make(kind)
        self.session = session
        var state = DevThreadState(kind: kind)
        let resumeID = resume ? resumeStore.lastSessionID(kind: kind, projectDir: projectDir) : nil
        let trimmedModel = model?.trimmingCharacters(in: .whitespaces)
        do {
            try await session.start(projectDir: projectDir,
                                    model: (trimmedModel?.isEmpty ?? true) ? nil : trimmedModel,
                                    resumeID: resumeID)
        } catch {
            isStarting = false
            startError = error as? AgentCLIError
            startErrorText = error.localizedDescription
            session.close()
            self.session = nil
            return
        }
        guard self.session === session else { return } // replaced while starting
        state.attached()
        thread = state
        isStarting = false
        pump = Task { [weak self] in
            for await event in session.events {
                guard let self, self.session === session else { return }
                self.thread?.apply(event)
                if case .sessionStarted(let id) = event {
                    self.resumeStore.save(id, kind: kind, projectDir: projectDir)
                }
            }
        }
    }

    func send(_ text: String) {
        guard let session, thread?.canSend == true else { return }
        do {
            try session.send(text)
            thread?.userSent(text)
        } catch {
            thread?.note(error: error.localizedDescription)
        }
    }

    func interrupt() {
        session?.interrupt()
    }

    func respond(approvalID: String, decision: CLIApprovalDecision) {
        session?.respond(approvalID: approvalID, decision: decision)
        thread?.decided(approvalID: approvalID, decision)
    }

    /// Ends the session and clears the thread.
    func stop() {
        pump?.cancel()
        pump = nil
        session?.close()
        session = nil
        thread = nil
    }
}
