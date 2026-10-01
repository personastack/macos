import Foundation

public enum LocalRunError: String, Error, Sendable {
    case unsupported = "Local runs require Apple silicon and macOS 26."
    case runtimeMissing = "Install Apple's container runtime version 1.4.1 or newer within version 1 to run a persona locally."
    case runtimeUnavailable = "Start Apple's container runtime, then try again."
    case setupCancelled = "Local run setup was cancelled."
    case setupInProgress = "Local run setup is already open. Finish that setup, then try again."
    case setupFailed = "The container runtime installer could not be downloaded or verified. Check your connection and try Run Local again."
    case networkingUnavailable = "Mac localhost access is unavailable. Follow Apple's host integration setup, then try again. It must be restored after restarting your Mac."
    case invalidBundle = "The local startup bundle could not be verified."
    case staleSession = "This local session is no longer available."
    case connectionFailed = "The local agent connection closed."
    case invalidFrame = "The local agent sent an unsupported message."
    case startupFailed = "The local container could not start."
    case revocationUnconfirmed = "Local agent stopped. Credential revocation unconfirmed. Try closing this window again."
    case cleanupFailed = "The local container could not be stopped. Try closing this window again."
}

public struct LocalRunTool: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var title: String?
    public var input: String?
    public var output: String?
    public var status: String
    public var exit_code: Int?
    public var path: String?
    public var diff: String?
    public var error: String?
}

public struct LocalRunOption: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
}

public struct LocalRunQuestion: Codable, Equatable, Sendable {
    public var id: String
    public var prompt: String
    public var options: [LocalRunOption]?
    public var multiple: Bool?
    public var allow_text: Bool?
    public var secret: Bool?
}

public struct LocalRunControl: Codable, Equatable, Sendable {
    public var kind: String
    public var prompt: String?
    public var options: [LocalRunOption]?
    public var allow_text: Bool?
    public var questions: [LocalRunQuestion]?
}

public struct LocalRunAnswer: Codable, Equatable, Sendable {
    public var question_id: String
    public var option_ids: [String]?
    public var text: String?
    public init(question_id: String, option_ids: [String]? = nil, text: String? = nil) {
        self.question_id = question_id; self.option_ids = option_ids; self.text = text
    }
}

public struct LocalRunReply: Codable, Equatable, Sendable {
    public var request_id: String
    public var option_id: String?
    public var text: String?
    public var answers: [LocalRunAnswer]?
    public var stdout: String?
    public var stderr: String?
    public var exit_code: Int?
    public init(request_id: String, option_id: String? = nil, text: String? = nil, answers: [LocalRunAnswer]? = nil,
                stdout: String? = nil, stderr: String? = nil, exit_code: Int? = nil) {
        self.request_id = request_id; self.option_id = option_id; self.text = text; self.answers = answers
        self.stdout = stdout; self.stderr = stderr; self.exit_code = exit_code
    }
}

public struct LocalRunHostRequest: Codable, Equatable, Sendable {
    public var operation: String
    public var command: [String]?
    public var working_directory: String?
    public var stdin: String?
}

/// One bounded JSON object per line. Provider text events are cumulative snapshots.
public struct LocalRunFrame: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var type: String
    public var session_id: String
    public var request_id: String?
    public var turn_id: String?
    public var event_id: String?
    public var secret: String?
    public var text: String?
    public var status: String?
    public var capabilities: [String]?
    public var tool: LocalRunTool?
    public var control: LocalRunControl?
    public var reply: LocalRunReply?
    public var host: LocalRunHostRequest?

    public init(type: String, sessionID: String, requestID: String? = nil, turnID: String? = nil,
                secret: String? = nil, text: String? = nil, reply: LocalRunReply? = nil) {
        self.type = type; self.session_id = sessionID; self.request_id = requestID; self.turn_id = turnID
        self.secret = secret; self.text = text; self.reply = reply
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count < LocalRunFrameDecoder.maximumFrameBytes else { throw LocalRunError.invalidFrame }
        return data + Data([10])
    }
}

public struct LocalRunFrameDecoder: Sendable {
    public static let maximumFrameBytes = 1024 * 1024
    private var pending = Data()
    private let sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }

    public mutating func append(_ data: Data) throws -> [LocalRunFrame] {
        pending.append(data)
        var frames: [LocalRunFrame] = []
        while let boundary = pending.firstIndex(of: 10) {
            let size = pending.distance(from: pending.startIndex, to: boundary)
            guard size > 0, size <= Self.maximumFrameBytes else { throw LocalRunError.invalidFrame }
            let frame = try JSONDecoder().decode(LocalRunFrame.self, from: pending.prefix(size))
            guard frame.version == 1, frame.session_id == sessionID else { throw LocalRunError.invalidFrame }
            frames.append(frame)
            pending.removeSubrange(...boundary)
        }
        guard pending.count <= Self.maximumFrameBytes else { throw LocalRunError.invalidFrame }
        return frames
    }
}
