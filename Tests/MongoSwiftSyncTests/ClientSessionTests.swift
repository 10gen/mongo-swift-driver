import Foundation
@testable import MongoSwift
@testable import MongoSwiftSync
import Nimble
import TestsCommon

/// Describes an operation run on a collection that takes in a session.
struct CollectionSessionOp {
    let name: String
    let body: (MongoSwiftSync.MongoCollection<Document>, MongoSwiftSync.ClientSession?) throws -> Void
}

/// Describes an operation run on a database that takes in a session.
struct DatabaseSessionOp {
    let name: String
    let body: (MongoSwiftSync.MongoDatabase, MongoSwiftSync.ClientSession?) throws -> Void
}

/// Describes an operation run on a client that takes in a session.
struct ClientSessionOp {
    let name: String
    let body: (MongoSwiftSync.MongoClient, MongoSwiftSync.ClientSession?) throws -> Void
}

extension MongoSwiftSync.ClientSession {
    var active: Bool {
        return self.asyncSession.active
    }

    var id: Document? {
        return self.asyncSession.id
    }
}

final class SyncClientSessionTests: MongoSwiftTestCase {
    override func tearDown() {
        do {
            let client = try MongoClient.makeTestClient()
            try client.db(type(of: self).testDatabase).drop()
        } catch let commandError as CommandError where commandError.code == 26 {
            // skip database not found errors
        } catch {
            fail("encountered error when tearing down: \(error)")
        }
        super.tearDown()
    }

    typealias SessionOp = (name: String, body: (MongoSwiftSync.ClientSession?) throws -> Void)

    // list of read only operations on MongoCollection that take in a session
    let collectionSessionReadOps = [
        // TODO: SWIFT-672: enable
        // CollectionSessionOp(name: "find") { _ = try $0.find([:], session: $1).next()?.get() },
        // CollectionSessionOp(name: "findOne") { _ = try $0.findOne([:], session: $1) },
        // CollectionSessionOp(name: "aggregate") { _ = try $0.aggregate([], session: $1).next()?.get() },
        CollectionSessionOp(name: "distinct") { _ = try $0.distinct(fieldName: "x", session: $1) },
        CollectionSessionOp(name: "countDocuments") { _ = try $0.countDocuments(session: $1) },
        CollectionSessionOp(name: "estimatedDocumentCount") { _ = try $0.estimatedDocumentCount(session: $1) }
    ]

    // list of write operations on MongoCollection that take in a session
    let collectionSessionWriteOps = [
        CollectionSessionOp(name: "bulkWrite") { _ = try $0.bulkWrite([.insertOne([:])], session: $1) },
        CollectionSessionOp(name: "insertOne") { _ = try $0.insertOne([:], session: $1) },
        CollectionSessionOp(name: "insertMany") { _ = try $0.insertMany([[:]], session: $1) },
        CollectionSessionOp(name: "replaceOne") { _ = try $0.replaceOne(filter: [:], replacement: [:], session: $1) },
        CollectionSessionOp(name: "updateOne") { _ = try $0.updateOne(filter: [:], update: [:], session: $1) },
        CollectionSessionOp(name: "updateMany") { _ = try $0.updateMany(filter: [:], update: [:], session: $1) },
        CollectionSessionOp(name: "deleteOne") { _ = try $0.deleteOne([:], session: $1) },
        CollectionSessionOp(name: "deleteMany") { _ = try $0.deleteMany([:], session: $1) },
        CollectionSessionOp(name: "createIndex") { _ = try $0.createIndex([:], session: $1) },
        CollectionSessionOp(name: "createIndex1") { _ = try $0.createIndex(IndexModel(keys: ["x": 1]), session: $1) },
        CollectionSessionOp(name: "createIndexes") {
            _ = try $0.createIndexes([IndexModel(keys: ["x": 1])], session: $1)
        },
        CollectionSessionOp(name: "dropIndex") { _ = try $0.dropIndex(["x": 1], session: $1) },
        CollectionSessionOp(name: "dropIndex1") { _ = try $0.dropIndex(IndexModel(keys: ["x": 3]), session: $1) },
        CollectionSessionOp(name: "dropIndex2") { _ = try $0.dropIndex("x_7", session: $1) },
        CollectionSessionOp(name: "dropIndexes") { _ = try $0.dropIndexes(session: $1) },
        // TODO: SWIFT-672: enable
        // CollectionSessionOp(name: "listIndexes") { _ = try $0.listIndexes(session: $1).next() },
        CollectionSessionOp(name: "findOneAndDelete") {
            _ = try $0.findOneAndDelete([:], session: $1)
        },
        CollectionSessionOp(name: "findOneAndReplace") {
            _ = try $0.findOneAndReplace(filter: [:], replacement: [:], session: $1)
        },
        CollectionSessionOp(name: "findOneAndUpdate") {
            _ = try $0.findOneAndUpdate(filter: [:], update: [:], session: $1)
        },
        CollectionSessionOp(name: "drop") { _ = try $0.drop(session: $1) }
    ]

    // list of operations on MongoDatabase that take in a session
    let databaseSessionOps = [
        // TODO: SWIFT-672: test listCollections + session here
        DatabaseSessionOp(name: "runCommand") { try $0.runCommand(["isMaster": 0], session: $1) },
        DatabaseSessionOp(name: "createCollection") { _ = try $0.createCollection("asdf", session: $1) },
        DatabaseSessionOp(name: "createCollection1") {
            _ = try $0.createCollection("asf", withType: Document.self, session: $1)
        },
        DatabaseSessionOp(name: "drop") { _ = try $0.drop(session: $1) }
    ]

    // list of operatoins on MongoClient that take in a session
    let clientSessionOps = [
        ClientSessionOp(name: "listDatabases") { _ = try $0.listDatabases(session: $1) },
        ClientSessionOp(name: "listMongoDatabases") { _ = try $0.listMongoDatabases(session: $1) },
        ClientSessionOp(name: "listDatabaseNames") { _ = try $0.listDatabaseNames(session: $1) }
    ]

    /// iterate over all the different session op types, passing in the provided client/db/collection as needed.
    func forEachSessionOp(
        client: MongoSwiftSync.MongoClient,
        database: MongoSwiftSync.MongoDatabase,
        collection: MongoSwiftSync.MongoCollection<Document>,
        _ body: (SessionOp) throws -> Void
    ) rethrows {
        try (self.collectionSessionReadOps + self.collectionSessionWriteOps).forEach { op in
            try body((name: op.name, body: { try op.body(collection, $0) }))
        }
        try self.databaseSessionOps.forEach { op in
            try body((name: op.name, body: { try op.body(database, $0) }))
        }
        try self.clientSessionOps.forEach { op in
            try body((name: op.name, body: { try op.body(client, $0) }))
        }
    }

    /// Sessions spec test 1: Test that sessions are properly returned to the pool when ended.
    func testSessionCleanup() throws {
        let client = try MongoClient.makeTestClient()

        var sessionA: MongoSwiftSync.ClientSession? = client.startSession()
        // use the session to trigger starting the libmongoc session
        _ = try client.listDatabases(session: sessionA)
        expect(sessionA!.active).to(beTrue())

        var sessionB: MongoSwiftSync.ClientSession? = client.startSession()
        _ = try client.listDatabases(session: sessionB)
        expect(sessionB!.active).to(beTrue())

        let idA = sessionA!.id
        let idB = sessionB!.id

        // test via deinit
        sessionA = nil
        sessionB = nil

        let sessionC = client.startSession()
        _ = try client.listDatabases(session: sessionC)
        expect(sessionC.active).to(beTrue())
        expect(sessionC.id).to(equal(idB))

        let sessionD = client.startSession()
        _ = try client.listDatabases(session: sessionD)
        expect(sessionD.active).to(beTrue())
        expect(sessionD.id).to(equal(idA))

        // test via explicitly ending
        sessionC.end()
        expect(sessionC.active).to(beFalse())
        sessionD.end()
        expect(sessionD.active).to(beFalse())

        // test via withSession
        try client.withSession { session in
            _ = try client.listDatabases(session: session)
            expect(session.id).to(equal(idA))
        }

        try client.withSession { session in
            _ = try client.listDatabases(session: session)
            expect(session.id).to(equal(idA))
        }

        try client.withSession { session in
            _ = try client.listDatabases(session: session)
            expect(session.id).to(equal(idA))
            try client.withSession { nestedSession in
                _ = try client.listDatabases(session: nestedSession)
                expect(nestedSession.id).to(equal(idB))
            }
        }
    }

    // Executes the body twice, once with the supplied session and once without, verifying that a correct lsid is
    // seen both times.
    func runArgTest(session: MongoSwiftSync.ClientSession, op: SessionOp) throws {
        let center = NotificationCenter.default

        var seenExplicit = false
        var seenImplicit = false
        let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
            guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                return
            }

            expect(event.command["lsid"]).toNot(beNil(), description: op.name)
            if !seenExplicit {
                expect(event.command["lsid"]).to(equal(.document(session.id!)), description: op.name)
                seenExplicit = true
            } else {
                expect(seenImplicit).to(beFalse())
                expect(event.command["lsid"]).toNot(equal(.document(session.id!)), description: op.name)
                seenImplicit = true
            }
        }
        // We don't care if they succeed (e.g. a drop index may fail if index doesn't exist)
        try? op.body(session)
        try? op.body(nil)

        expect(seenImplicit).to(beTrue(), description: op.name)
        expect(seenExplicit).to(beTrue(), description: op.name)

        center.removeObserver(observer)
    }

    /// Sessions spec test 3: test that every function that takes a session parameter passes the sends implicit and
    /// explicit lsids to server.
    func testSessionArguments() throws {
        let client1 = try MongoClient.makeTestClient(options: ClientOptions(commandMonitoring: true))
        let database = client1.db(type(of: self).testDatabase)
        let collection = try database.createCollection(self.getCollectionName())
        let session = client1.startSession()

        try self.forEachSessionOp(client: client1, database: database, collection: collection) { op in
            try runArgTest(session: session, op: op)
        }
    }

    /// Sessions spec test 4: test that a session can only be used with db's and collections that were derived from the
    /// same client.
    func testSessionClientValidation() throws {
        let client1 = try MongoClient.makeTestClient()
        let client2 = try MongoClient.makeTestClient()

        let database = client1.db(type(of: self).testDatabase)
        let collection = try database.createCollection(self.getCollectionName())

        let session = client2.startSession()
        try self.forEachSessionOp(client: client1, database: database, collection: collection) { op in
            expect(try op.body(session))
                .to(throwError(errorType: InvalidArgumentError.self), description: op.name)
        }
    }

    /// Sessions spec test 5: Test that inactive sessions cannot be used.
    func testInactiveSession() throws {
        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        let collection = try db.createCollection(self.getCollectionName())
        let session1 = client.startSession()

        session1.end()
        expect(session1.active).to(beFalse())

        try self.forEachSessionOp(client: client, database: db, collection: collection) { op in
            expect(try op.body(session1)).to(throwError(ClientSession.SessionInactiveError), description: op.name)
        }

        // TODO: SWIFT-672: enable
        // let session2 = client.startSession()
        // let database = client.db(type(of: self).testDatabase)
        // let collection1 = database.collection(self.getCollectionName())

        // try (1...3).forEach { try collection1.insertOne(["x": BSON($0)]) }

        // let cursor = try collection.find(session: session2)
        // expect(cursor.next()).toNot(beNil())
        // session2.end()
        // expect(try cursor.next()?.get()).to(throwError(ClientSession.SessionInactiveError))
    }

    // TODO: SWIFT-672: enable
    /// Sessions spec test 10: Test cursors have the same lsid in the initial find command and in subsequent getMores.
    // func testSessionCursor() throws {
    //     let client = try MongoClient.makeTestClient(options: ClientOptions(commandMonitoring: true))
    //     let database = client.db(type(of: self).testDatabase)
    //     let collection = try database.createCollection(self.getCollectionName())
    //     let session = client.startSession()

    //     for x in 1...3 {
    //         // use the session to trigger starting the libmongoc session
    //         try collection.insertOne(["x": BSON(x)], session: session)
    //     }

    //     var id: BSON?
    //     var seenFind = false
    //     var seenGetMore = false

    //     let center = NotificationCenter.default
    //     let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
    //         guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
    //             return
    //         }

    //         if event.command["find"] != nil {
    //             seenFind = true
    //             if let id = id {
    //                 expect(id).to(equal(event.command["lsid"]))
    //             } else {
    //                 expect(event.command["lsid"]).toNot(beNil())
    //                 id = event.command["lsid"]
    //             }
    //         } else if event.command["getMore"] != nil {
    //             seenGetMore = true
    //             expect(id).toNot(beNil())
    //             expect(event.command["lsid"]).toNot(beNil())
    //             expect(event.command["lsid"]).to(equal(id))
    //         }
    //     }

    //     // explicit
    //     id = .document(session.id!)
    //     seenFind = false
    //     seenGetMore = false
    //     let cursor = try collection.find(options: FindOptions(batchSize: 2), session: session)
    //     expect(cursor.next()).toNot(beNil())
    //     expect(cursor.next()).toNot(beNil())
    //     expect(cursor.next()).toNot(beNil())
    //     expect(seenFind).to(beTrue())
    //     expect(seenGetMore).to(beTrue())

    //     // implicit
    //     seenFind = false
    //     seenGetMore = false
    //     id = nil
    //     let cursor1 = try collection.find(options: FindOptions(batchSize: 2))
    //     expect(cursor1.next()).toNot(beNil())
    //     expect(cursor1.next()).toNot(beNil())
    //     expect(cursor1.next()).toNot(beNil())
    //     expect(seenFind).to(beTrue())
    //     expect(seenGetMore).to(beTrue())

    //     center.removeObserver(observer)
    // }

    /// Sessions spec test 11: Test that the clusterTime is reported properly.
    func testClusterTime() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print(unsupportedTopologyMessage(testName: self.name))
            return
        }

        let client = try MongoClient.makeTestClient()

        try client.withSession { session in
            expect(session.clusterTime).to(beNil())
            _ = try client.listDatabases(session: session)
            expect(session.clusterTime).toNot(beNil())
        }

        client.withSession { session in
            let date = Date()
            expect(session.clusterTime).to(beNil())
            let newTime: Document = [
                "clusterTime": .timestamp(Timestamp(timestamp: Int(date.timeIntervalSince1970), inc: 100))
            ]
            session.advanceClusterTime(to: newTime)
            expect(session.clusterTime).to(equal(newTime))
        }
    }

    /// Test that causal consistency guarantees are met on deployments that support cluster time.
    func testCausalConsistency() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print(unsupportedTopologyMessage(testName: self.name))
            return
        }

        let center = NotificationCenter.default
        let client = try MongoClient.makeTestClient(options: ClientOptions(commandMonitoring: true))
        let db = client.db(type(of: self).testDatabase)
        let collection = try db.createCollection(self.getCollectionName())

        // Causal consistency spec test 3: the first read/write on a session should update the operationTime of a
        // session.
        try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            var seenCommands = false
            let startObserver = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                    return
                }
                seenCommands = true
            }
            defer { center.removeObserver(startObserver) }

            var replyOpTime: Timestamp?
            let replyObserver = center.addObserver(forName: .commandSucceeded, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandSucceededEvent else {
                    return
                }
                replyOpTime = event.reply["operationTime"]?.timestampValue
            }
            defer { center.removeObserver(replyObserver) }

            _ = try collection.countDocuments(session: session)
            expect(seenCommands).to(beTrue())
            expect(replyOpTime).toNot(beNil())
            expect(replyOpTime).to(equal(session.operationTime))
        }

        // Causal consistency spec test 3: the first read/write on a session should update the operationTime of a
        // session, even when there is an error.
        client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            _ = try? db.runCommand(["axasdfasdf": 1], session: session)
            expect(session.operationTime).toNot(beNil())
        }

        // TODO: SWIFT-672: enable
        // Causal consistency spec test 4: A find followed by any other read operation should
        // include the operationTime returned by the server for the first operation in the afterClusterTime parameter of
        // the second operation
        //
        // Causal consistency spec test 8: When using the default server ReadConcern the readConcern parameter in the
        // command sent to the server should not include a level field
        // try self.collectionSessionReadOps.forEach { op in
        //     try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
        //         _ = try collection.find(session: session).next()
        //         let opTime = session.operationTime
        //         var seenCommand = false
        //         let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
        //             guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
        //                 return
        //             }
        //             let readConcern = event.command["readConcern"]?.documentValue
        //             expect(readConcern).toNot(beNil(), description: op.name)
        //             expect(readConcern!["afterClusterTime"]?.timestampValue).to(equal(opTime), description: op.name)
        //             expect(readConcern!["level"]).to(beNil(), description: op.name)
        //             seenCommand = true
        //         }
        //         defer { center.removeObserver(observer) }
        //         try op.body(collection, session)
        //         expect(seenCommand).to(beTrue(), description: op.name)
        //     }
        // }

        // TODO: SWIFT-672: enable
        // Causal consistency spec test 5: Any write operation followed by a find operation should include the
        // operationTime of the first operation in the afterClusterTime parameter of the second operation, including the
        // case where the first operation returned an error
        // try self.collectionSessionWriteOps.forEach { op in
        //     try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
        //         try? op.body(collection, session)
        //         let opTime = session.operationTime

        //         var seenCommand = false
        //         let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
        //             guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
        //                 return
        //             }
        //             expect(event.command["readConcern"]?.documentValue?["afterClusterTime"]?.timestampValue)
        //                 .to(equal(opTime), description: op.name)
        //             seenCommand = true
        //         }
        //         defer { center.removeObserver(observer) }
        //         _ = try collection.find(session: session).next()
        //         expect(seenCommand).to(beTrue(), description: op.name)
        //     }
        // }

        // Causal consistency spec test 6: A read operation in a ClientSession that is not causally consistent should
        // not include the afterClusterTime parameter in the command sent to the server
        try client.withSession(options: ClientSessionOptions(causalConsistency: false)) { session in
            var seenCommand = false
            _ = try collection.countDocuments(session: session)
            let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                    return
                }
                expect(event.command["readConcern"]?.documentValue?["afterClusterTime"]).to(beNil())
                seenCommand = true
            }
            defer { center.removeObserver(observer) }
            _ = try collection.countDocuments(session: session)
            expect(seenCommand).to(beTrue())
        }

        // Causal consistency spec test 9: When using a custom ReadConcern the readConcern field in the command sent to
        // the server should be a merger of the ReadConcern value and the afterClusterTime field
        try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            let collection1 = db.collection(
                self.getCollectionName(),
                options: CollectionOptions(readConcern: ReadConcern(.local))
            )
            _ = try collection1.countDocuments(session: session)
            let opTime = session.operationTime

            var seenCommand = false
            let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                    return
                }
                let readConcern = event.command["readConcern"]?.documentValue
                expect(readConcern).toNot(beNil())
                expect(readConcern!["afterClusterTime"]?.timestampValue).to(equal(opTime))
                expect(readConcern!["level"]).to(equal("local"))
                seenCommand = true
            }
            defer { center.removeObserver(observer) }
            _ = try collection1.countDocuments(session: session)
            expect(seenCommand).to(beTrue())
        }

        // Causal consistency spec test 12: When connected to a deployment that does support cluster times messages sent
        // to the server should include $clusterTime
        try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            var seenCommand = false
            let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                    return
                }
                expect(event.command["$clusterTime"]).toNot(beNil())
                seenCommand = true
            }
            defer { center.removeObserver(observer) }
            _ = try collection.countDocuments(session: session)
            expect(seenCommand).to(beTrue())
        }
    }

    /// Test causal consistent behavior on a topology that doesn't support cluster time.
    func testCausalConsistencyStandalone() throws {
        guard MongoSwiftTestCase.topologyType == .single else {
            print(unsupportedTopologyMessage(testName: self.name))
            return
        }

        let center = NotificationCenter.default
        let client = try MongoClient.makeTestClient(options: ClientOptions(commandMonitoring: true))
        let db = client.db(type(of: self).testDatabase)
        let collection = db.collection(self.getCollectionName())

        // Causal consistency spec test 7: A read operation in a causally consistent session against a deployment that
        // does not support cluster times does not include the afterClusterTime parameter in the command sent to the
        // server
        try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            _ = try collection.countDocuments(session: session)

            var seenCommand = false
            let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                    return
                }
                expect(event.command["readConcern"]?.documentValue?["afterClusterTime"]).to(beNil())
                seenCommand = true
            }
            defer { center.removeObserver(observer) }
            _ = try collection.countDocuments(session: session)
            expect(seenCommand).to(beTrue())
        }

        // Causal consistency spec test 11: When connected to a deployment that does not support cluster times messages
        // sent to the server should not include $clusterTime
        try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            _ = try collection.insertOne([:], session: session)
            let opTime = session.operationTime

            var seenCommand = false
            let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                    return
                }
                expect(event.command["$clusterTime"]).to(beNil())
                seenCommand = true
            }
            defer { center.removeObserver(observer) }
            _ = try collection.countDocuments(session: session)
            expect(seenCommand).to(beTrue())
        }
    }

    /// Test causal consistent behavior that is expected on any topology, regardless of whether it supports cluster time
    func testCausalConsistencyAnyTopology() throws {
        let center = NotificationCenter.default
        let client = try MongoClient.makeTestClient(options: ClientOptions(commandMonitoring: true))
        let db = client.db(type(of: self).testDatabase)
        let collection = db.collection(self.getCollectionName())

        // Causal consistency spec test 1: When a ClientSession is first created the operationTime has no value
        let session1 = client.startSession()
        expect(session1.operationTime).to(beNil())
        session1.end()

        // Causal consistency spec test 2: The first read in a causally consistent session must not send
        // afterClusterTime to the server (because the operationTime has not yet been determined)
        try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            var seenCommand = false
            let startObserver = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notif in
                guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                    return
                }
                expect(event.command["readConcern"]?.documentValue?["afterClusterTime"]).to(beNil())
                seenCommand = true
            }
            defer { center.removeObserver(startObserver) }

            _ = try collection.countDocuments(session: session)
            expect(seenCommand).to(beTrue())
        }

        // Causal consistency spec test 10: When an unacknowledged write is executed in a causally consistent
        // ClientSession the operationTime property of the ClientSession is not updated
        try client.withSession(options: ClientSessionOptions(causalConsistency: true)) { session in
            let collection1 = db.collection(
                self.getCollectionName(),
                options: CollectionOptions(writeConcern: try WriteConcern(w: .number(0)))
            )
            try collection1.insertOne(["x": 3])
            expect(session.operationTime).to(beNil())
        }
    }
}