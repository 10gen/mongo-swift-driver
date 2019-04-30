import mongoc

private final class MongocInitializer {
    private static let versionString = "0.1.0"
    internal static let shared = MongocInitializer()

    private init() {
        mongoc_init()
        mongoc_handshake_data_append("MongoSwift", MongocInitializer.versionString, nil)
    }
}

/// Initializes libmongoc. Repeated calls to this method have no effect.
internal func initializeMongoc() {
    _ = MongocInitializer.shared
}

/**
 * Release all memory and other resources allocated by libmongoc.
 *
 * This function should be called once at the end of the application. Users
 * should not interact with the driver after calling this function.
 */
public func cleanupMongoc() {
    /* Note: ideally, this would be called from MongocInitializer's deinit,
     * but Swift does not currently handle deinitialization of singletons.
     * See: https://bugs.swift.org/browse/SR-2500 */
    mongoc_cleanup()
}
