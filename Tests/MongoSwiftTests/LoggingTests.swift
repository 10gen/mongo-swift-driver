import Foundation
import Logging
@testable import MongoSwift
import Nimble
import TestsCommon

// For reasons I am still trying to wrap my head around, log handlers are supposed to be value types.
// I think that perhaps they get created as needed when messages are being logged, or something like that.
// To facilitate gathering messages in one place no matter which log handler created them, we use a single
// global thread-safe queue for gathering messages.

private let globalContainer = LogMessageContainer()

private class LogMessageContainer {
    private var messages: [LogMessage] = []
    private let queue = DispatchQueue(label: "MessageContainer")

    fileprivate init() {}

    fileprivate func append(_ message: LogMessage) {
        self.queue.sync {
            self.messages.append(message)
        }
    }

    fileprivate func getMessages() -> [LogMessage] {
        self.queue.sync {
            let messages = self.messages
            self.messages = []
            return messages
        }
    }
}

/// Struct representing info we care about from a log message.
private struct LogMessage {
    fileprivate let level: Logger.Level
    fileprivate let message: Logger.Message
    fileprivate let metadata: Logger.Metadata?
}

/// Test log handler that conforms to the LogHandler protocol, so we can register it with swift-log.
private struct TestLogHandler: LogHandler {
    fileprivate var logLevel: Logger.Level

    fileprivate init() {
        self.logLevel = .debug
    }

    static func bootstrap(label _: String) -> LogHandler {
        self.init()
    }

    public var metadata: Logger.Metadata {
        get { [:] }
        set { _ = newValue }
    }

    public subscript(metadataKey _: String) -> Logger.Metadata.Value? {
        get { nil }
        set { _ = newValue }
    }

    // part of the Logger protocol, we can't work around it.
    // swiftlint:disable:next function_parameter_count
    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        let message = LogMessage(level: level, message: message, metadata: metadata)
        globalContainer.append(message)
    }
}

/// Temporarily enables and then disables command logging.
private func withCommandLogging<T>(_ body: () throws -> T) rethrows -> T {
    TEST_COMMAND_LOGGER = Logger(label: "MongoSwiftTests.command")
    defer { TEST_COMMAND_LOGGER = nil }
    return try body()
}

final class LoggingTests: MongoSwiftTestCase {
    func testCommandLogging() throws {
        // TODO: you can only call bootstrap once, need to do this in a singleton way
        LoggingSystem.bootstrap(TestLogHandler.bootstrap)
        try self.withTestNamespace { _, db, _ in
            try withCommandLogging {
                // successful command
                _ = try db.runCommand(["isMaster": 1]).wait()
            }
            let messages = globalContainer.getMessages()
            expect(messages).to(haveCount(2))

            expect(messages[0].level).to(equal(.info))
            expect(messages[1].level).to(equal(.info))

            expect(messages[0].message).to(equal("Command started"))
            expect(messages[1].message).to(equal("Command succeeded"))

            expect(messages[0].metadata).toNot(beNil())
            let metadata0 = messages[0].metadata!

            let expectedStartedKeys = [
                "command",
                "commandName",
                "databaseName",
                "explicitSession",
                "operationId",
                "requestId",
                "serverConnectionId",
                "serverHostname",
                "serverPort",
                "serverResolvedIPAddress"
            ]

            expect(metadata0.keys.sorted()).to(equal(expectedStartedKeys))

            expect(messages[1].metadata).toNot(beNil())
            let metadata1 = messages[1].metadata!

            let expectedSucceededKeys = [
                "commandName",
                "duration",
                "explicitSession",
                "operationId",
                "reply",
                "requestId",
                "serverConnectionId",
                "serverHostname",
                "serverPort",
                "serverResolvedIPAddress"
            ]

            expect(metadata1.keys.sorted()).to(equal(expectedSucceededKeys))

            expect(metadata0["commandName"]).to(equal("isMaster"))
            expect(metadata0["databaseName"]).to(equal("test"))
            expect(metadata0["explicitSession"]).to(equal("false"))

            expect(metadata0["command"]).toNot(beNil())
            let commandDoc = try BSONDocument(fromJSON: metadata0["command"]!.description)
            expect(commandDoc["isMaster"]?.int64Value).to(equal(1))

            expect(metadata1["commandName"]).to(equal("isMaster"))
            expect(metadata1["explicitSession"]).to(equal("false"))

            expect(metadata1["reply"]).toNot(beNil())
            let replyDoc = try BSONDocument(fromJSON: metadata1["reply"]!.description)
            expect(replyDoc["ok"]?.doubleValue).to(equal(1.0))

            // no particular values to expect here, but they should always match up.
            expect(metadata0["operationId"]).to(equal(metadata1["operationId"]))
            expect(metadata0["requestId"]).to(equal(metadata1["requestId"]))
            expect(metadata0["serverConnectionId"]).to(equal(metadata1["serverConnectionId"]))
            expect(metadata0["serverHostname"]).to(equal(metadata1["serverHostname"]))
            expect(metadata0["serverPort"]).to(equal(metadata1["serverPort"]))
            expect(metadata0["serverResolvedIPAddress"]).to(equal(metadata1["serverResolvedIPAddress"]))
        }
    }

    func testLoggingTruncation() throws {
        try self.withTestNamespace { _, db, _ in
            try withCommandLogging {
                // choose a very small length to ensure the command/reply are longer and get truncated
                LOGGING_MAX_DOC_LENGTH = 5
                defer { LOGGING_MAX_DOC_LENGTH = 1000 }
                _ = try db.runCommand(["isMaster": 1]).wait()
            }

            let messages = globalContainer.getMessages()
            expect(messages).to(haveCount(2))

            expect(messages[0].metadata).toNot(beNil())
            let metadata0 = messages[0].metadata!

            expect(metadata0["command"]?.description).to(haveCount(5))

            expect(messages[1].metadata).toNot(beNil())
            let metadata1 = messages[1].metadata!

            expect(metadata1["reply"]?.description).to(haveCount(5))
        }
    }
}
