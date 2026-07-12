import Foundation

enum WavFileWriter {
    static func write(audioClip: AudioClip, to url: URL) throws {
        guard !audioClip.samples.isEmpty else {
            throw InkfallError.missingAudio
        }

        let sampleRate = UInt32(audioClip.sampleRate)
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(channels * bytesPerSample)
        let blockAlign = channels * bytesPerSample
        let pcmData = audioClip.samples.flatMap { sample -> [UInt8] in
            let clamped = max(-1, min(1, sample))
            let intSample = Int16(clamped * Float(Int16.max))
            return [
                UInt8(truncatingIfNeeded: intSample),
                UInt8(truncatingIfNeeded: intSample >> 8)
            ]
        }

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + pcmData.count))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(pcmData.count))
        data.append(contentsOf: pcmData)

        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
