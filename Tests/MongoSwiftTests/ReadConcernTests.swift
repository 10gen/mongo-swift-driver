import CLibMongoC
@testable import MongoSwift
import Nimble
import TestsCommon

/// Indicates that a type has a read concern property, as well as a way to get a read concern from an instance of the
/// corresponding mongoc type.
private protocol ReadConcernable {
    var readConcern: ReadConcern? { get }
    func getMongocReadConcern() throws -> ReadConcern?
}

extension MongoClient: ReadConcernable {}
extension MongoDatabase: ReadConcernable {}
extension MongoCollection: ReadConcernable {}

/// Checks that a type T, as well as pointers to corresponding libmongoc instances, has the expected read concern.
private func checkReadConcern<T: ReadConcernable>(
    _ instance: T,
    _ expected: ReadConcern,
    _ description: String
) throws {
    if expected.isDefault {
        expect(instance.readConcern).to(beNil(), description: description)
    } else {
        expect(instance.readConcern).to(equal(expected), description: description)
    }

    expect(try instance.getMongocReadConcern()).to(equal(expected))
}

final class ReadConcernTests: MongoSwiftTestCase {
    func testReadConcernType() throws {
        // check level var works as expected
        let rc = ReadConcern(.majority)
        expect(rc.level).to(equal(.majority))

        // test empty init
        let rc2 = ReadConcern()
        expect(rc2.level).to(beNil())
        expect(rc2.isDefault).to(beTrue())

        // test init from doc
        let rc3 = try BSONDecoder().decode(ReadConcern.self, from: ["level": "majority"])
        expect(rc3.level).to(equal(.majority))

        // test string init
        let rc4 = ReadConcern("majority")
        expect(rc4.level).to(equal(.majority))

        // test init with unknown level
        let rc5 = ReadConcern("blah")
        expect(rc5.level).to(equal(.other(level: "blah")))
    }

    func testClientReadConcern() throws {
        let empty = ReadConcern()
        let majority = ReadConcern(.majority)
        let majorityString = ReadConcern("majority")
        let local = ReadConcern(.local)

        // test behavior of a client with initialized with no RC
        try self.withTestClient { client in
            let clientDesc = "client created with no RC provided"
            // expect the client to have empty/server default read concern
            try checkReadConcern(client, empty, clientDesc)

            // expect that a DB created from this client inherits its unset RC
            let db1 = client.db(Self.testDatabase)
            try checkReadConcern(db1, empty, "db created with no RC provided from \(clientDesc)")

            // expect that a DB created from this client can override the client's unset RC
            let db2 = client.db(Self.testDatabase, options: DatabaseOptions(readConcern: majority))
            try checkReadConcern(db2, majority, "db created with majority RC from \(clientDesc)")
        }

        // test behavior of a client initialized with local RC
        try self.withTestClient(options: ClientOptions(readConcern: local)) { client in
            let clientDesc = "client created with local RC"
            // although local is default, if it is explicitly provided it should be set
            try checkReadConcern(client, local, clientDesc)

            // expect that a DB created from this client inherits its local RC
            let db1 = client.db(Self.testDatabase)
            try checkReadConcern(db1, local, "db created with no RC provided from \(clientDesc)")

            // expect that a DB created from this client can override the client's local RC
            let db2 = client.db(Self.testDatabase, options: DatabaseOptions(readConcern: majority))
            try checkReadConcern(db2, majority, "db created with majority RC from \(clientDesc)")

            // test with string init
            let db3 = client.db(Self.testDatabase, options: DatabaseOptions(readConcern: majorityString))
            try checkReadConcern(db3, majority, "db created with majority string RC from \(clientDesc)")

            // test with unknown level
            let unknown = ReadConcern("blah")
            let db4 = client.db(Self.testDatabase, options: DatabaseOptions(readConcern: unknown))
            try checkReadConcern(db4, unknown, "db created with unknown RC from \(clientDesc)")
        }

        // test behavior of a client initialized with majority RC
        try self.withTestClient(options: ClientOptions(readConcern: majority)) { client in
            try checkReadConcern(client, majority, "client created with majority RC")
        }

        // test with string init
        try self.withTestClient(options: ClientOptions(readConcern: majorityString)) { client in
            let clientDesc = "client created with majority RC string"
            try checkReadConcern(client, majority, clientDesc)

            // expect that a DB created from this client can override the client's majority RC with an unset one
            let db = client.db(Self.testDatabase, options: DatabaseOptions(readConcern: empty))
            try checkReadConcern(db, empty, "db created with empty RC from \(clientDesc)")
        }
    }

    func testDatabaseReadConcern() throws {
        let empty = ReadConcern()
        let local = ReadConcern(.local)
        let localString = ReadConcern("local")
        let unknown = ReadConcern("blah")
        let majority = ReadConcern(.majority)

        try self.withTestClient { client in
            let db1 = client.db(Self.testDatabase)
            defer { try? db1.drop().wait() }

            let dbDesc = "db created with no RC provided"

            let coll1Name = self.getCollectionName(suffix: "1")
            // expect that a collection created from a DB with unset RC also has unset RC
            var coll1 = try db1.createCollection(coll1Name).wait()
            try checkReadConcern(coll1, empty, "collection created with no RC provided from \(dbDesc)")

            // expect that a collection retrieved from a DB with unset RC also has unset RC
            coll1 = db1.collection(coll1Name)
            try checkReadConcern(coll1, empty, "collection retrieved with no RC provided from \(dbDesc)")

            // expect that a collection retrieved from a DB with unset RC can override the DB's RC
            let coll2 =
                db1.collection(self.getCollectionName(suffix: "2"), options: CollectionOptions(readConcern: local))
            try checkReadConcern(coll2, local, "collection retrieved with local RC from \(dbDesc)")

            // test with string init
            var coll3 = db1.collection(
                self.getCollectionName(suffix: "3"),
                options: CollectionOptions(readConcern: localString)
            )
            try checkReadConcern(coll3, local, "collection created with local RC string from \(dbDesc)")

            // test with unknown level
            coll3 =
                db1.collection(self.getCollectionName(suffix: "3"), options: CollectionOptions(readConcern: unknown))
            try checkReadConcern(coll3, unknown, "collection retrieved with unknown RC level from \(dbDesc)")

            try db1.drop().wait()

            let db2 = client.db(
                Self.testDatabase,
                options: DatabaseOptions(readConcern: local)
            )
            defer { try? db2.drop().wait() }

            let coll4Name = self.getCollectionName(suffix: "4")
            // expect that a collection created from a DB with local RC also has local RC
            var coll4 = try db2.createCollection(coll4Name).wait()
            try checkReadConcern(coll4, local, "collection created with no RC provided from \(dbDesc)")

            // expect that a collection retrieved from a DB with local RC also has local RC
            coll4 = db2.collection(coll4Name)
            try checkReadConcern(coll4, local, "collection retrieved with no RC provided from \(dbDesc)")

            // expect that a collection retrieved from a DB with local RC can override the DB's RC
            let coll5 = db2.collection(
                self.getCollectionName(suffix: "5"),
                options: CollectionOptions(readConcern: majority)
            )
            try checkReadConcern(coll5, majority, "collection retrieved with majority RC from \(dbDesc)")
        }
    }
}
