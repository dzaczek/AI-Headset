import Foundation
import os

/// Dedicated os_log subsystem, so the app's own diagnostics can
/// actually be found:
///
///   log show --last 10m --predicate 'subsystem == "cat.sysop.aiheadset"'
///   log stream --predicate 'subsystem == "cat.sysop.aiheadset"'
///
/// `NSLog` was used first and turned out to be a dead end -- its output
/// never surfaced under any `log show` predicate tried (process name,
/// message substring, --info --debug), which quietly invalidated
/// several "no errors in the log" conclusions during remote debugging.
/// A dedicated subsystem is queryable and unambiguous.
enum Log {
    private static let logger = Logger(subsystem: "cat.sysop.aiheadset", category: "app")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
