import Foundation

public enum BSON {
    case double(Double)
    case string(String)
    case document(PureBSONDocument)
    indirect case array([BSON])
    case binary(PureBSONBinary)
    case undefined
    case objectId(PureBSONObjectId)
    case bool(Bool)
    case date(Date)
    case null
    case regex(PureBSONRegularExpression)
    case dbPointer(PureBSONDBPointer)
    case symbol(String)
    case code(PureBSONCode)
    case codeWithScope(PureBSONCodeWithScope)
    case int32(Int32)
    case timestamp(PureBSONTimestamp)
    case int64(Int64)
    // decimal128
    case minKey
    case maxKey

    public var doubleValue: Double? {
        guard case let .double(double) = self else {
            return nil
        }
        return double
    }

    public var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    public var documentValue: PureBSONDocument? {
        guard case let .document(value) = self else {
            return nil
        }
        return value
    }

    public var arrayValue: [BSON]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    public var binaryValue: PureBSONBinary? {
        guard case let .binary(value) = self else {
            return nil
        }
        return value
    }

    public var isUndefined: Bool {
        return self == .undefined
    }

    public var objectIdValue: PureBSONObjectId? {
        guard case let .objectId(value) = self else {
            return nil
        }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }

    public var dateValue: Date? {
        guard case let .date(value) = self else {
            return nil
        }
        return value
    }

    public var isNull: Bool {
        return self == .null
    }

    public var regexValue: PureBSONRegularExpression? {
        guard case let .regex(value) = self else {
            return nil
        }
        return value
    }

    public var dbPointerValue: PureBSONDBPointer? {
        guard case let .dbPointer(value) = self else {
            return nil
        }
        return value
    }

    public var symbolValue: String? {
        guard case let .symbol(value) = self else {
            return nil
        }
        return value
    }

    public var codeWithScopeValue: PureBSONCodeWithScope? {
        guard case let .codeWithScope(value) = self else {
            return nil
        }
        return value
    }

    public var int32Value: Int32? {
        guard case let .int32(value) = self else {
            return nil
        }
        return value
    }

    public var timestampValue: PureBSONTimestamp? {
        guard case let .timestamp(value) = self else {
            return nil
        }
        return value
    }

    public var int64Value: Int64? {
        guard case let .int64(value) = self else {
            return nil
        }
        return value
    }

    public var isMinKey: Bool {
        return self == .minKey
    }

    public var isMaxKey: Bool {
        return self == .maxKey
    }

    public var intValue: Int? {
        switch self {
        case let .int32(value):
            return Int(value)
        case let .int64(value):
            return Int(exactly: value)
        case let .double(value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    internal var bsonValue: PureBSONValue {
        switch self {
        case .null:
            return PureBSONNull()
        case .undefined:
            return PureBSONUndefined()
        case .minKey:
            return PureBSONMinKey()
        case .maxKey:
            return PureBSONMaxKey()
        case let .symbol(v):
            return PureBSONSymbol(v)
        case let .double(v):
            return v
        case let .string(v):
            return v
        case let .document(v):
            return v
        case let .binary(v):
            return v
        case let .objectId(v):
            return v
        case let .bool(v):
            return v
        case let .date(v):
            return v
        case let .regex(v):
            return v
        case let .dbPointer(v):
            return v
        case let .code(v):
            return v
        case let .codeWithScope(v):
            return v
        case let .int32(v):
            return v
        case let .timestamp(v):
            return v
        case let .int64(v):
            return v
        case let .array(v):
            return v
        }
    }

    internal func toBSON() -> Data {
        return self.bsonValue.toBSON()
    }

    internal var bsonType: UInt8 {
        return UInt8(type(of: self.bsonValue).bsonType.rawValue)
    }
}

extension BSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension BSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension BSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension BSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int64(Int64(value))
    }
}

extension BSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, BSON)...) {
        self = .document(PureBSONDocument(elements: elements))
    }
}

extension BSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: BSON...) {
        self = .array(elements)
    }
}

extension BSON: Equatable {}
extension BSON: Hashable {}

extension BSON: Codable {
    public init(from decoder: Decoder) throws {
        // short-circuit when using `BSONDecoder`
        if let bsonDecoder = decoder as? _PureBSONDecoder {
            self = bsonDecoder.storage.topContainer.bson
            return
        }

        let container = try decoder.singleValueContainer()

        // since we aren't sure which BSON type this is, just try decoding
        // to each of them and go with the first one that succeeds
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONBinary.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONObjectId.self) {
            self = value.bson
        } else if let value = try? container.decode(Bool.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONRegularExpression.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONCodeWithScope.self) {
            self = value.bson
        } else if let value = try? container.decode(Int.self) {
            self = value.bson
        } else if let value = try? container.decode(Int32.self) {
            self = value.bson
        } else if let value = try? container.decode(Int64.self) {
            self = value.bson
        } else if let value = try? container.decode(Double.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONMinKey.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONMaxKey.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONDocument.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONTimestamp.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONUndefined.self) {
            self = value.bson
        } else if let value = try? container.decode(PureBSONDBPointer.self) {
            self = value.bson
        } else {
            throw DecodingError.typeMismatch(
                    BSON.self,
                    DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "Encountered a value that could not be decoded to any BSON type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try self.bsonValue.encode(to: encoder)
    }
}

internal protocol PureBSONValue: Codable {
    init(from data: inout Data) throws
    func toBSON() -> Data
    var bson: BSON { get }
    static var bsonType: BSONType { get }
}

extension PureBSONValue where Self: ExpressibleByIntegerLiteral {
    init(from data: inout Data) throws {
        self = try readInteger(from: &data)
    }
}

extension PureBSONValue where Self: Numeric {
    func toBSON() -> Data {
        return withUnsafeBytes(of: self) { Data($0) }
    }
}

extension String: PureBSONValue {
    internal static var bsonType: BSONType { return .string }

    internal var bson: BSON { return .string(self) }

    internal init(from data: inout Data) throws {
        self = try readString(from: &data)
    }

    /// Given utf8-encoded `Data`, reads from the start up to the first null byte and constructs a String from it.
    /// Mutates `cStringData` to remove the parsed data from the start.
    internal init(cStringData: inout Data) throws {
        guard cStringData.count >= 1 else {
            throw RuntimeError.internalError(message: "Expected to get at least 1 byte, got \(cStringData.count)")
        }
        let bytes = cStringData.prefix { $0 != 0 }
        guard bytes.count < cStringData.count else {
            throw RuntimeError.internalError(message: "cstring buffer missing null byte")
        }
        cStringData = cStringData[(cStringData.startIndex + bytes.count + 1)...]
        guard let str = String(bytes: bytes, encoding: .utf8) else {
            throw RuntimeError.internalError(message: "invalid UTF-8 data")
        }
        self = str
    }

    internal func toBSON() -> Data {
        var data = Data()
        let cStringData = self.toCStringData()
        data.append(Int32(cStringData.count).toBSON())
        data.append(cStringData)
        return data
    }

    internal func toCStringData() -> Data {
        var data = Data()
        data.append(contentsOf: self.utf8)
        data.append(0)
        return data
    }
}

extension Bool: PureBSONValue {
    internal static var bsonType: BSONType { return .boolean }

    internal var bson: BSON { return .bool(self) }

    internal init(from data: inout Data) throws {
        guard data.count >= 1 else {
            throw RuntimeError.internalError(message: "Expected to get at least 1 byte, got \(data.count)")
        }
        let byte = data.removeFirst()
        switch byte {
        case 0:
            self = false
        case 1:
            self = true
        default:
            throw InvalidBSONError("Unable to initialize Bool from byte \(byte)")
        }
    }

    internal func toBSON() -> Data {
        return self ? Data([1]) : Data([0])
    }
}

extension Double: PureBSONValue {
    internal static var bsonType: BSONType { return .double }

    internal var bson: BSON { return .double(self) }

    public init(from data: inout Data) throws {
        guard data.count >= 8 else {
            throw RuntimeError.internalError(message: "Expected to get at least 8 bytes, got \(data.count)")
        }
        var value = 0.0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0)
        }
        self = value
        data.removeFirst(8)
    }
}

extension Int: PureBSONValue {
    /// `Int` corresponds to a BSON int32 or int64 depending upon whether the compilation system is 32 or 64 bit.
    /// Use MemoryLayout instead of Int.bitWidth to avoid a compiler warning.
    /// See: https://forums.swift.org/t/how-can-i-condition-on-the-size-of-int/9080/4
    internal static var bsonType: BSONType { return MemoryLayout<Int>.size == 4 ? .int32 : .int64 }

    internal var bson: BSON { return Int.bsonType == .int32 ? .int32(Int32(self)) : .int64(Int64(self)) }
}

extension Int32: PureBSONValue {
    internal static var bsonType: BSONType { return .int32 }

    internal var bson: BSON { return .int32(self) }
}

extension Int64: PureBSONValue {
    internal static var bsonType: BSONType { return .int64 }

    internal var bson: BSON { return .int64(self) }
}

extension Date: PureBSONValue {
    internal static var bsonType: BSONType { return .dateTime }

    internal var bson: BSON { return .date(self) }

    internal init(from data: inout Data) throws {
        self.init(msSinceEpoch: try Int64(from: &data))
    }

    internal func toBSON() -> Data {
        return self.msSinceEpoch.toBSON()
    }
}

extension Array: PureBSONValue where Element == BSON {
    internal static var bsonType: BSONType { return .array }

    internal var bson: BSON { return .array(self) }

    internal init(from data: inout Data) throws {
        let doc = try PureBSONDocument(from: &data)

        var arr: [BSON] = []
        for (i, key) in doc.keys.enumerated() {
            guard String(i) == key else {
                throw RuntimeError.internalError(message: "invalid array document: \(doc)")
            }
            arr.append(doc[key]!)
        }

        self = arr
    }

    internal func toBSON() -> Data {
        if case let .array(arr) = self.bson {
            var doc = PureBSONDocument()
            for (i, element) in arr.enumerated() {
                doc[String(i)] = element
            }
            return doc.toBSON()
        }
        fatalError("can't reach here")
    }
}

/// Reads a `String` according to the "string" non-terminal of the BSON spec.
internal func readString(from data: inout Data) throws -> String {
    let length = Int(try Int32(from: &data))
    guard data.count >= length && data[data.startIndex + length - 1] == 0 else {
        throw RuntimeError.internalError(message: "invalid buffer")
    }

    let str = data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> String in
        String(cString: ptr)
    }

    data.removeFirst(str.utf8.count + 1)
    return str
}

/// Reads an integer type from the data. Throws if buffer is too small.
internal func readInteger<T: ExpressibleByIntegerLiteral>(from data: inout Data) throws -> T {
    let size = MemoryLayout<T>.size
    guard data.count >= size else {
        throw RuntimeError.internalError(message: "Buffer not large enough to read \(T.self) from")
    }
    var value: T = 0
    _ = withUnsafeMutableBytes(of: &value) {
        data.copyBytes(to: $0)
    }
    data.removeFirst(size)
    return value
}

internal struct InvalidBSONError: LocalizedError {
    internal let message: String

    internal init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        return self.message
    }
}