import Foundation

/// Systematic Reed-Solomon erasure code over GF(2^8), wire-compatible with the code NVIDIA's
/// video pipeline uses for NVST FEC.
///
/// Compatibility is the entire point, so the conventions are pinned to the implementation the
/// Moonlight project has decoded GameStream/GFN FEC with for years (nanors):
///
/// - Field: GF(2^8) with polynomial 285 (0x11D), generator 2.
/// - Generator matrix: systematic, with the parity rows forming the Cauchy matrix
///   `parity[j][i] = inverse((ps + i) XOR j)` for data shard `i` and parity shard `j`.
///
/// A shard is one whole plaintext RTP packet (header included), zero-padded to the block's
/// uniform size — that is what the seat computes parity over, which is why recovering a shard
/// yields a complete packet, GS header and all.
public enum NvstReedSolomon {
    /// GF(2^8) shard-count ceiling: `(ps + i) XOR j` must stay a field element.
    public static let maximumShards = 255

    // MARK: - GF(2^8) tables (polynomial 0x11D, generator 2)

    /// exp table doubled so `exp[log a + log b]` needs no modulo.
    private static let tables: (exp: [UInt8], log: [UInt8], inv: [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [UInt8](repeating: 0, count: 256)
        var x = 1
        for power in 0..<255 {
            exp[power] = UInt8(x)
            log[x] = UInt8(power)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for power in 255..<512 { exp[power] = exp[power - 255] }
        var inv = [UInt8](repeating: 0, count: 256)
        for value in 1..<256 { inv[value] = exp[255 - Int(log[value])] }
        return (exp, log, inv)
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return tables.exp[Int(tables.log[Int(a)]) + Int(tables.log[Int(b)])]
    }

    static func inverse(_ a: UInt8) -> UInt8 { tables.inv[Int(a)] }

    /// destination ^= coefficient * source, element-wise, through raw buffers: the inner loop
    /// runs the length of a shard, and dropping the per-index bounds checks is a measurable win
    /// on exactly the path that runs when the network is already stressed.
    private static func addScaled(_ destination: inout [UInt8], _ source: [UInt8], by coefficient: UInt8) {
        guard coefficient != 0 else { return }
        let length = min(destination.count, source.count)
        guard length > 0 else { return }
        if coefficient == 1 {
            destination.withUnsafeMutableBufferPointer { dst in
                source.withUnsafeBufferPointer { src in
                    for index in 0..<length { dst[index] ^= src[index] }
                }
            }
            return
        }
        let logC = Int(tables.log[Int(coefficient)])
        let exp = tables.exp
        let log = tables.log
        destination.withUnsafeMutableBufferPointer { dst in
            source.withUnsafeBufferPointer { src in
                for index in 0..<length {
                    let value = src[index]
                    if value != 0 { dst[index] ^= exp[logC + Int(log[Int(value)])] }
                }
            }
        }
    }

    /// One parity-matrix coefficient: the contribution of data shard `dataIndex` to parity shard
    /// `parityIndex`, given `parityCount` total parity shards.
    static func parityCoefficient(parityCount: Int, dataIndex: Int, parityIndex: Int) -> UInt8 {
        inverse(UInt8((parityCount + dataIndex) ^ parityIndex))
    }

    // MARK: - Encode

    /// Computes the parity shards for `data`. Every shard must be `size` bytes.
    public static func encode(data: [[UInt8]], parityCount: Int, size: Int) -> [[UInt8]]? {
        let dataCount = data.count
        guard dataCount > 0, parityCount > 0, dataCount + parityCount <= maximumShards,
              data.allSatisfy({ $0.count == size }) else { return nil }
        var parity: [[UInt8]] = []
        parity.reserveCapacity(parityCount)
        for parityIndex in 0..<parityCount {
            var row = [UInt8](repeating: 0, count: size)
            for dataIndex in 0..<dataCount {
                addScaled(&row, data[dataIndex],
                          by: parityCoefficient(parityCount: parityCount, dataIndex: dataIndex, parityIndex: parityIndex))
            }
            parity.append(row)
        }
        return parity
    }

    // MARK: - Decode

    /// Recovers the missing data shards of one block.
    ///
    /// `shards` holds `dataCount + parityCount` slots in shard order (data first), `nil` where the
    /// shard never arrived. Every present shard must be `size` bytes. Returns the recovered data
    /// shards keyed by data index, or nil when too few shards survive.
    ///
    /// The array is `inout` so consumed shards are moved out rather than copied: Gauss-Jordan
    /// mutates every shard it touches, and a shard still referenced by the caller's array would
    /// copy-on-write on each mutation. Consumed slots are left `nil`.
    public static func recover(shards: inout [[UInt8]?], dataCount: Int, parityCount: Int, size: Int) -> [Int: [UInt8]]? {
        guard dataCount > 0, parityCount > 0, dataCount + parityCount <= maximumShards,
              shards.count == dataCount + parityCount else { return nil }
        let missingData = (0..<dataCount).filter { shards[$0] == nil }
        guard !missingData.isEmpty else { return [:] }

        // One equation per surviving shard: a present data shard pins its own value, a present
        // parity shard contributes its Cauchy row. `dataCount` independent equations solve the
        // block.
        var rows: [[UInt8]] = []
        var values: [[UInt8]] = []
        for dataIndex in 0..<dataCount {
            guard let shard = shards[dataIndex], shard.count == size else { continue }
            shards[dataIndex] = nil
            var row = [UInt8](repeating: 0, count: dataCount)
            row[dataIndex] = 1
            rows.append(row)
            values.append(shard)
        }
        for parityIndex in 0..<parityCount where rows.count < dataCount {
            guard let shard = shards[dataCount + parityIndex], shard.count == size else { continue }
            shards[dataCount + parityIndex] = nil
            var row = [UInt8](repeating: 0, count: dataCount)
            for dataIndex in 0..<dataCount {
                row[dataIndex] = parityCoefficient(parityCount: parityCount, dataIndex: dataIndex, parityIndex: parityIndex)
            }
            rows.append(row)
            values.append(shard)
        }
        guard rows.count == dataCount else { return nil }

        // Gauss-Jordan over GF(2^8), applying every row operation to the shard payloads too.
        for column in 0..<dataCount {
            guard let pivot = (column..<dataCount).first(where: { rows[$0][column] != 0 }) else { return nil }
            if pivot != column {
                rows.swapAt(pivot, column)
                values.swapAt(pivot, column)
            }
            let scale = inverse(rows[column][column])
            if scale != 1 {
                for index in 0..<dataCount { rows[column][index] = multiply(rows[column][index], scale) }
                var scaled = [UInt8](repeating: 0, count: size)
                addScaled(&scaled, values[column], by: scale)
                values[column] = scaled
            }
            for other in 0..<dataCount where other != column {
                let factor = rows[other][column]
                guard factor != 0 else { continue }
                for index in 0..<dataCount {
                    rows[other][index] ^= multiply(rows[column][index], factor)
                }
                let source = values[column]
                addScaled(&values[other], source, by: factor)
            }
        }

        var recovered: [Int: [UInt8]] = [:]
        for index in missingData { recovered[index] = values[index] }
        return recovered
    }
}
