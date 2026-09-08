import OSLog

enum Log {
    static let general = Logger(subsystem: "Trail-Mix.Doodle", category: "General")
    static let location = Logger(subsystem: "Trail-Mix.Doodle", category: "Location")
    static let tracking = Logger(subsystem: "Trail-Mix.Doodle", category: "Tracking")
} 