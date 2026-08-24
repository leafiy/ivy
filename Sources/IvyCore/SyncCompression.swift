import Foundation
#if canImport(Compression)
import Compression
#endif

/// Shrinks database snapshots in transit. Apple's `COMPRESSION_ZLIB` emits a
/// headerless raw-deflate stream, which the API inflates with zlib's
/// `inflateRawSync`. On platforms without the Compression framework snapshots
/// travel uncompressed; the API accepts both.
public enum SyncCompression {
    /// The `contentEncoding` form value the API expects for compressed uploads.
    public static let encodingName = "deflate"

    /// Returns the raw-deflate encoding of `data`, or nil when compression is
    /// unavailable or would not make the payload smaller.
    public static func deflate(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }
        var destination = Data(count: data.count)
        let compressedCount = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                compression_encode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    destinationBuffer.count,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    sourceBuffer.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        // Zero means failure or output >= the buffer, i.e. incompressible.
        guard compressedCount > 0, compressedCount < data.count else { return nil }
        destination.removeSubrange(compressedCount...)
        return destination
        #else
        return nil
        #endif
    }
}
