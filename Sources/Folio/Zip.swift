import Compression
import Foundation

/// A small ZIP extractor for EPUBs, used where there is no `unzip` command (iPad).
/// Handles stored and deflated entries; no encryption, no ZIP64.
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
}
