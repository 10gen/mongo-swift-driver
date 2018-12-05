@testable import MongoSwift
import Nimble
import XCTest

final class MongoDatabaseTests: MongoSwiftTestCase {
    static var allTests: [(String, (MongoDatabaseTests) -> () throws -> Void)] {
        return [
            ("testDatabase", testDatabase)
        ]
    }

    override class func testDatabase() -> String {
        return "testDB"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testDatabase() throws {
        let client = try MongoClient(connectionString: MongoSwiftTestCase.connStr)
        let db = try client.db(type(of: self).testDatabase())

        let command: Document = ["create": "coll1"]
        expect(try db.runCommand(command)).to(equal(["ok": 1.0]))
        expect(try db.collection("coll1")).toNot(throwError())

        // create collection using createCollection
        expect(try db.createCollection("coll2")).toNot(throwError())
        expect(try (Array(db.listCollections()) as [Document]).count).to(equal(2))

        let opts = ListCollectionsOptions(filter: ["type": "view"] as Document)
        expect(try db.listCollections(options: opts)).to(beEmpty())

        expect(try db.drop()).toNot(throwError())
        let dbs = try client.listDatabases(options: ListDatabasesOptions(nameOnly: true))
        let names = (Array(dbs) as [Document]).map { $0["name"] as? String ?? "" }
        expect(names).toNot(contain([type(of: self).testDatabase()]))

        expect(db.name).to(equal(type(of: self).testDatabase()))
    }
}
