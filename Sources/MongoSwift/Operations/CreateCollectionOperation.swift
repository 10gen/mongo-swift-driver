import mongoc

/// Options to use when executing a `createCollection` command on a `MongoDatabase`.
public struct CreateCollectionOptions: Codable, CodingStrategyProvider {
    /// Indicates whether this will be a capped collection.
    public let capped: Bool?

    /// Whether or not this collection will automatically generate an index on _id.
    public let autoIndexId: Bool?

    /// Maximum size, in bytes, of this collection (if capped).
    public let size: Int64?

    /// Maximum number of documents allowed in the collection (if capped).
    public let max: Int64?

    /// Specifies storage engine configuration for this collection.
    public let storageEngine: Document?

    /// What validator should be used for the collection.
    public let validator: Document?

    /// Determines how strictly MongoDB applies the validation rules to existing documents during an update.
    public let validationLevel: String?

    /// Determines whether to error on invalid documents or just warn about the violations but allow invalid documents
    /// to be inserted.
    public let validationAction: String?

    /// Specify a default configuration for indexes created on this collection.
    public let indexOptionDefaults: Document?

    /// The name of the source collection or view from which to create the view.
    public let viewOn: String?

    /// An array consisting of aggregation pipeline stages. When used with `viewOn`, will create the view by applying
    /// this pipeline to the source collection or view.
    public let pipeline: [Document]?

    /// Specifies the default collation for the collection.
    public let collation: Document?

    /// A write concern to use when executing this command. To set a read or write concern for the collection itself,
    /// retrieve the collection using `MongoDatabase.collection`.
    public let writeConcern: WriteConcern?

    // swiftlint:disable redundant_optional_initialization
    // to get synthesized decodable conformance for the struct, these strategies need default values.

    /// Specifies the `DateCodingStrategy` to use for BSON encoding/decoding operations performed by this collection.
    /// It is the responsibility of the user to ensure that any `Date`s already stored in this collection can be
    /// decoded using this strategy.
    public var dateCodingStrategy: DateCodingStrategy? = nil

    /// Specifies the `UUIDCodingStrategy` to use for BSON encoding/decoding operations performed by this collection.
    /// It is the responsibility of the user to ensure that any `UUID`s already stored in this collection can be
    /// decoded using this strategy.
    public var uuidCodingStrategy: UUIDCodingStrategy? = nil

    /// Specifies the `DataCodingStrategy` to use for BSON encoding/decoding operations performed by this collection.
    /// It is the responsibility of the user to ensure that any `Data`s already stored in this collection can be
    /// decoded using this strategy.
    public var dataCodingStrategy: DataCodingStrategy? = nil
    // swiftlint:enable redundant_optional_initialization

    private enum CodingKeys: String, CodingKey {
        case capped, autoIndexId, size, max, storageEngine, validator, validationLevel, validationAction,
             indexOptionDefaults, viewOn, pipeline, collation, writeConcern
    }

    /// Convenience initializer allowing any/all parameters to be omitted or optional.
    public init(autoIndexId: Bool? = nil,
                capped: Bool? = nil,
                collation: Document? = nil,
                indexOptionDefaults: Document? = nil,
                max: Int64? = nil,
                pipeline: [Document]? = nil,
                size: Int64? = nil,
                storageEngine: Document? = nil,
                validationAction: String? = nil,
                validationLevel: String? = nil,
                validator: Document? = nil,
                viewOn: String? = nil,
                writeConcern: WriteConcern? = nil,
                dateCodingStrategy: DateCodingStrategy? = nil,
                uuidCodingStrategy: UUIDCodingStrategy? = nil,
                dataCodingStrategy: DataCodingStrategy? = nil) {
        self.autoIndexId = autoIndexId
        self.capped = capped
        self.collation = collation
        self.indexOptionDefaults = indexOptionDefaults
        self.max = max
        self.pipeline = pipeline
        self.size = size
        self.storageEngine = storageEngine
        self.validationAction = validationAction
        self.validationLevel = validationLevel
        self.validator = validator
        self.viewOn = viewOn
        self.writeConcern = writeConcern
        self.dateCodingStrategy = dateCodingStrategy
        self.uuidCodingStrategy = uuidCodingStrategy
        self.dataCodingStrategy = dataCodingStrategy
    }
}

// An operation corresponding to a `createCollection` command on a MongoDatabase.
internal struct CreateCollectionOperation<T: Codable>: Operation {
    private let database: MongoDatabase
    private let name: String
    private let type: T.Type
    private let options: CreateCollectionOptions?
    private let session: ClientSession?

    internal init(database: MongoDatabase,
                  name: String,
                  type: T.Type,
                  options: CreateCollectionOptions?,
                  session: ClientSession?) {
        self.database = database
        self.name = name
        self.type = type
        self.options = options
        self.session = session
    }

    internal func execute() throws -> MongoCollection<T> {
        let opts = try encodeOptions(options: self.options, session: self.session)
        var error = bson_error_t()

        guard let collection = mongoc_database_create_collection(
            self.database._database, self.name, opts?.data, &error) else {
            throw parseMongocError(error)
        }

        let encoder = BSONEncoder(copies: self.database.encoder, options: self.options)
        let decoder = BSONDecoder(copies: self.database.decoder, options: self.options)

        return MongoCollection(
                fromCollection: collection,
                withClient: self.database._client,
                withEncoder: encoder,
                withDecoder: decoder
        )
    }
}
