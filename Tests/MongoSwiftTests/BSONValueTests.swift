import Foundation
@testable import MongoSwift
import Nimble
import XCTest

final class BSONValueTests: XCTestCase {
    static var allTests: [(String, (BSONValueTests) -> () throws -> Void)] {
        return [
            ("testInvalidDecimal128", testInvalidDecimal128),
            ("testUUIDBytes", testUUIDBytes),
            ("testBSONEquals", testBSONEquals),
            ("testBSONInterfaces", testBSONInterfaces)
        ]
    }

    func testInvalidDecimal128() throws {
        expect(Decimal128(ifValid: "hi")).to(beNil())
        expect(Decimal128(ifValid: "123.4.5")).to(beNil())
        expect(Decimal128(ifValid: "10")).toNot(beNil())
    }

    func testUUIDBytes() throws {
        let twoBytes = Data(base64Encoded: "//8=")!
        let sixteenBytes = Data(base64Encoded: "c//SZESzTGmQ6OfR38A11A==")!

        // UUIDs must have 16 bytes
        expect(try Binary(data: twoBytes, subtype: .uuidDeprecated)).to(throwError())
        expect(try Binary(data: twoBytes, subtype: .uuid)).to(throwError())
        expect(try Binary(data: sixteenBytes, subtype: .uuidDeprecated)).toNot(throwError())
        expect(try Binary(data: sixteenBytes, subtype: .uuid)).toNot(throwError())
    }

    fileprivate func checkTrueAndFalse(val: BSONValue, alternate: BSONValue) {
        expect(val).to(bsonEqual(val))
        expect(val).toNot(bsonEqual(alternate))
    }

    func testBSONEquals() throws {
        // Int
        checkTrueAndFalse(val: 1, alternate: 2)
        // Int32
        checkTrueAndFalse(val: Int32(32), alternate: Int32(33))
        // Int64
        checkTrueAndFalse(val: Int64(64), alternate: Int64(65))
        // Double
        checkTrueAndFalse(val: 1.618, alternate: 2.718)
        // Decimal128
        checkTrueAndFalse(val: Decimal128("1.618"), alternate: Decimal128("2.718"))
        // Bool
        checkTrueAndFalse(val: true, alternate: false)
        // String
        checkTrueAndFalse(val: "some", alternate: "not some")
        // RegularExpression
        checkTrueAndFalse(
            val: RegularExpression(pattern: ".*", options: ""),
            alternate: RegularExpression(pattern: ".+", options: "")
        )
        // Timestamp
        checkTrueAndFalse(val: Timestamp(timestamp: 1, inc: 2), alternate: Timestamp(timestamp: 5, inc: 10))
        // Date
        checkTrueAndFalse(
            val: Date(timeIntervalSinceReferenceDate: 5000),
            alternate: Date(timeIntervalSinceReferenceDate: 5001)
        )
        // MinKey & MaxKey
        expect(MinKey()).to(bsonEqual(MinKey()))
        expect(MaxKey()).to(bsonEqual(MaxKey()))
        // ObjectId
        checkTrueAndFalse(val: ObjectId(), alternate: ObjectId())
        // CodeWithScope
        checkTrueAndFalse(
            val: CodeWithScope(code: "console.log('foo');"),
            alternate: CodeWithScope(code: "console.log(x);", scope: ["x": 2])
        )
        // Binary
        checkTrueAndFalse(
            val: try Binary(data: Data(base64Encoded: "c//SZESzTGmQ6OfR38A11A==")!, subtype: .uuid),
            alternate: try Binary(data: Data(base64Encoded: "c//88KLnfdfefOfR33ddFA==")!, subtype: .uuid)
        )
        // Document
        checkTrueAndFalse(
            val: [
                "foo": 1.414,
                "bar": "swift",
                "nested": [ "a": 1, "b": "2" ] as Document
                ] as Document,
            alternate: [
                "foo": 1.414,
                "bar": "swift",
                "nested": [ "a": 1, "b": "different" ] as Document
                ] as Document
        )
        // [BSONValue?]
        checkTrueAndFalse(val: [4, 5, 1, nil, 3], alternate: [4, 5, 1, 2, 3])
        // Invalid Array type
        expect(bsonEquals([BSONEncoder()], [BSONEncoder(), BSONEncoder()])).to(beFalse())
        // Different types
        expect(4).toNot(bsonEqual("swift"))
    }

    internal struct DocumentTest {
        public var header: String
        public var doc: Document

        public init(_ header: String, _ meaning: BSONValue?) {
            self.header = header
            self.doc = [
                BSONValueTests.hello: 42,
                BSONValueTests.whatIsUp: "nothing much man",
                BSONValueTests.meaningOfLife: meaning,
                BSONValueTests.pizza: true
            ]
        }
    }

    static var doubleOptionalHeader = "SWIFT (BSONValue?) ================================="

    static var (hello, whatIsUp, meaningOfLife, pizza) = (
        "hello",
        "what is up",
        "what is the meaning of life",
        "why is pizza so good"
    )

    func testBSONInterfaces() throws {
        let doubleOptional: [String: BSONValue?] = [
            BSONValueTests.hello: 42,
            BSONValueTests.whatIsUp: "nothing much man",
            BSONValueTests.meaningOfLife: nil as BSONValue?,
            BSONValueTests.pizza: true
        ]

        let docTests = [
            DocumentTest(
                "BSONMissing ========================================",
                nil
            ),
            DocumentTest(
                "BSONNull ===========================================",
                 BSONNull()
            ),
            DocumentTest(
                "Both BSONNull and BSONMissing ======================",
                BSONNull()
            ),
            DocumentTest(
                "NSNull ======================",
                NSNull()
            )
        ]

        // use cases
        // 1. Get existing key's value from document and using it:
        usingExistingKeyValue(doubleOptional, docTests)

        // 2. Distinguishing between nil value for key, missing value for key, and existing value for key
        distinguishingValueKinds(doubleOptional, docTests)

        // 3. Getting the value for a key, where the value is nil
        gettingNilKeyValue(doubleOptional, docTests)
    }

    func usingExistingKeyValue(_ doubleOptional: [String: BSONValue?], _ testDocs: [DocumentTest]) {
        let (bsonMissing, bsonNull, bsonBoth, nsNull) = getDocumentTests(testDocs)
        let msg = "Got back existing key value from: "
        let sumDocMsg = "sumDoc: "

        print("\n=== EXISTING KEY VALUE ===\n")

        print(BSONValueTests.doubleOptionalHeader)
        let existingSwift = doubleOptional["hello"] as? Int
        debugPrint(msg + "\(String(describing: existingSwift))")
        if let existingSwift = existingSwift {
            let sumDict = existingSwift + 10
            debugPrint(sumDocMsg + "\(sumDict)")
        }

        print(bsonMissing.header)
        let existingBSONMissing = bsonMissing.doc["hello"] as? Int
        debugPrint(msg + "\(String(describing: existingBSONMissing))")
        if let existingBSONMissing = existingBSONMissing {
            let sumDoc = existingBSONMissing + 10
            debugPrint(sumDocMsg + "\(sumDoc)")
        }

        print(bsonNull.header)
        let existingBSONNull = bsonNull.doc["hello"] as? Int
        debugPrint(msg + "\(String(describing: existingBSONNull))")
        if let existingBSONNull = existingBSONNull {
            let sumDict = existingBSONNull + 10
            debugPrint(sumDocMsg + "\(sumDict)")
        }

        print(bsonBoth.header)
        let existingBSONBoth = bsonBoth.doc["hello"] as? Int
        debugPrint(msg + "\(String(describing: existingBSONBoth))")
        if let existingBSONBoth = existingBSONBoth {
            let sumDict = existingBSONBoth + 10
            debugPrint(sumDocMsg + "\(sumDict)")
        }

        print(nsNull.header)
        let existingNSNull = nsNull.doc["hello"] as? Int
        debugPrint(msg + "\(String(describing: existingNSNull))")
        if let existingNSNull = existingNSNull {
            let sumDict = existingNSNull + 10
            debugPrint(sumDocMsg + "\(sumDict)")
        }
    }

    func distinguishingValueKinds(_ doubleOptional: [String: BSONValue?], _ testDocs: [DocumentTest]) {
        let (bsonMissing, bsonNull, bsonBoth, nsNull) = getDocumentTests(testDocs)
        let keys = [BSONValueTests.hello, "i am missing", BSONValueTests.meaningOfLife]
        let (dne, exists, null) = ("Key DNE!", "Key exists!", "Key is null!")

        print("\n=== DISTINGUISHING VALUE KINDS ===\n")

        // NOTE: Since we are merging various approaches into this single PoC branch, some of these will not function
        // correctly. E.g., if we've disabled using BSONMissing, the BSONMissing test case below will not work. However,
        // this demo only serves to show what the code _would_ look like, so I've kept them all here for comparison.
        print(BSONValueTests.doubleOptionalHeader)
        for key in keys {
            let keyVal = doubleOptional[key]
            if let keyVal = keyVal { // Having double optional makes us lose brevity/clarity here.
                if keyVal == nil {
                    debugPrint(null)
                } else {
                    if let keyValInner = keyVal {
                        debugPrint(exists + ": \(keyValInner)")
                    }
                }
            } else {
                debugPrint(dne)
            }
        }

        print(bsonMissing.header)
        for key in keys {
            let keyVal = bsonMissing.doc[key]
            if let keyVal = keyVal, keyVal == BSONMissing() {
                debugPrint(dne)
            } else if keyVal != nil, let keyVal = keyVal {
                debugPrint(exists + ": \(keyVal)")
            } else {
                debugPrint(null)
            }
        }

        print(bsonNull.header)
        for key in keys {
            let keyVal = bsonNull.doc[key]
            if let keyVal = keyVal, keyVal == BSONNull() {
                debugPrint(null)
            } else if keyVal != nil, let keyVal = keyVal {
                debugPrint(exists + ": \(keyVal)")
            } else {
                debugPrint(dne)
            }
        }

        // NOTE: that one can also combine NSNull with BSONMissing, the semantics are identical, with
        // BSONNull() -> NSNull().
        // NOTE: This has uses of `if let`, but in fact, we can remove `BSONValue?` (optional) entirely with this
        // approach.
        print(bsonBoth.header)
        for key in keys {
            let keyVal = bsonBoth.doc[key]
            if let keyVal = keyVal, keyVal == BSONNull() {
                debugPrint(null)
            } else if let keyVal = keyVal, keyVal == BSONMissing() {
                debugPrint(dne)
            } else if let keyVal = keyVal {
                debugPrint(exists + ": \(keyVal)")
            }
        }

        print(nsNull.header)
        for key in keys {
            let keyVal = nsNull.doc[key]
            if let keyVal = keyVal, keyVal == NSNull() {
                debugPrint(null)
            } else if keyVal != nil {
                debugPrint(exists)
            } else {
                debugPrint(dne)
            }
        }
    }

    func gettingNilKeyValue(_ doubleOptional: [String: BSONValue?], _ testDocs: [DocumentTest]) {
        let (bsonMissing, bsonNull, bsonBoth, nsNull) = getDocumentTests(testDocs)
        let nullKey = BSONValueTests.meaningOfLife
        let msg = "Got back null val: "

        print("\n=== GETTING A NIL VALUE ===\n")

        print(BSONValueTests.doubleOptionalHeader)
        let swiftVal = doubleOptional[nullKey]
        if let swiftVal = swiftVal {
            if swiftVal == nil {
                debugPrint(msg + "\(String(describing: swiftVal))")
            }
        }

        print(bsonMissing.header)
        let bsonMissingVal = bsonMissing.doc[nullKey]
        if bsonMissingVal == nil { // No unwrapping via if let needed, null is native `nil`.
            debugPrint(msg + "\(String(describing: bsonMissingVal))")
        }

        print(bsonNull.header)
        let bsonNullVal = bsonNull.doc[nullKey]
        if let bsonNullVal = bsonNullVal { // We need to unwrap, since 'null' is actually an Object in these cases.
            if bsonNullVal == BSONNull() {
                debugPrint(msg + "\(String(describing: bsonNullVal))")
            }
        }

        print(bsonBoth.header)
        let bsonBothVal = bsonBoth.doc[nullKey]
        if let bsonBothVal = bsonBothVal {
            if bsonBothVal == BSONNull() {
                debugPrint(msg + "\(String(describing: bsonBothVal))")
            }
        }

        print(nsNull.header)
        let nsNullVal = nsNull.doc[nullKey]
        if let nsNullVal = nsNullVal {
            if nsNullVal == NSNull() {
                debugPrint(msg + "\(String(describing: nsNullVal))")
            }
        }
    }

    func getDocumentTests(_ tests: [DocumentTest]) -> (DocumentTest, DocumentTest, DocumentTest, DocumentTest) {
        return (tests[0], tests[1], tests[2], tests[3])
    }
}
