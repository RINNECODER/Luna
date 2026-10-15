import Foundation

/// The environment a Terminal window would have: apps launched from Finder get a bare PATH,
/// so `claude` / `codex` (Homebrew, npm, ~/.local/bin) would not be found without this.
nonisolated enum LoginShellEnvironment {
    static let fallbackDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "~/.local/bin", "~/.claude/local", "~/.npm-global/bin", "~/.bun/bin", "~/.cargo/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    private static let startMarker = "__LUNA_PATH_START__"
    private static let endMarker = "__LUNA_PATH_END__"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPATH: String?

    /// PATH from `zsh -lic`, resolved once and cached; the fallback list if the shell fails.
    static func path() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cachedPATH { return cachedPATH }
        let resolved = merged(shellPATH: runLoginShell(), home: NSHomeDirectory())
        cachedPATH = resolved
        return resolved
    }

    /// The child environment: this process's env with the login PATH and any extras.
    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path()
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Full path of `name` on the login PATH, or nil.
    static func locate(_ name: String, path: String? = nil) -> String? {
        for dir in (path ?? self.path()).split(separator: ":") where !dir.isEmpty {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Pulls PATH out of shell output that may also contain rc-file noise.
    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: startMarker),
              let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex) else { return nil }
        let value = output[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Shell PATH first (user's order wins), then any fallback dirs it lacks; `~` expanded.
    static func merged(shellPATH: String?, home: String) -> String {
        var seen = Set<String>()
        var out: [String] = []
        let fallback = fallbackDirectories.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        for dir in (shellPATH?.split(separator: ":").map(String.init) ?? []) + fallback where !dir.isEmpty {
            if seen.insert(dir).inserted { out.append(dir) }
        }
        return out.joined(separator: ":")
    }

    static func runLoginShell(shell: String = "/bin/zsh", timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '\(startMarker)%s\(endMarker)' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); done.signal() }
        // Read concurrently so a chatty rc file cannot fill the pipe and block the shell.
        var data = Data()
        let reader = DispatchQueue(label: "luna.loginshell.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return parse(String(decoding: data, as: UTF8.self))
    }
}
