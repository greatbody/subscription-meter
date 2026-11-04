import Foundation
import Darwin

// Captures only stdout in memory; secrets and command output are never logged.
enum CommandRunner {
    static func executable(_ name: String) throws -> URL {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        throw AdapterError.message("未找到 \(name)，请安装并登录后重试")
    }

    static func run(_ name: String, arguments: [String], input: String? = nil, afterInitialize: String? = nil, responseID: Int? = nil, timeout: TimeInterval = 20) throws -> Data {
        let process = Process()
        process.executableURL = try executable(name)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        let output = Pipe(), inputPipe = Pipe()
        process.standardOutput = output
        if input != nil { process.standardInput = inputPipe }
        try process.run()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if let input { inputPipe.fileHandleForWriting.write(Data(input.utf8)) }
        var buffer = Data(), sentFollowup = false, timedOut = false, gotResponse = false
        let deadline = Date().addingTimeInterval(timeout)
        func hasResponse(_ id: Int) -> Bool {
            guard let text = String(data: buffer, encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { line in
                guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return obj["id"] as? Int == id
            }
        }
        while true {
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                else { break }
            }
            if let afterInitialize, !sentFollowup, hasResponse(0) {
                inputPipe.fileHandleForWriting.write(Data(afterInitialize.utf8))
                sentFollowup = true
            }
            if let responseID, hasResponse(responseID) { gotResponse = true; break }
            // All available pipe bytes were drained before observing exit; drain once more next iteration.
            if !process.isRunning {
                while true {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) } else { break }
                }
                break
            }
            if Date() >= deadline || buffer.count > 4_000_000 { timedOut = true; break }
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < killDeadline { usleep(20_000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        if input != nil { try? inputPipe.fileHandleForWriting.close() }
        if timedOut { throw AdapterError.message("连接超时，请稍后重试") }
        if responseID == nil && process.terminationStatus != 0 {
            throw AdapterError.message("\(name) 请求失败，请检查登录状态和网络")
        }
        if responseID != nil && !gotResponse { throw AdapterError.message("\(name) 未返回用量，请检查登录状态") }
        return buffer
    }
}
