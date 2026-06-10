import Foundation

struct ShellResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { exitCode == 0 }
}

/// Minimal synchronous process runner. Used off the main thread.
enum Shell {
    @discardableResult
    static func run(_ launchPath: String,
                    _ args: [String],
                    stdin: String? = nil,
                    env: [String: String]? = nil) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let env { proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var inPipe: Pipe?
        if stdin != nil {
            inPipe = Pipe()
            proc.standardInput = inPipe
        }

        do {
            try proc.run()
        } catch {
            return ShellResult(exitCode: -1, stdout: "", stderr: "Start fehlgeschlagen: \(error.localizedDescription)")
        }

        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return ShellResult(
            exitCode: proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
