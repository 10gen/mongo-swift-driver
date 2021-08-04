import Foundation
import MongoSwiftSync

private let configs = ["ATLAS_REPL", "ATLAS_SHRD", "ATLAS_FREE", "ATLAS_TLS11", "ATLAS_TLS12"]
private let srvConfigs = configs.map { $0 + "_SRV" }
/// Currently, almost all of the Atlas test instances are running server versions that do not yet support the new
/// "hello" command.
private let legacyHello = "ismaster"

for config in configs + srvConfigs {
    print("Testing config \(config)... ", terminator: "")

    guard let uri = ProcessInfo.processInfo.environment[config] else {
        print("Failed: couldn't find URI for config \(config)")
        exit(1)
    }

    do {
        let client = try MongoClient(uri)
        // run legacy hello command
        let db = client.db("test")
        _ = try db.runCommand([legacyHello: 1])
        // findOne
        let coll = db.collection("test")
        _ = try coll.findOne()
    } catch {
        print("Failed: \(error)")
        exit(1)
    }

    print("Success")
}

print("All tests passed")
