import XCTest

#if !os(macOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(BSONValueTests.allTests),
        testCase(CodecTests.allTests),
        testCase(CommandMonitoringTests.allTests),
        testCase(CrudTests.allTests),
        testCase(MongoClientTests.allTests),
        testCase(MongoCollectionTests.allTests),
        testCase(MongoCollection_BulkWriteTests.allTests),
        testCase(MongoDatabaseTests.allTests),
        testCase(DocumentTests.allTests),
        testCase(Document_SequenceTests.allTests),
        testCase(ReadPreferenceTests.allTests),
        testCase(ReadWriteConcernTests.allTests),
        testCase(SDAMTests.allTests)
    ]
}
#endif
