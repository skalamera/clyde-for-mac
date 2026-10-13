import Foundation
import os

/// Central logging. Uses os_log/Logger under the hood so output is visible in Console.app
/// and via `log stream --predicate 'subsystem == "com.clyde.copilot"'`.
enum Log {
    static let app = Logger(subsystem: "com.clyde.copilot", category: "app")
    static let audio = Logger(subsystem: "com.clyde.copilot", category: "audio")
    static let transcribe = Logger(subsystem: "com.clyde.copilot", category: "transcribe")
    static let llm = Logger(subsystem: "com.clyde.copilot", category: "llm")
    static let mcp = Logger(subsystem: "com.clyde.copilot", category: "mcp")
    static let overlay = Logger(subsystem: "com.clyde.copilot", category: "overlay")
}
