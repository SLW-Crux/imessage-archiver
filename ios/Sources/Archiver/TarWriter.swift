#if os(macOS)
import Foundation

/// Append-mode POSIX ustar tar writer for `attachments.tar`.
///
/// Mirrors `TarReader` byte-for-byte. Each `append()` writes one file
/// entry (header + data + zero-padding) and returns `(offset, length)`:
///   - `offset` = the byte position of the first file-data byte
///                (header_start + 512 for short names; computed from
///                end-of-write for PAX-extended-header names).
///   - `length` = the raw file size (NOT padded).
///
/// The iOS reader does `seek(offset); read(length)` — the offset MUST
/// point at the data byte, never at a header byte.
///
/// Port of `src/imessage_archiver/core/tar_writer.py`.
final class TarWriter {

    /// POSIX ustar block size — every record is a multiple of this.
    static let blockSize: Int = 512

    private let url: URL
    private let handle: FileHandle

    /// Open `path` for append. If it doesn't exist, create it. If it
    /// does, position before the trailing end-of-archive blocks so the
    /// next entry overwrites them — same behaviour as Python's
    /// `tarfile.open(..., 'a:')`.
    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forUpdating: url)
        try seekBeforeEndOfArchive()
    }

    /// Append `sourceURL`'s bytes as one tar entry. Returns
    /// `(tarOffset, tarLength)`.
    func append(
        attachmentGUID: String,
        sourceURL: URL,
        filename: String?
    ) throws -> (offset: Int64, length: Int64) {
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let size = attrs[.size] as? NSNumber else {
            throw TarWriteError.sizeUnreadable(sourceURL)
        }
        let fileSize = size.int64Value
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        let entryName = Self.entryName(attachmentGUID: attachmentGUID, filename: filename)

        // Tar headers are limited to 100-byte names. For longer names,
        // Python's tarfile writes a PAX extended header before the
        // real entry — we replicate that so the file format stays
        // compatible. The exact PAX format isn't documented here; we
        // emit it only when needed.
        let usePAX = entryName.utf8.count > 100

        if usePAX {
            try writePAXExtendedHeader(name: entryName)
        }
        // When the name needs to be shortened for the ustar header
        // (PAX entry carries the full path), shorten on UTF-8 byte
        // boundary, not on Swift Character index — `prefix(100)` is
        // 100 graphemes, which can be hundreds of bytes; and slicing
        // a UTF-8 byte view mid-codepoint produces invalid bytes
        // that some tar readers reject (review finding MH7). We fall
        // back to the attachment GUID prefix when the name has no
        // pure-ASCII prefix to safely embed.
        let nameForHeader = usePAX
            ? Self.shortenForUstarHeader(entryName, guidPrefix: attachmentGUID)
            : entryName
        try writeUstarHeader(
            name: nameForHeader,
            size: fileSize,
            mtime: mtime
        )
        try copyFileBytes(from: sourceURL, length: fileSize)
        try padToBlockBoundary()
        try handle.synchronize()

        let endOffset = try handle.offset()  // UInt64 from FileHandle
        let padded = ((fileSize + Int64(Self.blockSize - 1)) / Int64(Self.blockSize)) * Int64(Self.blockSize)
        // FileHandle returns UInt64 offsets; the tar protocol values
        // we expose are Int64 (matches archive.sqlite schema). Convert
        // explicitly — offsets can't exceed Int64.max on any realistic
        // tar (>9 EiB).
        let tarOffset = Int64(endOffset) - padded
        return (tarOffset, fileSize)
    }

    func close() throws {
        try writeEndOfArchive()
        try handle.synchronize()
        try handle.close()
    }

    // MARK: - Naming

    /// Build a tar entry name ≤ 80 visible chars (we cap aggressively
    /// to leave room for the GUID prefix + the separator).
    static func entryName(attachmentGUID: String, filename: String?) -> String {
        let guidPrefix = String(attachmentGUID.prefix(36))
        guard let raw = filename, !raw.isEmpty else {
            return guidPrefix
        }
        let basename = (raw as NSString).lastPathComponent
        // Strip leading dots — POSIX hidden-file convention is unsafe
        // when we're embedding paths inside a bundle the user may extract.
        let cleaned = basename.drop(while: { $0 == "." })
        let trimmed = String(cleaned.prefix(80))
        let safe = trimmed.isEmpty ? "file" : trimmed
        return "\(guidPrefix)-\(safe)"
    }

    /// Shorten `entryName` for embedding in the 100-byte ustar header
    /// field WITHOUT producing invalid UTF-8 (MH7). When the entire
    /// name fits in ≤100 bytes we use it as-is. Otherwise we fall back
    /// to the 36-char attachment GUID prefix — it's pure ASCII so the
    /// byte/character math is trivial, and the PAX-extended `path`
    /// record written before this header carries the authoritative
    /// full name for readers that honour PAX.
    static func shortenForUstarHeader(
        _ entryName: String,
        guidPrefix attachmentGUID: String
    ) -> String {
        if entryName.utf8.count <= 100 {
            return entryName
        }
        let guidPrefix = String(attachmentGUID.prefix(36))
        precondition(guidPrefix.utf8.count <= 100, "GUID prefix must fit in ustar name field")
        return guidPrefix
    }

    // MARK: - Header writing

    private func writeUstarHeader(name: String, size: Int64, mtime: Date) throws {
        var header = [UInt8](repeating: 0, count: Self.blockSize)

        // name: 100 bytes
        Self.writeAsciiZ(&header, value: name, offset: 0, length: 100)
        // mode: 8 bytes ("0000644\0")
        Self.writeOctal(&header, value: 0o644, offset: 100, length: 8)
        // uid: 8 bytes
        Self.writeOctal(&header, value: 0, offset: 108, length: 8)
        // gid: 8 bytes
        Self.writeOctal(&header, value: 0, offset: 116, length: 8)
        // size: 12 bytes
        Self.writeOctal(&header, value: size, offset: 124, length: 12)
        // mtime: 12 bytes (unix epoch)
        Self.writeOctal(
            &header,
            value: Int64(mtime.timeIntervalSince1970),
            offset: 136,
            length: 12
        )
        // chksum placeholder: 8 bytes filled with spaces
        for i in 148..<156 { header[i] = 0x20 }
        // typeflag: '0' = regular file
        header[156] = 0x30
        // linkname: 100 bytes (blank)
        // ustar magic + version
        let magic: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72, 0x00]  // "ustar\0"
        for (i, b) in magic.enumerated() { header[257 + i] = b }
        header[263] = 0x30  // version "0"
        header[264] = 0x30  // version "0"
        // uname / gname / devmajor / devminor / prefix: leave blank

        // Compute checksum: sum of all bytes treating chksum field as spaces.
        var checksum: Int = 0
        for b in header { checksum &+= Int(b) }
        Self.writeOctal(
            &header,
            value: Int64(checksum),
            offset: 148,
            length: 7,
            padNul: true
        )
        header[155] = 0x20  // single trailing space per POSIX

        try handle.write(contentsOf: Data(header))
    }

    /// Emit a PAX extended-header record. The header carries a long
    /// "path=<full name>" key/value so readers that ignore PAX can
    /// still parse the truncated ustar header that follows.
    private func writePAXExtendedHeader(name: String) throws {
        let payload = Self.paxRecord(key: "path", value: name)
        // ustar header for the PAX block
        var hdr = [UInt8](repeating: 0, count: Self.blockSize)
        Self.writeAsciiZ(&hdr, value: "PaxHeader", offset: 0, length: 100)
        Self.writeOctal(&hdr, value: 0o644, offset: 100, length: 8)
        Self.writeOctal(&hdr, value: 0, offset: 108, length: 8)
        Self.writeOctal(&hdr, value: 0, offset: 116, length: 8)
        Self.writeOctal(&hdr, value: Int64(payload.count), offset: 124, length: 12)
        Self.writeOctal(&hdr, value: 0, offset: 136, length: 12)
        for i in 148..<156 { hdr[i] = 0x20 }
        hdr[156] = 0x78  // typeflag 'x' = PAX extended header
        let magic: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72, 0x00]
        for (i, b) in magic.enumerated() { hdr[257 + i] = b }
        hdr[263] = 0x30
        hdr[264] = 0x30
        var sum = 0
        for b in hdr { sum &+= Int(b) }
        Self.writeOctal(&hdr, value: Int64(sum), offset: 148, length: 7, padNul: true)
        hdr[155] = 0x20
        try handle.write(contentsOf: Data(hdr))
        try handle.write(contentsOf: payload)
        // Pad PAX payload to 512-block boundary
        let pad = (Self.blockSize - (payload.count % Self.blockSize)) % Self.blockSize
        if pad > 0 {
            try handle.write(contentsOf: Data(repeating: 0, count: pad))
        }
    }

    private static func paxRecord(key: String, value: String) -> Data {
        // PAX records: "<length> <key>=<value>\n" where <length> is the
        // total length of the record INCLUDING the length field itself.
        // The length is self-referential so we have to iterate.
        let kv = "\(key)=\(value)\n"
        var length = kv.utf8.count + 3  // " " + "\n" + minimum 1-digit length
        while true {
            let candidate = "\(length) \(kv)"
            if candidate.utf8.count == length {
                return Data(candidate.utf8)
            }
            length += 1
        }
    }

    // MARK: - Data copy

    private func copyFileBytes(from sourceURL: URL, length: Int64) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let chunkSize = 1 * 1024 * 1024
        var remaining = length
        while remaining > 0 {
            let toRead = Int(Swift.min(Int64(chunkSize), remaining))
            guard let chunk = try input.read(upToCount: toRead), !chunk.isEmpty else {
                throw TarWriteError.unexpectedEOF(sourceURL)
            }
            try handle.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
    }

    private func padToBlockBoundary() throws {
        let pos = try handle.offset()  // UInt64
        let pad = Int(pos % UInt64(Self.blockSize))
        if pad > 0 {
            let bytes = Self.blockSize - pad
            try handle.write(contentsOf: Data(repeating: 0, count: bytes))
        }
    }

    private func writeEndOfArchive() throws {
        // POSIX requires two consecutive zero blocks as EoA.
        try handle.write(contentsOf: Data(repeating: 0, count: Self.blockSize * 2))
    }

    private func seekBeforeEndOfArchive() throws {
        let size = try handle.seekToEnd()
        // If the file already has at least two trailing zero blocks,
        // step back over them so the next append overwrites them. This
        // matches what Python's tarfile a: mode does internally.
        let probe = Int64(Self.blockSize * 2)
        if Int64(size) >= probe {
            try handle.seek(toOffset: size - UInt64(probe))
            let trailing = try handle.read(upToCount: Int(probe))
            if let trailing, trailing.allSatisfy({ $0 == 0 }) {
                try handle.seek(toOffset: size - UInt64(probe))
                return
            }
        }
        try handle.seek(toOffset: size)
    }

    // MARK: - Field writers

    private static func writeAsciiZ(
        _ buffer: inout [UInt8], value: String, offset: Int, length: Int
    ) {
        let bytes = Array(value.utf8.prefix(length - 1))
        for (i, b) in bytes.enumerated() { buffer[offset + i] = b }
        // remainder stays zero
    }

    /// Write `value` as a NUL-terminated octal ASCII string into the
    /// given field. POSIX ustar uses 6/7 octal digits depending on the
    /// field; we leave the final byte as NUL (or space, per `padNul`)
    /// because the format expects it.
    private static func writeOctal(
        _ buffer: inout [UInt8],
        value: Int64,
        offset: Int,
        length: Int,
        padNul: Bool = false
    ) {
        var str = String(value, radix: 8)
        // Left-pad with zeroes so the field is fully populated.
        while str.count < length - 1 { str = "0" + str }
        let bytes = Array(str.utf8)
        for (i, b) in bytes.enumerated() {
            buffer[offset + i] = b
        }
        if padNul {
            buffer[offset + length - 1] = 0
        } else {
            buffer[offset + length - 1] = 0  // NUL terminator
        }
    }
}

enum TarWriteError: Error, LocalizedError {
    case sizeUnreadable(URL)
    case unexpectedEOF(URL)

    var errorDescription: String? {
        switch self {
        case .sizeUnreadable(let url):
            return "Couldn't determine size of \(url.path)"
        case .unexpectedEOF(let url):
            return "Unexpected EOF reading \(url.path) into tar"
        }
    }
}

#endif
