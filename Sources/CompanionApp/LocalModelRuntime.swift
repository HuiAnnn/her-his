import Foundation

@MainActor protocol LocalModelStarting: AnyObject {
    func start() throws
    func stop()
}

enum LocalModelStartupError: LocalizedError {
    case notInstalled, launchFailed, notReady
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "没有找到 Ollama，请先安装本机对话引擎。安装后会自动连接。"
        case .launchFailed: return "本机对话引擎未能启动，请在设置中点击“重新连接”重试。"
        case .notReady: return "本机对话引擎还未就绪，请稍后在设置中点击“重新连接”。"
        }
    }
}

/// Owns only the process started by this application, never an existing Ollama server.
@MainActor final class LocalModelRuntime: LocalModelStarting {
    private var process: Process?
    func start() throws {
        if process?.isRunning == true { return }
        let candidates = [
            "/Applications/Ollama.app/Contents/Resources/ollama",
            NSHomeDirectory() + "/Applications/Ollama.app/Contents/Resources/ollama",
            "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw LocalModelStartupError.notInstalled
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve"]
        // Keep the service local and do not inherit cloud credentials or remote endpoints.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(), "OLLAMA_HOST": "127.0.0.1:11434",
            "OLLAMA_NO_CLOUD": "1", "OLLAMA_NOPRUNE": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); self.process = process }
        catch { throw LocalModelStartupError.launchFailed }
    }
    func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
}

@MainActor enum LocalModelConnection {
    static func connect(client: any ModelServing, runtime: any LocalModelStarting,
                        retryDelay: UInt64 = 500_000_000, attempts: Int = 24,
                        cancelled: () -> Bool = { false }, preparing: () -> Void = {}) async throws -> [String] {
        func checkCancellation() throws {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
        }
        try checkCancellation()
        do { return try await client.health() }
        catch {
            try checkCancellation()
            guard isConnectionUnavailable(error) else { throw error }
        }
        preparing()
        try runtime.start()
        for _ in 0..<attempts {
            try await Task.sleep(nanoseconds: retryDelay)
            try checkCancellation()
            do { return try await client.health() }
            catch {
                try checkCancellation()
                guard isConnectionUnavailable(error) else { throw error }
            }
        }
        throw LocalModelStartupError.notReady
    }
    private static func isConnectionUnavailable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code)
    }
}
