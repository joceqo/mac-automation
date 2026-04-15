import AppKit

/// Runs AppleScript source code and returns the result or error.
/// All execution happens on a background queue to avoid blocking the main thread.
public enum AppleScriptRunner {

    /// Result of an AppleScript execution.
    public enum Result: Sendable {
        case success(String)
        case failure(String)
    }

    /// Executes an AppleScript source string synchronously on a background queue
    /// and returns the result. Safe to call from any actor.
    public static func run(_ source: String) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failure("Failed to create NSAppleScript"))
                    return
                }

                let descriptor = script.executeAndReturnError(&errorInfo)

                if let errorInfo {
                    let message = errorInfo[NSAppleScript.errorMessage] as? String
                        ?? "Unknown AppleScript error"
                    continuation.resume(returning: .failure(message))
                } else {
                    let output = descriptor.stringValue ?? ""
                    continuation.resume(returning: .success(output))
                }
            }
        }
    }

    /// Escapes a string for safe embedding inside AppleScript double-quoted string literals.
    public static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Escapes a string for safe embedding inside SQL single-quoted string literals.
    public static func escapeForSQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
