import Foundation

// What one run of a program produced.
struct ProgramResult {
    // The exit code (the signal number when `killedBySignal`).
    let status: Int32
    let killedBySignal: Bool
    let stdout: String
    let stderr: String
    // True when the program had to be killed because it ran past the time limit.
    let timedOut: Bool
}

// Runs a program to the end with a controlled environment and standard input, and collects its output. Kills it after `timeout` seconds so a hung program cannot hang the suite.
// Standard input, output and error are files in a private temp folder rather than pipes: tests run in parallel and start long-lived daemons, and a daemon that inherited another test's pipe end would keep that pipe open and stop its reader from ever seeing end-of-file.
func runProgram(_ path: String, _ arguments: [String], environment: [String: String] = [:], stdin: String? = nil, timeout: Double = 15) throws -> ProgramResult {
    Registry.installOnce()
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    let scratch = "/tmp/sbr-" + String((0..<8).map { _ in alphabet.randomElement()! })
    try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    let inPath = scratch + "/in"
    let outPath = scratch + "/out"
    let errPath = scratch + "/err"
    try Data((stdin ?? "").utf8).write(to: URL(fileURLWithPath: inPath))
    FileManager.default.createFile(atPath: outPath, contents: nil)
    FileManager.default.createFile(atPath: errPath, contents: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { _, new in new }
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: inPath))
    let output = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
    let errors = try FileHandle(forWritingTo: URL(fileURLWithPath: errPath))
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    Registry.add(pid: process.processIdentifier)
    try? input.close()
    try? output.close()
    try? errors.close()

    var timedOut = false
    if waitUntil(timeout: timeout, interval: 0.01, { !process.isRunning }) == nil {
        timedOut = true
        kill(process.processIdentifier, SIGKILL)
        _ = waitUntil(timeout: 3, interval: 0.01) { !process.isRunning }
    }
    Registry.remove(pid: process.processIdentifier)
    return ProgramResult(status: process.terminationStatus, killedBySignal: process.terminationReason == .uncaughtSignal, stdout: readText(outPath) ?? "", stderr: readText(errPath) ?? "", timedOut: timedOut)
}

// Runs the real `siteblock` command-line tool against the given socket (through the SITEBLOCK_SOCKET environment variable). Passwords are supplied as lines on standard input; with no `stdin` the program sees an empty input.
func runCLI(_ arguments: [String], socket: String, stdin: String? = nil) throws -> ProgramResult {
    try runProgram(try Binaries.path("siteblock"), arguments, environment: ["SITEBLOCK_SOCKET": socket], stdin: stdin)
}

// Runs the real `siteblockd` program with the given flags (for flag checks that must exit by themselves).
func runDaemonProgram(_ arguments: [String], timeout: Double = 8) throws -> ProgramResult {
    try runProgram(try Binaries.path("siteblockd"), arguments, timeout: timeout)
}
