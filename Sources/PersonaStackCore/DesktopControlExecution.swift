import Foundation

/// Carries the admitted command's deadline across actor queues. Local setup and
/// cleanup do not install a deadline. They keep their existing lifecycle bounds.
public enum DesktopControlExecution {
    @TaskLocal public static var deadline: Date?

    public struct Expired: Error, Equatable { public init() {} }

    public static func check() throws {
        try Task.checkCancellation()
        if let deadline, deadline <= Date() { throw Expired() }
    }

    public static func boundedDeadline(timeout: TimeInterval) throws -> Date {
        try check()
        let local = Date().addingTimeInterval(timeout)
        return deadline.map { min($0, local) } ?? local
    }
}
