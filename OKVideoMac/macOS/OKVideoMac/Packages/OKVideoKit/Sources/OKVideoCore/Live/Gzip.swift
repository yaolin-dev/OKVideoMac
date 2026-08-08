import Foundation
import CZlib

public enum Gzip {
    public static func isCompressed(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    public static func decompress(_ data: Data, maximumOutputBytes: Int = 64 * 1_024 * 1_024) throws -> Data {
        guard isCompressed(data) else { return data }
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let initialization = inflateInit2_(
            &stream,
            16 + MAX_WBITS,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initialization == Z_OK else {
            throw AppError.live("无法初始化 gzip 解压器（\(initialization)）")
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1_024
        var output = Data()
        var status: Int32 = Z_OK

        try data.withUnsafeBytes { rawInput in
            guard let inputBase = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                throw AppError.live("gzip 输入为空")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            repeat {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let produced = buffer.withUnsafeMutableBytes { rawOutput -> Int in
                    stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: buffer.prefix(produced))
                }
                guard output.count <= maximumOutputBytes else {
                    throw AppError.live("gzip 解压结果超过 \(maximumOutputBytes) 字节限制")
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    let message = stream.msg.map { String(cString: $0) } ?? "zlib 状态 \(status)"
                    throw AppError.live("gzip 解压失败：\(message)")
                }
            } while status != Z_STREAM_END
        }

        return output
    }
}

