import Foundation

/// `BSONDecoder` facilitates the decoding of BSON into semantic `Decodable` types.
public class BSONDecoder {

    @available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
    internal static var iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        return formatter
    }()

    /// Enum representing the different options for decoding `Date`s from BSON.
    public enum DateDecodingStrategy {
        /// Decode `Date`s stored as BSON datetimes.
        case bsonDateTime

        /// Decode `Date`s stored as 64 bit integers counting the number of milliseconds since January 1, 1970.
        case millisecondsSince1970Int64

        /// Decode `Date`s stored as 64 bit integers counting the number of seconds since January 1, 1970.
        case secondsSince1970Int64

        /// Decode `Date`s stored as `Double`s counting the number of seconds since January 1, 1970.
        case millisecondsSince1970

        /// Decode `Date`s stored as BSON doubles counting the number of milliseconds since January 1, 1970.
        case secondsSince1970

        /// Decode `Date`s by deferring to their default decoding implementation.
        case deferredToDate

        /// Decode `Date`s represented by ISO8601 formatted strings.
        @available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
        case iso8601

        /// Decode `Date`s stored as strings parsable by the given formatter.
        case formatted(DateFormatter)

        /// Decode `Date`s using the provided closure.
        case custom((_ decoder: Decoder) throws -> Date)
    }

    /// Enum representing the different options for decoding `UUID`s from BSON.
    public enum UUIDDecodingStrategy {
        /// Decode `UUID`s by deferring to their default decoding implementation.
        case deferredToUUID

        /// Decode `UUID`s from strings.
        case fromString

        /// Decode `UUID`s from the BSON `Binary` type.
        case fromBinary
    }

    /// Contextual user-provided information for use during decoding.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// The strategy used for decoding dates with this instance.
    public var dateDecodingStrategy: DateDecodingStrategy = .bsonDateTime

    /// The strategy used for decoding UUIDs with this instance.
    public var uuidDecodingStrategy: UUIDDecodingStrategy = .fromBinary

    /// Options set on the top-level decoder to pass down the decoding hierarchy.
    fileprivate struct _Options {
        let userInfo: [CodingUserInfoKey: Any]
        let dateDecodingStrategy: DateDecodingStrategy
        let uuidDecodingStrategy: UUIDDecodingStrategy
    }

    /// The options set on the top-level decoder.
    fileprivate var options: _Options {
        return _Options(userInfo: self.userInfo,
                        dateDecodingStrategy: self.dateDecodingStrategy,
                        uuidDecodingStrategy: self.uuidDecodingStrategy)
    }

    /// Initializes `self`.
    public init() {}

    /// Decodes a top-level value of the given type from the given BSON document.
    ///
    /// - parameter type: The type of the value to decode.
    /// - parameter document: The BSON document to decode from.
    /// - returns: A value of the requested type.
    /// - throws: An error if any value throws an error during decoding.
    public func decode<T: Decodable>(_ type: T.Type, from document: Document) throws -> T {
        /// if the requested type is `Document` we're done
        if let doc = document as? T { return doc }
        let _decoder = _BSONDecoder(referencing: document, options: self.options)
        return try type.init(from: _decoder)
    }

    /// Decodes a top-level value of the given type from the given BSON data.
    ///
    /// - parameter type: The type of the value to decode.
    /// - parameter data: The BSON data to decode from.
    /// - returns: A value of the requested type.
    /// - throws: An error if the BSON data is corrupt, or if any value throws an error during decoding.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try self.decode(type, from: Document(fromBSON: data))
    }

    /// Decodes a top-level value of the given type from the given JSON/extended JSON string.
    ///
    /// - parameter type: The type of the value to decode.
    /// - parameter json: The JSON string to decode from.
    /// - returns: A value of the requested type.
    /// - throws: An error if the JSON data is corrupt, or if any value throws an error during decoding.
    public func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        // we nest the input JSON in another object, and then decode to a `DecodableWrapper`
        // wrapping an object of the requested type. since our decoder only supports decoding
        // objects, this allows us to additionally handle decoding to primitive types like a
        // `String` or an `Int`.
        // while this is not needed to decode JSON representing objects, it is difficult to
        // determine when JSON represents an object vs. a primitive value -- for example,
        // {"$numberInt": "42"} is a JSON object and looks like an object type but is actually
        // a primitive type, Int32. so for simplicity, we just always assume wrapping is needed,
        // and pay a small performance penalty of decoding a few extra bytes.
        let wrapped = "{\"value\": \(json)}"

        if let doc = try? Document(fromJSON: wrapped) {
            let s = try self.decode(DecodableWrapper<T>.self, from: doc)
            return s.value
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [],
                                  debugDescription: "Unable to parse JSON string \(json)"))
    }

    /// A struct to wrap a `Decodable` type, allowing us to support decoding to types that
    /// are not inside a wrapping object (for ex., Int or String).
    private struct DecodableWrapper<T: Decodable>: Decodable {
        let value: T
    }
}

/// :nodoc: An internal class to actually implement the `Decoder` protocol.
internal class _BSONDecoder: Decoder {

    /// The decoder's storage.
    internal var storage: _BSONDecodingStorage

    /// Options set on the top-level decoder.
    fileprivate let options: BSONDecoder._Options

    /// The path to the current point in decoding.
    public fileprivate(set) var codingPath: [CodingKey]

    /// Contextual user-provided information for use during decoding.
    public var userInfo: [CodingUserInfoKey: Any] {
        return self.options.userInfo
    }

    /// Performs the given closure with the given key pushed onto the end of the current coding path.
    ///
    /// - parameter key: The key to push. May be nil for unkeyed containers.
    /// - parameter work: The work to perform with the key in the path.
    fileprivate func with<T>(pushedKey key: CodingKey, _ work: () throws -> T) rethrows -> T {
        self.codingPath.append(key)
        let ret: T = try work()
        self.codingPath.removeLast()
        return ret
    }

    /// Initializes `self` with the given top-level container and options.
    fileprivate init(referencing container: BSONValue, at codingPath: [CodingKey] = [],
                     options: BSONDecoder._Options) {
        self.storage = _BSONDecodingStorage()
        self.storage.push(container: container)
        self.codingPath = codingPath
        self.options = options
    }

    // Returns the data stored in this decoder as represented in a container keyed by the given key type.
    public func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard let topContainer = self.storage.topContainer as? Document else {
            throw DecodingError._typeMismatch(at: self.codingPath,
                                              expectation: Document.self,
                                              reality: self.storage.topContainer)
        }

        let container = _BSONKeyedDecodingContainer<Key>(referencing: self, wrapping: topContainer)
        return KeyedDecodingContainer(container)
    }

    // Returns the data stored in this decoder in a container appropriate for holding a single primitive value.
    public func singleValueContainer() throws -> SingleValueDecodingContainer {
        return self
    }

    // Returns the data stored in this decoder in a container appropriate for holding values with no keys.
    public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard let arr = self.storage.topContainer as? [BSONValue] else {
            throw DecodingError._typeMismatch(at: self.codingPath,
                                              expectation: [BSONValue].self,
                                              reality: self.storage.topContainer)
        }

        return _BSONUnkeyedDecodingContainer(referencing: self, wrapping: arr)
    }
}

// Storage for a _BSONDecoder.
internal struct _BSONDecodingStorage {

    /// The container stack, consisting of `BSONValue`s.
    fileprivate private(set) var containers: [BSONValue] = []

    /// Initializes `self` with no containers.
    fileprivate init() {}

    /// The count of containers stored.
    fileprivate var count: Int { return self.containers.count }

    /// The container at the top of the stack.
    internal var topContainer: BSONValue {
        precondition(self.containers.count > 0, "Empty container stack.")
        return self.containers.last!
    }

    /// Adds a new container to the stack.
    fileprivate mutating func push(container: BSONValue) {
        self.containers.append(container)
    }

    /// Pops the top container from the stack. 
    fileprivate mutating func popContainer() {
        precondition(self.containers.count > 0, "Empty container stack.")
        self.containers.removeLast()
    }
}

/// Extend _BSONDecoder to add methods for "unboxing" values as various types.
extension _BSONDecoder {

    fileprivate func unboxBSONValue<T: BSONValue>(_ value: BSONValue, as type: T.Type) throws -> T {
        // We throw in the case of BSONNull because nulls should be requested through decodeNil().
        guard !(value is BSONNull) else {
            throw DecodingError.valueNotFound(
                type,
                DecodingError.Context(codingPath: self.codingPath,
                                      debugDescription: "Expected a non-null type."))
        }

        guard let typed = value as? T else {
            throw DecodingError._typeMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        return typed
    }

    fileprivate func unboxNumber<T: CodableNumber>(_ value: BSONValue, as type: T.Type) throws -> T {
        guard let primitive = T(from: value) else {
            throw DecodingError._numberMismatch(at: self.codingPath, expectation: type, reality: value)
        }
        return primitive
    }

    /// Private helper function used specifically for decoding dates.
    // swiftlint:disable cyclomatic_complexity
    fileprivate func unboxDate(_ value: BSONValue) throws -> Date {
        switch self.options.dateDecodingStrategy {
        case .bsonDateTime:
            guard let date = value as? Date else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: Date.self, reality: value)
            }
            return date
        case .deferredToDate:
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try Date(from: self)
        case .millisecondsSince1970:
            let val = try self.unbox(value, as: TimeInterval.self)
            return Date(timeIntervalSince1970: val / 1000.0)
        case .secondsSince1970:
            let val = try self.unbox(value, as: TimeInterval.self)
            return Date(timeIntervalSince1970: val)
        case .millisecondsSince1970Int64:
            let val = try self.unbox(value, as: Int64.self)
            return Date(msSinceEpoch: val)
        case .secondsSince1970Int64:
            let val = try self.unbox(value, as: Int64.self)
            return Date(timeIntervalSince1970: TimeInterval(val))
        case .iso8601:
            if #available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
                let isoString = try self.unbox(value, as: String.self)
                guard let date = BSONDecoder.iso8601Formatter.date(from: isoString) else {
                    throw MongoError.bsonDecodeError(message: "Improperly formatted ISO 8601 Date string")
                }
                return date
            } else {
                throw MongoError.bsonDecodeError(message: "ISO8601DateFormatter is unavailable on this platform.")
            }
        case .custom(let f):
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try f(self)
        case .formatted(let formatter):
            let dateString = try self.unbox(value, as: String.self)
            guard let date = formatter.date(from: dateString) else {
                throw MongoError.bsonDecodeError(message: "Date string does not match format expected by formatter.")
            }
            return date
        }
    }
    // swiftlint:enable cyclomatic_complexity

    /// Private helper used specifically for decoding UUIDs.
    fileprivate func unboxUUID(_ value: BSONValue) throws -> UUID {
        switch self.options.uuidDecodingStrategy {
        case .deferredToUUID:
            self.storage.push(container: value)
            defer { self.storage.popContainer() }
            return try UUID(from: self)
        case .fromString:
            let uuidString = try self.unbox(value, as: String.self)
             guard let uuid = UUID(uuidString: uuidString) else {
                throw MongoError.bsonDecodeError(message: "Could not decode UUID from \(uuidString)")
            }
            return uuid
        case .fromBinary:
            let binary = try self.unbox(value, as: Binary.self)
            return try UUID(fromBinary: binary)
        }
    }

    fileprivate func unbox<T: Decodable>(_ value: BSONValue, as type: T.Type) throws -> T {
        // swiftlint:disable force_cast
        if type == Date.self {
            // We know T is a Date and unboxDate returns a Date or throws, so this cast will always work
            return try unboxDate(value) as! T
        } else if type == UUID.self {
            // We know T is a Date and unboxUUID returns a UUID or throws, so this cast will always work
            return try unboxUUID(value) as! T
        }
        // swiftlint:enable force_cast

        // if the data is already stored as the correct type in the document, then we can short-circuit
        // and just return the typed value here
        if let val = value as? T { return val }

        self.storage.push(container: value)
        defer { self.storage.popContainer() }
        return try T(from: self)
    }
}

/// A keyed decoding container, backed by a `Document`.
private struct _BSONKeyedDecodingContainer<K: CodingKey> : KeyedDecodingContainerProtocol {
    typealias Key = K

    /// A reference to the decoder we're reading from.
    private let decoder: _BSONDecoder

    /// A reference to the container we're reading from.
    fileprivate let container: Document

    /// The path of coding keys taken to get to this point in decoding.
    public private(set) var codingPath: [CodingKey]

    /// Initializes `self`, referencing the given decoder and container.
    fileprivate init(referencing decoder: _BSONDecoder, wrapping container: Document) {
        self.decoder = decoder
        self.container = container
        self.codingPath = decoder.codingPath
    }

    /// All the keys the decoder has for this container.
    public var allKeys: [Key] {
        #if swift(>=4.1)
        return self.container.keys.compactMap { Key(stringValue: $0) }
        #else
        return self.container.keys.flatMap { Key(stringValue: $0) }
        #endif

    }

    /// Returns a Boolean value indicating whether the decoder contains a value associated with the given key.
    public func contains(_ key: Key) -> Bool {
        return self.container.hasKey(key.stringValue)
    }

    /// A string description of a CodingKey, for use in error messages.
    private func _errorDescription(of key: CodingKey) -> String {
        return "\(key) (\"\(key.stringValue)\")"
    }

    /// Private helper function to check for a value in self.container. Returns the value stored
    /// under `key`, or throws an error if the value is not found.
    private func getValue(forKey key: Key) throws -> BSONValue {
        guard let entry = try self.container.getValue(for: key.stringValue) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(codingPath: self.decoder.codingPath,
                                      debugDescription: "No value associated with key \(_errorDescription(of: key))."))
        }
        return entry
    }

    /// Decode a BSONValue type from this container for the given key.
    private func decodeBSONType<T: BSONValue>(_ type: T.Type, forKey key: Key) throws -> T {
        let entry = try getValue(forKey: key)
        return try self.decoder.with(pushedKey: key) {
            try decoder.unboxBSONValue(entry, as: type)
        }
    }

    /// Decodes a CodableNumber type from this container for the given key.
    private func decodeNumber<T: CodableNumber>(_ type: T.Type, forKey key: Key) throws -> T {
        let entry = try getValue(forKey: key)
        return try self.decoder.with(pushedKey: key) {
            try decoder.unboxNumber(entry, as: type)
        }
    }

    /// Decodes a Decodable type from this container for the given key.
    public func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let entry = try getValue(forKey: key)
        return try self.decoder.with(pushedKey: key) {
            let value = try decoder.unbox(entry, as: type)
            guard !(value is BSONNull) else {
                throw DecodingError.valueNotFound(
                    type,
                    DecodingError.Context(codingPath: self.decoder.codingPath,
                                          debugDescription: "Expected \(type) value but found null instead."))
            }
            return value
        }
    }

    /// Decodes a null value for the given key.
    public func decodeNil(forKey key: Key) throws -> Bool {
        // check if the key exists in the document, so we can differentiate between
        // the key being set to nil and the key not existing at all.
        guard self.contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(codingPath: self.decoder.codingPath,
                                      debugDescription: "Key \(_errorDescription(of: key)) not found."))
        }
        return try self.container.getValue(for: key.stringValue) is BSONNull
    }

    // swiftlint:disable line_length
    public func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { return try decodeBSONType(type, forKey: key) }
    public func decode(_ type: Int.Type, forKey key: Key) throws -> Int { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: Float.Type, forKey key: Key) throws -> Float { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: Double.Type, forKey key: Key) throws -> Double { return try decodeNumber(type, forKey: key) }
    public func decode(_ type: String.Type, forKey key: Key) throws -> String { return try decodeBSONType(type, forKey: key) }
    // swiftlint:enable line_length

    /// Returns the data stored for the given key as represented in a container keyed by the given key type.
    public func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type,
                                           forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        return try self.decoder.with(pushedKey: key) {
            let value = try getValue(forKey: key)

            guard let doc = value as? Document else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: Document.self, reality: value)
            }

            let container = _BSONKeyedDecodingContainer<NestedKey>(referencing: self.decoder, wrapping: doc)
            return KeyedDecodingContainer(container)
        }
    }

    /// Returns the data stored for the given key as represented in an unkeyed container.
    public func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        return try self.decoder.with(pushedKey: key) {
            let value = try getValue(forKey: key)

            guard let array = value as? [BSONValue] else {
                throw DecodingError._typeMismatch(at: self.codingPath, expectation: [BSONValue].self, reality: value)
            }

            return _BSONUnkeyedDecodingContainer(referencing: self.decoder, wrapping: array)
        }
    }

    /// Private method to create a superDecoder for the provided key.
    private func _superDecoder(forKey key: CodingKey) throws -> Decoder {
        return try self.decoder.with(pushedKey: key) {
            guard let value = try self.container.getValue(for: key.stringValue) else {
                throw DecodingError.keyNotFound(key,
                                                DecodingError.Context(
                                                    codingPath: self.decoder.codingPath,
                                                    debugDescription: "Could not find key \(key) in Decoder container"
                                                )
                )
            }
            return _BSONDecoder(referencing: value, at: self.decoder.codingPath, options: self.decoder.options)
        }
    }

    /// Returns a Decoder instance for decoding super from the container associated with the default super key.
    public func superDecoder() throws -> Decoder {
        return try _superDecoder(forKey: _BSONKey.super)
    }

    // Returns a Decoder instance for decoding super from the container associated with the given key.
    public func superDecoder(forKey key: Key) throws -> Decoder {
        return try _superDecoder(forKey: key)
    }
}

private struct _BSONUnkeyedDecodingContainer: UnkeyedDecodingContainer {

    /// A reference to the decoder we're reading from.
    private let decoder: _BSONDecoder

    /// A reference to the container we're reading from.
    private let container: [BSONValue]

    /// The path of coding keys taken to get to this point in decoding.
    public private(set) var codingPath: [CodingKey]

    /// The index of the element we're about to decode.
    public private(set) var currentIndex: Int

    /// Initializes `self` by referencing the given decoder and container.
    fileprivate init(referencing decoder: _BSONDecoder, wrapping container: [BSONValue]) {
        self.decoder = decoder
        self.container = container
        self.codingPath = decoder.codingPath
        self.currentIndex = 0
    }

    /// The number of elements contained within this container.
    public var count: Int? { return self.container.count }

    /// A Boolean value indicating whether there are no more elements left to be decoded in the container.
    public var isAtEnd: Bool { return self.currentIndex >= self.count! }

    /// A private helper function to check if we're at the end of the container, and if so throw an error. 
    private func checkAtEnd() throws {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFound(
                BSONValue.self,
                DecodingError.Context(codingPath: self.decoder.codingPath + [_BSONKey(index: self.currentIndex)],
                                      debugDescription: "Unkeyed container is at end."))
        }
    }

    /// Decodes a BSONValue type from this container.
    private mutating func decodeBSONType<T: BSONValue>(_ type: T.Type) throws -> T {
        try self.checkAtEnd()
        return try self.decoder.with(pushedKey: _BSONKey(index: self.currentIndex)) {
            let typed = try self.decoder.unboxBSONValue(self.container[currentIndex], as: type)
            self.currentIndex += 1
            return typed
        }
    }

    /// Decodes a CodableNumber type from this container.
    private mutating func decodeNumber<T: CodableNumber>(_ type: T.Type) throws -> T {
        try self.checkAtEnd()
        return try self.decoder.with(pushedKey: _BSONKey(index: self.currentIndex)) {
            let typed = try self.decoder.unboxNumber(self.container[currentIndex], as: type)
            self.currentIndex += 1
            return typed
        }
    }

    /// Decodes a Decodable type from this container.
    public mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try self.checkAtEnd()
        return try self.decoder.with(pushedKey: _BSONKey(index: self.currentIndex)) {
            let decoded = try self.decoder.unbox(self.container[currentIndex], as: T.self)
            guard !(decoded is BSONNull) else {
                throw DecodingError.valueNotFound(
                    type,
                    DecodingError.Context(
                        codingPath: self.decoder.codingPath + [_BSONKey(index: self.currentIndex)],
                        debugDescription: "Expected \(type) but found null instead."))
            }
            self.currentIndex += 1
            return decoded
        }
    }

    /// Decodes a null value from this container.
    public mutating func decodeNil() throws -> Bool {
        try self.checkAtEnd()

        if self.container[self.currentIndex] is BSONNull {
            self.currentIndex += 1
            return true
        }
        return false
    }

    /// Decode all required types from this container using the helpers defined above.
    public mutating func decode(_ type: Bool.Type) throws -> Bool { return try self.decodeBSONType(type) }
    public mutating func decode(_ type: Int.Type) throws -> Int { return try self.decodeNumber(type) }
    public mutating func decode(_ type: Int8.Type) throws -> Int8 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: Int16.Type) throws -> Int16 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: Int32.Type) throws -> Int32 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: Int64.Type) throws -> Int64 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: UInt.Type) throws -> UInt { return try self.decodeNumber(type) }
    public mutating func decode(_ type: UInt8.Type) throws -> UInt8 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: UInt16.Type) throws -> UInt16 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: UInt32.Type) throws -> UInt32 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: UInt64.Type) throws -> UInt64 { return try self.decodeNumber(type) }
    public mutating func decode(_ type: Float.Type) throws -> Float { return try self.decodeNumber(type) }
    public mutating func decode(_ type: Double.Type) throws -> Double { return try self.decodeNumber(type) }
    public mutating func decode(_ type: String.Type) throws -> String { return try self.decodeBSONType(type) }

    /// Decodes a nested container keyed by the given type.
    public mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type)
        throws -> KeyedDecodingContainer<NestedKey> {
        return try self.decoder.with(pushedKey: _BSONKey(index: self.currentIndex)) {
            try self.checkAtEnd()
            let doc = try self.decodeBSONType(Document.self)
            self.currentIndex += 1
            let container = _BSONKeyedDecodingContainer<NestedKey>(referencing: self.decoder, wrapping: doc)
            return KeyedDecodingContainer(container)
        }
    }

    /// Decodes an unkeyed nested container.
    public mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        return try self.decoder.with(pushedKey: _BSONKey(index: self.currentIndex)) {
            try self.checkAtEnd()
            let array = try self.decodeBSONType([BSONValue].self)
            self.currentIndex += 1
            return _BSONUnkeyedDecodingContainer(referencing: self.decoder, wrapping: array)
        }
    }

    /// Decodes a nested container and returns a Decoder instance for decoding super from that container.
    public mutating func superDecoder() throws -> Decoder {
        return try self.decoder.with(pushedKey: _BSONKey(index: self.currentIndex)) {
            try self.checkAtEnd()
            let value = self.container[self.currentIndex]
            self.currentIndex += 1
            return _BSONDecoder(referencing: value, at: self.decoder.codingPath, options: self.decoder.options)
        }
    }
}

/// :nodoc:
extension _BSONDecoder: SingleValueDecodingContainer {

    /// Assert that the top container for this decoder is non-null.
    private func expectNonNull<T>(_ type: T.Type) throws {
        guard !self.decodeNil() else {
            throw DecodingError.valueNotFound(
                type,
                DecodingError.Context(codingPath: self.codingPath,
                                      debugDescription: "Expected \(type) but found null value instead."))
        }
    }

    /// Decode a BSONValue type from this container.
    private func decodeBSONType<T: BSONValue>(_ type: T.Type) throws -> T {
        try expectNonNull(T.self)
        return try self.unboxBSONValue(self.storage.topContainer, as: T.self)
    }

    /// Decode a CodableNumber type from this container.
    private func decodeNumber<T: CodableNumber>(_ type: T.Type) throws -> T {
        try expectNonNull(T.self)
        return try self.unboxNumber(self.storage.topContainer, as: T.self)
    }

    /// Decode a Decodable type from this container.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try expectNonNull(T.self)
        return try self.unbox(self.storage.topContainer, as: T.self)
    }

    /// Decode a null value from this container.
    public func decodeNil() -> Bool { return self.storage.topContainer is BSONNull }

    /// Decode all the required types from this container using the helpers defined above.
    public func decode(_ type: Bool.Type) throws -> Bool { return try decodeBSONType(type) }
    public func decode(_ type: Int.Type) throws -> Int { return try decodeNumber(type) }
    public func decode(_ type: Int8.Type) throws -> Int8 { return try decodeNumber(type) }
    public func decode(_ type: Int16.Type) throws -> Int16 { return try decodeNumber(type) }
    public func decode(_ type: Int32.Type) throws -> Int32 { return try decodeNumber(type) }
    public func decode(_ type: Int64.Type) throws -> Int64 { return try decodeNumber(type) }
    public func decode(_ type: UInt.Type) throws -> UInt { return try decodeNumber(type) }
    public func decode(_ type: UInt8.Type) throws -> UInt8 { return try decodeNumber(type) }
    public func decode(_ type: UInt16.Type) throws -> UInt16 { return try decodeNumber(type) }
    public func decode(_ type: UInt32.Type) throws -> UInt32 { return try decodeNumber(type) }
    public func decode(_ type: UInt64.Type) throws -> UInt64 { return try decodeNumber(type) }
    public func decode(_ type: Float.Type) throws -> Float { return try decodeNumber(type) }
    public func decode(_ type: Double.Type) throws -> Double { return try decodeNumber(type) }
    public func decode(_ type: String.Type) throws -> String { return try decodeBSONType(type) }
}

internal struct _BSONKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

    public init(stringValue: String, intValue: Int?) {
        self.stringValue = stringValue
        self.intValue = intValue
    }

    internal init(index: Int) {
        self.stringValue = "Index \(index)"
        self.intValue = index
    }

    internal static let `super` = _BSONKey(stringValue: "super")!
}

internal extension DecodingError {
    static func _typeMismatch(at path: [CodingKey], expectation: Any.Type, reality: BSONValue) -> DecodingError {
        let description = "Expected to decode \(expectation) but found \(type(of: reality)) instead."
        return .typeMismatch(expectation, Context(codingPath: path, debugDescription: description))
    }

    static func _numberMismatch(at path: [CodingKey], expectation: Any.Type, reality: BSONValue) -> DecodingError {
        let description = "Expected to find a value that can be represented as a \(expectation), " +
                         "but found value \(String(describing: reality)) of type \(type(of: reality)) instead."
        return .typeMismatch(expectation, Context(codingPath: path, debugDescription: description))
    }
}
