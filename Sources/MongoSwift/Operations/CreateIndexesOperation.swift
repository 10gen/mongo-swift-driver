import mongoc

/// Options to use when creating a new index on a `MongoCollection`.
public struct CreateIndexOptions: Encodable {
    /// An optional `WriteConcern` to use for the command.
    public let writeConcern: WriteConcern?

    /// Initializer allowing any/all parameters to be omitted.
    public init(writeConcern: WriteConcern? = nil) {
        self.writeConcern = writeConcern
    }
}

/// An operation corresponding to a "createIndexes" command.
internal struct CreateIndexesOperation<T: Codable>: Operation {
    private let collection: MongoCollection<T>
    private let models: [IndexModel]
    private let options: CreateIndexOptions?
    private let session: ClientSession?

    internal init(collection: MongoCollection<T>,
                  models: [IndexModel],
                  options: CreateIndexOptions?,
                  session: ClientSession?) {
        self.collection = collection
        self.models = models
        self.options = options
        self.session = session
    }

    internal func execute() throws -> [String] {
        var indexData = [Document]()
        for index in self.models {
            var indexDoc = try self.collection.encoder.encode(index)
            if let opts = try self.collection.encoder.encode(index.options) {
                try indexDoc.merge(opts)
            }
            indexData.append(indexDoc)
        }

        let command: Document = ["createIndexes": self.collection.name, "indexes": indexData]

        let opts = try combine(options: options, session: session, using: self.collection.encoder)

        var error = bson_error_t()
        let reply = Document()

        guard mongoc_collection_write_command_with_opts(
            self.collection._collection, command.data, opts?.data, reply.data, &error) else {
            throw getErrorFromReply(bsonError: error, from: reply)
        }

        return self.models.map { $0.options?.name ?? $0.defaultName }
    }
}
