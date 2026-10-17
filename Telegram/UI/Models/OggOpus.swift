import Foundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Minimal Ogg/Opus container support for Telegram voice notes.
/// iOS can record and play Opus only inside CAF, while Telegram uses Ogg, so packets are re-wrapped
/// without re-encoding and without third-party libraries.
nonisolated enum OggOpus {

    /// Number of 48 kHz samples in an Opus packet (RFC 6716, section 3.1).
    static func packetSamples(_ packet: [UInt8]) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frameSamples: Int
        switch config {
        case 0...11: frameSamples = [480, 960, 1920, 2880][config % 4]
        case 12...15: frameSamples = [480, 960][config % 2]
        default: frameSamples = [120, 240, 480, 960][config % 4]
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[1] & 0x3F) : 0
        }
        return frameSamples * frames
    }

    // MARK: - Muxing

    static func mux(packets: [[UInt8]], channels: Int = 1, preSkip: Int = 0) -> Data {
        let serial = UInt32.random(in: 1...UInt32.max)
        var writer = PageWriter(serial: serial)

        var head = Array("OpusHead".utf8)
        head.append(1)
        head.append(UInt8(channels))
        head += le(UInt16(preSkip))
        head += le(UInt32(48_000))
        head += le(UInt16(0))
        head.append(0)
        writer.writePage(packets: [head], granule: 0, flags: 0x02)

        let vendor = Array("fignyagram".utf8)
        var tags = Array("OpusTags".utf8)
        tags += le(UInt32(vendor.count))
        tags += vendor
        tags += le(UInt32(0))
        writer.writePage(packets: [tags], granule: 0, flags: 0)

        var granule: Int64 = 0
        var pending: [[UInt8]] = []
        var pendingSegments = 0
        for (index, packet) in packets.enumerated() {
            let segments = packet.count / 255 + 1
            if pendingSegments + segments > 255 || pending.count >= 50 {
                writer.writePage(packets: pending, granule: granule, flags: 0)
                pending = []
                pendingSegments = 0
            }
            pending.append(packet)
            pendingSegments += segments
            granule += Int64(packetSamples(packet))
            if index == packets.count - 1 {
                writer.writePage(packets: pending, granule: granule, flags: 0x04)
            }
        }
        if packets.isEmpty {
            writer.writePage(packets: [], granule: 0, flags: 0x04)
        }
        return Data(writer.output)
    }

    private struct PageWriter {
        let serial: UInt32
        var sequence: UInt32 = 0
        var output: [UInt8] = []

        mutating func writePage(packets: [[UInt8]], granule: Int64, flags: UInt8) {
            var lacing: [UInt8] = []
            var body: [UInt8] = []
            for packet in packets {
                var remaining = packet.count
                while remaining >= 255 {
                    lacing.append(255)
                    remaining -= 255
                }
                lacing.append(UInt8(remaining))
                body += packet
            }
            var page = Array("OggS".utf8)
            page.append(0)
            page.append(flags)
            page += le(UInt64(bitPattern: granule))
            page += le(serial)
            page += le(sequence)
            page += [0, 0, 0, 0]
            page.append(UInt8(lacing.count))
            page += lacing
            page += body
            let crc = OggOpus.crc(page)
            page.replaceSubrange(22..<26, with: le(crc))
            output += page
            sequence += 1
        }
    }

    // MARK: - Demuxing

    struct Stream {
        var channels: Int
        var preSkip: Int
        var packets: [[UInt8]]
    }

    static func demux(_ data: Data) -> Stream? {
        let bytes = [UInt8](data)
        var offset = 0
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        while offset + 27 <= bytes.count {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67, bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else { return nil }
            let segmentCount = Int(bytes[offset + 26])
            let lacingStart = offset + 27
            guard lacingStart + segmentCount <= bytes.count else { break }
            var position = lacingStart + segmentCount
            for i in 0..<segmentCount {
                let length = Int(bytes[lacingStart + i])
                guard position + length <= bytes.count else { return nil }
                current += bytes[position..<position + length]
                position += length
                if length < 255 {
                    packets.append(current)
                    current = []
                }
            }
            offset = position
        }
        guard packets.count >= 2 else { return nil }
        let head = packets[0]
        guard head.count >= 19, Array(head[0..<8]) == Array("OpusHead".utf8) else { return nil }
        let channels = Int(head[9])
        let preSkip = Int(head[10]) | Int(head[11]) << 8
        return Stream(channels: max(channels, 1), preSkip: preSkip, packets: Array(packets.dropFirst(2)))
    }

    // MARK: - Helpers

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 {
            r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1
        }
        return r
    }

    static func crc(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            crc = (crc << 8) ^ crcTable[Int(((crc >> 24) & 0xFF) ^ UInt32(byte))]
        }
        return crc
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}

/// Telegram voice note waveform: 5-bit amplitudes packed into a little-endian bit stream.
nonisolated enum Waveform {

    static func pack(_ levels: [Float]) -> Data {
        let values = levels.map { UInt8(max(0, min(31, ($0 * 31).rounded()))) }
        var bytes = [UInt8](repeating: 0, count: (values.count * 5 + 7) / 8)
        for (i, value) in values.enumerated() {
            for bit in 0..<5 where value & (1 << bit) != 0 {
                let position = i * 5 + bit
                bytes[position / 8] |= 1 << UInt8(position % 8)
            }
        }
        return Data(bytes)
    }

    /// Returns amplitudes in 0...1.
    static func unpack(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        let count = bytes.count * 8 / 5
        return (0..<count).map { i in
            var value = 0
            for bit in 0..<5 {
                let position = i * 5 + bit
                if bytes[position / 8] & (1 << UInt8(position % 8)) != 0 { value |= 1 << bit }
            }
            return Float(value) / 31
        }
    }

    static func resample(_ samples: [Float], to count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        return (0..<count).map { i in
            let start = i * samples.count / count
            let end = max(start + 1, (i + 1) * samples.count / count)
            return samples[start..<min(end, samples.count)].max() ?? 0
        }
    }
}

#if canImport(AudioToolbox)
nonisolated extension OggOpus {

    enum ConversionError: Swift.Error {
        case invalidInput
        case audioFile(OSStatus)
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw ConversionError.audioFile(status) }
    }

    /// Re-wraps an Ogg/Opus file into CAF so AVAudioPlayer can play it.
    static func convertOggToCaf(_ source: URL, destination: URL) throws {
        guard let stream = demux(try Data(contentsOf: source)), !stream.packets.isEmpty else { throw ConversionError.invalidInput }
        let samples = stream.packets.map(packetSamples)
        let fixed = Set(samples).count == 1 ? UInt32(samples[0]) : 0
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: fixed, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(stream.channels),
            mBitsPerChannel: 0, mReserved: 0
        )
        var file: AudioFileID?
        try check(AudioFileCreateWithURL(destination as CFURL, kAudioFileCAFType, &format, .eraseFile, &file))
        guard let file else { throw ConversionError.invalidInput }
        defer { AudioFileClose(file) }

        var buffer: [UInt8] = []
        var descriptions: [AudioStreamPacketDescription] = []
        buffer.reserveCapacity(stream.packets.reduce(0) { $0 + $1.count })
        for (packet, count) in zip(stream.packets, samples) {
            descriptions.append(AudioStreamPacketDescription(
                mStartOffset: Int64(buffer.count),
                mVariableFramesInPacket: fixed == 0 ? UInt32(count) : 0,
                mDataByteSize: UInt32(packet.count)
            ))
            buffer += packet
        }
        var packetCount = UInt32(descriptions.count)
        try check(AudioFileWritePackets(file, false, UInt32(buffer.count), &descriptions, 0, &packetCount, &buffer))
    }

    /// Re-wraps a CAF/Opus recording into Ogg for sending. Returns the duration in seconds.
    @discardableResult
    static func convertCafToOgg(_ source: URL, destination: URL) throws -> Double {
        var file: AudioFileID?
        try check(AudioFileOpenURL(source as CFURL, .readPermission, 0, &file))
        guard let file else { throw ConversionError.invalidInput }
        defer { AudioFileClose(file) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format))
        guard format.mFormatID == kAudioFormatOpus else { throw ConversionError.invalidInput }

        var totalPackets: UInt64 = 0
        size = UInt32(MemoryLayout<UInt64>.size)
        try check(AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &totalPackets))
        var maxPacketSize: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioFileGetProperty(file, kAudioFilePropertyMaximumPacketSize, &size, &maxPacketSize))

        var packets: [[UInt8]] = []
        let chunk: UInt32 = 256
        var buffer = [UInt8](repeating: 0, count: Int(max(maxPacketSize, 1) * chunk))
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: Int(chunk))
        var start: Int64 = 0
        while start < Int64(totalPackets) {
            var bytes = UInt32(buffer.count)
            var count = chunk
            try check(AudioFileReadPacketData(file, false, &bytes, &descriptions, start, &count, &buffer))
            if count == 0 { break }
            for d in descriptions.prefix(Int(count)) {
                let begin = Int(d.mStartOffset)
                packets.append(Array(buffer[begin..<begin + Int(d.mDataByteSize)]))
            }
            start += Int64(count)
        }
        try mux(packets: packets, channels: Int(format.mChannelsPerFrame)).write(to: destination)
        return Double(packets.reduce(0) { $0 + packetSamples($1) }) / 48_000
    }
}
#endif
