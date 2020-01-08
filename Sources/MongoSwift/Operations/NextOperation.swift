import CLibMongoC

/// An operation corresponding to a `next` call on a `NextOperationTarget`.
internal struct NextOperation<T: Codable>: Operation {
    private let target: CursorObject<T>

    internal init(target: CursorObject<T>) {
        self.target = target
    }

    internal func execute(using _: Connection, session: ClientSession?) throws -> T? {
        // NOTE: this method does not actually use the `connection` parameter passed in. for the moment, it is only
        // here so that `NextOperation` conforms to `Operation`. if we eventually rewrite our cursors to no longer
        // wrap a mongoc cursor then we will use the connection here.
        if let session = session, !session.active {
            throw ClientSession.SessionInactiveError
        }

        switch self.target {
        case let .cursor(cursor):
            return try cursor.getNextDocumentFromMongocCursor()
        case let .changeStream(changeStream):
            return try changeStream.fetchNextDocument()
        }
    }
}
