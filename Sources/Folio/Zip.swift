import Compression
import Foundation

/// A small ZIP reader and writer for EPUBs, used where there are no `zip` / `unzip` commands (iPad).
/// Reads stored and deflated entries, writes stored ones; no encryption, no ZIP64.
enum Zip {
    struct Failure: Error {}

    static func extract(_ archive: URL, to directory: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        // End-of-central-directory record: at the very end, after an optional comment.
        guard data.count >= 22 else { throw Failure() }
        var eocd = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while eocd >= floor, u32(eocd) != 0x0605_4b50 { eocd -= 1 }
        guard eocd >= floor else { throw Failure() }
        let count = u16(eocd + 10)
        var cursor = u32(eocd + 16)

        let fm = FileManager.default
        let base = directory.standardizedFileURL.path
        for _ in 0..<count {
            guard cursor + 46 <= data.count, u32(cursor) == 0x0201_4b50 else { throw Failure() }
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let packed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            let local = u32(cursor + 42)
            guard cursor + 46 + nameLength <= data.count else { throw Failure() }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            cursor += 46 + nameLength + extraLength + commentLength
            guard flags & 1 == 0, let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) else {
                throw Failure()
            }

            let target = directory.appendingPathComponent(name).standardizedFileURL
            // Never write outside the destination, whatever the archive says.
            guard target.path == base || target.path.hasPrefix(base + "/") else { continue }
            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            guard local + 30 <= data.count, u32(local) == 0x0403_4b50 else { throw Failure() }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + packed <= data.count else { throw Failure() }
            let body = data.subdata(in: start..<start + packed)
            switch method {
            case 0:
                try body.write(to: target)
            case 8:
                try inflate(body, size: size).write(to: target)
            default:
                throw Failure()
            }
        }
    }

    private static func inflate(_ body: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure() }
        return out
    }

    // MARK: Writing

    /// Packs files into an archive without compressing them, in the order given. Timestamps are fixed,
    /// so the same content always produces the same bytes (a book's id is a hash of its file).
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(), directory = Data()
        func put(_ value: Int, _ bytes: Int, into data: inout Data) {
            for shift in 0..<bytes { data.append(UInt8((value >> (8 * shift)) & 0xff)) }
        }
        for file in files {
            let name = Data(file.name.utf8), crc = Int(crc32(file.data)), offset = out.count
            // version 2.0, UTF-8 names, stored, 1 Jan 1980.
            var fields = Data()
            put(20, 2, into: &fields); put(0x0800, 2, into: &fields); put(0, 2, into: &fields)
            put(0, 2, into: &fields); put(0x0021, 2, into: &fields)
            put(crc, 4, into: &fields); put(file.data.count, 4, into: &fields); put(file.data.count, 4, into: &fields)
            put(name.count, 2, into: &fields); put(0, 2, into: &fields)

            put(0x0403_4b50, 4, into: &out)
            out.append(fields); out.append(name); out.append(file.data)

            put(0x0201_4b50, 4, into: &directory); put(20, 2, into: &directory)
            directory.append(fields)
            put(0, 2, into: &directory); put(0, 2, into: &directory); put(0, 2, into: &directory)
            put(0, 4, into: &directory); put(offset, 4, into: &directory)
            directory.append(name)
        }
        let start = out.count
        out.append(directory)
        put(0x0605_4b50, 4, into: &out); put(0, 2, into: &out); put(0, 2, into: &out)
        put(files.count, 2, into: &out); put(files.count, 2, into: &out)
        put(directory.count, 4, into: &out); put(start, 4, into: &out); put(0, 2, into: &out)
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        (0..<8).reduce(UInt32(i)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    }
}
