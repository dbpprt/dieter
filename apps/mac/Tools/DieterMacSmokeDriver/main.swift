import AppKit
import Foundation

private enum SmokeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case failed(String)

    var description: String {
        switch self {
        case .invalidArguments(let message), .failed(let message): message
        }
    }
}

private enum SmokeSuite: String, CaseIterable {
    case core
    case board
    case conversation
    case machine
    case sidebar
    case terminal
    case island
    case workspace

    var timeout: TimeInterval {
        switch self {
        case .core: 240
        case .board: 150
        case .workspace: 180
        case .terminal: 75
        case .conversation: 90
        case .machine: 60
        case .sidebar, .island: 30
        }
    }

    var needsGateway: Bool {
        self != .sidebar && self != .island
    }
}

private struct Options {
    let suite: SmokeSuite
    let app: URL
    let outputRoot: URL

    static func parse(_ arguments: [String]) throws -> Options {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), arguments.indices.contains(index + 1) else {
                throw SmokeError.invalidArguments(
                    "usage: DieterMacSmokeDriver --suite <suite> --app <executable> --output-root <directory>"
                )
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let rawSuite = values["--suite"], let suite = SmokeSuite(rawValue: rawSuite) else {
            throw SmokeError.invalidArguments(
                "unknown or missing suite; expected: \(SmokeSuite.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        guard let app = values["--app"], let outputRoot = values["--output-root"] else {
            throw SmokeError.invalidArguments("--app and --output-root are required")
        }
        return Options(
            suite: suite,
            app: URL(fileURLWithPath: app),
            outputRoot: URL(fileURLWithPath: outputRoot, isDirectory: true)
        )
    }
}

private final class OwnedProcess {
    let process: Process
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle

    init(executable: URL, arguments: [String], output: URL, error: URL, directory: URL? = nil) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        outputHandle = try FileHandle(forWritingTo: output)
        errorHandle = try FileHandle(forWritingTo: error)
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
    }

    deinit {
        try? outputHandle.close()
        try? errorHandle.close()
    }

    func stop(grace: TimeInterval = 5) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.interrupt()
            let interruptDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < interruptDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
}

private final class SmokeRun {
    private let options: Options
    private let repository: URL
    private let output: URL
    private let preferencesSuite: String
    private var gateway: OwnedProcess?
    private var app: OwnedProcess?

    init(options: Options) throws {
        self.options = options
        repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent("apps/mac/Package.swift").path) else {
            throw SmokeError.failed("run the smoke driver from the repository root")
        }
        guard FileManager.default.isExecutableFile(atPath: options.app.path) else {
            throw SmokeError.failed("packaged app executable is missing: \(options.app.path)")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        output = options.outputRoot.appendingPathComponent(
            "\(options.suite.rawValue)-\(formatter.string(from: Date()))-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        preferencesSuite = "com.dbpprt.dieter.smoke.\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    deinit {
        app?.stop()
        gateway?.stop()
        _ = try? Self.runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/defaults"),
            arguments: ["delete", preferencesSuite]
        )
    }

    func run() throws {
        try requireNoRunningApp()
        var endpoint: String?
        var tokenFile: URL?
        if options.suite.needsGateway {
            let connection = try startGateway()
            endpoint = connection.endpoint
            tokenFile = connection.tokenFile
        }

        switch options.suite {
        case .sidebar:
            try runApp(
                phase: "prepare",
                report: output.appendingPathComponent("prepare/report.json"),
                arguments: baseArguments(state: output.appendingPathComponent("state")) + [
                    "--sidebar-ui-smoke", "prepare",
                    "--sidebar-preferences-suite", preferencesSuite,
                    "--ui-smoke-output", output.appendingPathComponent("prepare").path,
                ]
            )
            try runApp(
                phase: "verify",
                report: output.appendingPathComponent("verify/report.json"),
                arguments: baseArguments(state: output.appendingPathComponent("state")) + [
                    "--sidebar-ui-smoke", "verify",
                    "--sidebar-preferences-suite", preferencesSuite,
                    "--ui-smoke-output", output.appendingPathComponent("verify").path,
                ]
            )
        case .terminal:
            let common = try gatewayArguments(endpoint: endpoint, tokenFile: tokenFile)
                + baseArguments(state: output.appendingPathComponent("state"))
                + ["--ui-smoke-output", output.path]
            try runApp(
                phase: "create",
                report: output.appendingPathComponent("create-report.json"),
                arguments: common + ["--terminal-ui-smoke", "create"]
            )
            try runApp(
                phase: "resume",
                report: output.appendingPathComponent("report.json"),
                arguments: common + ["--terminal-ui-smoke", "resume"]
            )
        case .island:
            try Self.runCommand(
                executable: URL(fileURLWithPath: "/usr/bin/defaults"),
                arguments: ["write", preferencesSuite, "DieterAppearance", "-string", "dark"]
            )
            try runApp(
                phase: "island",
                report: output.appendingPathComponent("report.json"),
                arguments: baseArguments(state: output.appendingPathComponent("state")) + [
                    "--island-ui-smoke",
                    "--island-ui-smoke-output", output.path,
                ]
            )
        case .core, .board, .conversation, .machine, .workspace:
            var arguments = try gatewayArguments(endpoint: endpoint, tokenFile: tokenFile)
                + baseArguments(state: output.appendingPathComponent("state"))
            switch options.suite {
            case .core:
                arguments += [
                    "--ui-smoke",
                    "--ui-smoke-output", output.path,
                    "--ui-smoke-offline-trigger", output.appendingPathComponent("daemon-offline").path,
                ]
            case .board:
                arguments += [
                    "--ui-smoke", "--board-stress-ui-smoke", "--lane-sort-ui-smoke",
                    "--ui-smoke-output", output.path,
                    "--ui-smoke-offline-trigger", output.appendingPathComponent("daemon-offline").path,
                ]
            case .conversation:
                arguments += ["--conversation-ui-smoke", "--ui-smoke-output", output.path]
            case .machine:
                arguments += ["--machine-ui-smoke", "--machine-ui-smoke-output", output.path]
            case .workspace:
                arguments += ["--workspace-ui-smoke", "--ui-smoke-output", output.path]
            default: break
            }
            try runApp(
                phase: options.suite.rawValue,
                report: output.appendingPathComponent("report.json"),
                arguments: arguments
            )
        }

        gateway?.stop()
        gateway = nil
        let disposableRuntime = output
            .appendingPathComponent("fixture-home/dieter/runtime", isDirectory: true)
        if FileManager.default.fileExists(atPath: disposableRuntime.path) {
            try FileManager.default.removeItem(at: disposableRuntime)
        }
        try requireNoRunningApp()
        print(output.path)
    }

    private func baseArguments(state: URL) -> [String] {
        [
            "--dieter-state-root", state.path,
            "--appearance-defaults-suite", preferencesSuite,
        ]
    }

    private func gatewayArguments(endpoint: String?, tokenFile: URL?) throws -> [String] {
        guard let endpoint, let tokenFile else {
            throw SmokeError.failed("isolated gateway connection was not initialized")
        }
        return [
            "--dieter-endpoint", endpoint,
            "--dieter-access-token-file", tokenFile.path,
        ]
    }

    private func startGateway() throws -> (endpoint: String, tokenFile: URL) {
        let tools = repository.appendingPathComponent("apps/mac/.build/smoke-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let gatewayExecutable = tools.appendingPathComponent("isolated-gateway")
        try Self.runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["go", "build", "-o", gatewayExecutable.path, "./scripts/isolated-gateway"],
            directory: repository
        )

        let environmentFile = output.appendingPathComponent("gateway.env")
        let gatewayLog = output.appendingPathComponent("gateway.log")
        var arguments = [
            "--addr", "127.0.0.1:0",
            "--home", output.appendingPathComponent("fixture-home").path,
        ]
        if options.suite == .core || options.suite == .board {
            arguments += ["--offline-trigger", output.appendingPathComponent("daemon-offline").path]
        }
        if options.suite == .board {
            arguments.append("--board-stress-fixture")
        }
        gateway = try OwnedProcess(
            executable: gatewayExecutable,
            arguments: arguments,
            output: environmentFile,
            error: gatewayLog,
            directory: repository
        )

        let deadline = Date().addingTimeInterval(45)
        var values: [String: String] = [:]
        while Date() < deadline {
            if gateway?.process.isRunning != true {
                throw SmokeError.failed("isolated gateway exited before READY; see \(gatewayLog.path)")
            }
            values = Self.environmentValues(at: environmentFile)
            if values["READY"] == "" { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard values["READY"] == "",
              let address = values["DIETER_ISOLATED_ADDR"],
              let token = values["DIETER_ISOLATED_TOKEN"] else {
            throw SmokeError.failed("isolated gateway did not become ready; see \(gatewayLog.path)")
        }
        let tokenFile = output.appendingPathComponent("session-token")
        try Data(token.utf8).write(to: tokenFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return ("http://\(address)", tokenFile)
    }

    private func runApp(phase: String, report: URL, arguments: [String]) throws {
        try requireNoRunningApp()
        try FileManager.default.createDirectory(
            at: report.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let appLog = output.appendingPathComponent("app-\(phase).log")
        let appErrorLog = output.appendingPathComponent("app-\(phase).stderr.log")
        app = try OwnedProcess(
            executable: options.app,
            arguments: arguments,
            output: appLog,
            error: appErrorLog,
            directory: repository
        )
        let appPID = app?.process.processIdentifier ?? 0
        let deadline = Date().addingTimeInterval(options.suite.timeout)
        while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
            guard app?.process.isRunning == true else {
                throw SmokeError.failed(
                    "DieterMac PID \(appPID) exited before writing \(report.lastPathComponent); "
                        + "see \(appLog.path) and \(appErrorLog.path)"
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard FileManager.default.fileExists(atPath: report.path) else {
            throw SmokeError.failed(
                "smoke phase \(phase) timed out; see \(appLog.path) and \(appErrorLog.path)"
            )
        }
        let data = try Data(contentsOf: report)
        guard let results = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw SmokeError.failed("invalid smoke report: \(report.path)")
        }
        let failures = results.filter { $0.value.lowercased().hasPrefix("failed") }
        print(String(data: data, encoding: .utf8) ?? "")

        var exitDeadline = Date().addingTimeInterval(3)
        while app?.process.isRunning == true && Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if app?.process.isRunning == true {
            _ = NSRunningApplication(processIdentifier: appPID)?.terminate()
            exitDeadline = Date().addingTimeInterval(5)
            while app?.process.isRunning == true && Date() < exitDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if app?.process.isRunning == true {
            app?.stop()
        }
        if app?.process.isRunning == true {
            throw SmokeError.failed("smoke phase \(phase) wrote a report but PID \(appPID) refused targeted termination")
        }
        app = nil
        if !failures.isEmpty {
            let summary = failures.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "; ")
            throw SmokeError.failed("smoke phase \(phase) failed: \(summary)")
        }
    }

    private func requireNoRunningApp() throws {
        let result = try Self.captureCommand(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-x", "DieterMac"]
        )
        if result.status == 1 || result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        if result.status != 0 {
            throw SmokeError.failed("could not inventory DieterMac processes: \(result.output)")
        }
        var details: [String] = []
        for rawPID in result.output.split(whereSeparator: \.isNewline) {
            let process = try Self.captureCommand(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-p", String(rawPID), "-o", "pid=,ppid=,lstart=,stat=,rss=,command="]
            )
            details.append(process.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw SmokeError.failed(
            "refusing to launch a smoke app while DieterMac is already running:\n\(details.joined(separator: "\n"))"
        )
    }

    private static func environmentValues(at url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            if line == "READY" {
                result["READY"] = ""
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        return result
    }

    @discardableResult
    private static func runCommand(executable: URL, arguments: [String], directory: URL? = nil) throws -> String {
        let result = try captureCommand(executable: executable, arguments: arguments, directory: directory)
        guard result.status == 0 else {
            throw SmokeError.failed("command failed (\(result.status)): \(([executable.path] + arguments).joined(separator: " "))\n\(result.output)")
        }
        return result.output
    }

    private static func captureCommand(
        executable: URL,
        arguments: [String],
        directory: URL? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    try SmokeRun(options: options).run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
