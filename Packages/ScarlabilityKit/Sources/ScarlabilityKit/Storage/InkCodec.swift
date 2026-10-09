import Foundation

/// Everything one device has written on one page: the strokes it drew, plus the IDs of strokes from
/// *other* devices that it erased. Each device only ever writes its own file, so iCloud Drive never
/// has two devices editing the same file.
public struct DeviceInk: Equatable, Sendable {
    public var strokes: [Stroke]
    public var erasedStrokeIDs: Set<UUID>

    public init(strokes: [Stroke] = [], erasedStrokeIDs: Set<UUID> = []) {
        self.strokes = strokes
        self.erasedStrokeIDs = erasedStrokeIDs
    }
}

/// Binary `.ink` file format: a small header, then an LZFSE-compressed body.
///
///     "SCIK" | version: UInt16 | compressed body
///     body = strokeCount: UInt32, strokes…, erasedCount: UInt32, erased UUIDs…
///     stroke = id: 16 bytes | tool: UInt8 | color: RGBA 4 bytes | createdAt: Float64
///              | pointCount: UInt32 | points: (x, y, width) as Float32 each
///
/// All numbers are little-endian.
public enum InkCodec {
    static let magic = Data("SCIK".utf8)
    static let version: UInt16 = 1

    public enum DecodeError: Error, Equatable {
        case notAnInkFile
        case unsupportedVersion(UInt16)
        case corrupted
    }

    public static func encode(_ ink: DeviceInk) throws -> Data {
        var body = BinaryWriter()
        body.write(UInt32(ink.strokes.count))
        for stroke in ink.strokes {
            body.write(stroke.id)
            body.write(stroke.tool.rawValue)
            body.write([stroke.color.red, stroke.color.green, stroke.color.blue, stroke.color.alpha])
            body.write(stroke.createdAt.timeIntervalSinceReferenceDate)
            body.write(UInt32(stroke.points.count))
            for point in stroke.points {
                body.write(point.x)
                body.write(point.y)
                body.write(point.width)
            }
        }
        body.write(UInt32(ink.erasedStrokeIDs.count))
        // Sorted so the same ink always produces the same bytes.
        for id in ink.erasedStrokeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            body.write(id)
        }

        var file = BinaryWriter()
        file.data.append(magic)
        file.write(version)
        file.data.append(try (body.data as NSData).compressed(using: .lzfse) as Data)
        return file.data
    }

    public static func decode(_ data: Data) throws -> DeviceInk {
        guard data.count >= magic.count + 2, data.prefix(magic.count) == magic else {
            throw DecodeError.notAnInkFile
        }
        var header = BinaryReader(data.dropFirst(magic.count))
        let fileVersion: UInt16 = try header.read()
        guard fileVersion == version else { throw DecodeError.unsupportedVersion(fileVersion) }

        let compressed = data.dropFirst(magic.count + 2)
        let body: Data
        do {
            body = try (Data(compressed) as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw DecodeError.corrupted
        }

        var reader = BinaryReader(body)
        let strokeCount: UInt32 = try reader.read()
        var strokes: [Stroke] = []
        strokes.reserveCapacity(Int(strokeCount))
        for _ in 0..<strokeCount {
            let id: UUID = try reader.read()
            let toolRaw: UInt8 = try reader.read()
            guard let tool = InkTool(rawValue: toolRaw) else { throw DecodeError.corrupted }
            let rgba = try reader.readBytes(4)
            let createdAt: Double = try reader.read()
            let pointCount: UInt32 = try reader.read()
            var points: [InkPoint] = []
            points.reserveCapacity(Int(pointCount))
            for _ in 0..<pointCount {
                points.append(InkPoint(x: try reader.read(), y: try reader.read(), width: try reader.read()))
            }
            strokes.append(Stroke(
                id: id,
                tool: tool,
                color: InkColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]),
                points: points,
                createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
            ))
        }
        let erasedCount: UInt32 = try reader.read()
        var erased = Set<UUID>()
        for _ in 0..<erasedCount {
            erased.insert(try reader.read())
        }
        return DeviceInk(strokes: strokes, erasedStrokeIDs: erased)
    }
}

private struct BinaryWriter {
    var data = Data()

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Float) { write(value.bitPattern) }
    mutating func write(_ value: Double) { write(value.bitPattern) }
    mutating func write(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }

    mutating func write(_ id: UUID) {
        withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
    }
}

private struct BinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.endIndex else { throw InkCodec.DecodeError.corrupted }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        let bytes = try readBytes(MemoryLayout<T>.size)
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        return T(littleEndian: value)
    }

    mutating func read() throws -> Float { Float(bitPattern: try read()) }
    mutating func read() throws -> Double { Double(bitPattern: try read()) }

    mutating func read() throws -> UUID {
        let bytes = try readBytes(16)
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
