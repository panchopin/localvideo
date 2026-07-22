import Foundation

/// Audio stream description reported once by the demuxer (see rtsp_demux.h).
struct AudioStreamConfig {
    enum Format: Int {
        case none = 0     // no audio stream, or an unsupported codec
        case alaw = 1     // G.711 A-law
        case ulaw = 2     // G.711 mu-law
        case aac  = 3     // AAC
    }
    let format: Format
    let sampleRate: Int
    let channels: Int
    let asc: [UInt8]      // AAC AudioSpecificConfig (empty for G.711)

    /// Whether the recorder can currently mux this audio. G.711 is decoded to PCM
    /// and stored in a .mov; AAC passthrough isn't wired yet (Wyze cams are G.711).
    var isSupported: Bool { format == .alaw || format == .ulaw }

    static let none = AudioStreamConfig(format: .none, sampleRate: 0, channels: 0, asc: [])
}

/// G.711 → 16-bit linear PCM. One byte in, one sample out, via precomputed tables
/// (the standard ITU-T G.711 expansion). No encoder/decoder library needed.
enum G711 {
    static let alawTable: [Int16] = (0..<256).map { alawToLinear(UInt8($0)) }
    static let ulawTable: [Int16] = (0..<256).map { ulawToLinear(UInt8($0)) }

    /// Decode a buffer of G.711 bytes to little-endian 16-bit PCM samples.
    static func decode(_ data: Data, format: AudioStreamConfig.Format) -> Data {
        let table = format == .ulaw ? ulawTable : alawTable
        var out = Data(capacity: data.count * 2)
        for byte in data {
            let s = table[Int(byte)]
            out.append(UInt8(truncatingIfNeeded: s))          // low byte
            out.append(UInt8(truncatingIfNeeded: s >> 8))     // high byte
        }
        return out
    }

    private static func alawToLinear(_ aVal: UInt8) -> Int16 {
        let a = Int(aVal) ^ 0x55
        var t = (a & 0x0F) << 4
        let seg = (a & 0x70) >> 4
        switch seg {
        case 0: t += 8
        case 1: t += 0x108
        default: t += 0x108; t <<= (seg - 1)
        }
        return Int16(truncatingIfNeeded: (a & 0x80) != 0 ? t : -t)
    }

    private static func ulawToLinear(_ uVal: UInt8) -> Int16 {
        let u = Int(~uVal)
        var t = ((u & 0x0F) << 3) + 0x84
        t <<= (u & 0x70) >> 4
        return Int16(truncatingIfNeeded: (u & 0x80) != 0 ? (0x84 - t) : (t - 0x84))
    }
}
