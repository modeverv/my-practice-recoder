import AVFoundation
import PracticeRecorderCore

public struct ExtractedAudio {
    public let sampleBuffer: CMSampleBuffer
    public let meter: AudioMeter
}

/// Copies only the two selected input channels to owned, interleaved Float32 stereo PCM.
/// Supports packed little/big-endian Float32/64 and signed Int16/24/32 linear PCM.
public enum PCMExtractor {
    /// AVFoundation may switch a native PCM stream between packed interleaved and
    /// non-interleaved buffers during startup. Both encode the same signal. Every
    /// buffer is still decoded from its own ASBD; actual rate/channel/sample-type
    /// changes remain an interruption.
    static func hasSameSignalFormat(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        guard lhs.mSampleRate == rhs.mSampleRate,
              lhs.mFormatID == kAudioFormatLinearPCM, rhs.mFormatID == kAudioFormatLinearPCM,
              lhs.mChannelsPerFrame == rhs.mChannelsPerFrame,
              lhs.mBitsPerChannel == rhs.mBitsPerChannel,
              lhs.mFramesPerPacket == rhs.mFramesPerPacket,
              lhs.mFormatFlags & ~kAudioFormatFlagIsNonInterleaved == rhs.mFormatFlags & ~kAudioFormatFlagIsNonInterleaved else { return false }
        func validPackedLayout(_ asbd: AudioStreamBasicDescription) -> Bool {
            guard asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  asbd.mBitsPerChannel > 0, asbd.mBitsPerChannel % 8 == 0 else { return false }
            let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let expectedFrame = asbd.mBitsPerChannel / 8 * (planar ? 1 : asbd.mChannelsPerFrame)
            return asbd.mBytesPerFrame == expectedFrame &&
                   asbd.mBytesPerPacket == expectedFrame * asbd.mFramesPerPacket
        }
        return validPackedLayout(lhs) && validPackedLayout(rhs)
    }
    public static func extract(_ sample: CMSampleBuffer, left: Int, right: Int) throws -> ExtractedAudio {
        guard CMSampleBufferDataIsReady(sample), let description = CMSampleBufferGetFormatDescription(sample),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw RecorderError("音声サンプルの形式がありません。")
        }
        let asbd = asbdPointer.pointee
        let count = CMSampleBufferGetNumSamples(sample)
        let channels = Int(asbd.mChannelsPerFrame)
        guard left >= 0, right >= 0, left < channels, right < channels else {
            throw RecorderError("L/R入力番号が範囲外です（取得入力数: \(channels)）。")
        }
        guard asbd.mSampleRate == 44_100 || asbd.mSampleRate == 48_000 else {
            throw RecorderError("入力\(asbd.mSampleRate) Hzは未対応です。デバイス設定は変更していません。44.1/48 kHzを使用してください。")
        }
        let flags = asbd.mFormatFlags
        let floating = flags & kAudioFormatFlagIsFloat != 0
        let signed = flags & kAudioFormatFlagIsSignedInteger != 0
        let packed = flags & kAudioFormatFlagIsPacked != 0
        let bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(asbd.mBitsPerChannel)
        let width = bits / 8
        let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
        guard asbd.mFormatID == kAudioFormatLinearPCM, packed,
              (floating && [32,64].contains(bits)) || (!floating && signed && [16,24,32].contains(bits)),
              asbd.mBytesPerFrame == UInt32(width * (planar ? 1 : channels)), count > 0 else {
            throw RecorderError("未対応のPCM形式です: \(asbd)。packed Float32/64またはsigned Int16/24/32が必要です。")
        }
        var needed = 0
        var retainedBlock: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, needed >= MemoryLayout<AudioBufferList>.size else { throw RecorderError("音声バッファ構造を取得できません (\(status))。") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retainedBlock)
        guard status == noErr else { throw RecorderError("音声バッファを読み出せません (\(status))。") }
        // GetAudioBufferList can coalesce discontiguous data into this retained block.
        // Keep that owner alive until all borrowed AudioBuffer pointers have been copied.
        defer { withExtendedLifetime(retainedBlock) {} }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var starts: [(buffer: AudioBuffer, first: Int)] = []
        var channelStart = 0
        for buffer in buffers {
            let n = Int(buffer.mNumberChannels)
            guard n > 0, buffer.mData != nil, Int(buffer.mDataByteSize) >= count * n * width else { throw RecorderError("音声バッファの長さが不足しています。") }
            starts.append((buffer, channelStart)); channelStart += n
        }
        guard channelStart == channels else { throw RecorderError("ASBDとバッファのチャンネル数が一致しません。") }
        func value(frame: Int, channel: Int) throws -> Float {
            guard let group = starts.first(where: { channel >= $0.first && channel < $0.first + Int($0.buffer.mNumberChannels) }), let data = group.buffer.mData else { throw RecorderError("入力チャンネルを特定できません。") }
            let offset = (frame * Int(group.buffer.mNumberChannels) + channel - group.first) * width
            let p = data.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            var raw: UInt64 = 0
            for b in 0..<width { raw |= UInt64(p[b]) << ((bigEndian ? width - 1 - b : b) * 8) }
            if floating {
                let v = bits == 32 ? Float(bitPattern: UInt32(raw)) : Float(Double(bitPattern: raw))
                guard v.isFinite else { throw RecorderError("音声入力に非有限PCM値があります。") }
                return v
            }
            let signBit = UInt64(1) << (bits - 1)
            let signedValue = raw & signBit == 0 ? Int64(raw) : Int64(raw) - (Int64(1) << bits)
            return Float(Double(signedValue) / Double(Int64(1) << (bits - 1)))
        }
        var stereo = [Float](repeating: 0, count: count * 2)
        var peakL: Float = 0, peakR: Float = 0
        for frame in 0..<count {
            let l = try value(frame: frame, channel: left), r = try value(frame: frame, channel: right)
            stereo[frame*2] = l; stereo[frame*2+1] = r
            peakL = max(peakL, abs(l)); peakR = max(peakR, abs(r))
        }
        let result = try makeStereo(samples: stereo, sampleRate: asbd.mSampleRate, pts: CMSampleBufferGetPresentationTimeStamp(sample))
        return ExtractedAudio(sampleBuffer: result, meter: AudioMeter(left: peakL, right: peakR))
    }

    /// Utility shared by synthetic tests; the returned sample owns its bytes.
    public static func makeStereo(samples: [Float], sampleRate: Double, pts: CMTime) throws -> CMSampleBuffer {
        guard !samples.isEmpty, samples.count % 2 == 0 else { throw RecorderError("ステレオPCMのサンプル数が不正です。") }
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw RecorderError("ステレオ形式の生成に失敗 (\(status))。") }
        var block: CMBlockBuffer?
        let bytes = samples.count * MemoryLayout<Float>.size
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw RecorderError("PCMメモリ確保に失敗 (\(status))。") }
        status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard status == noErr else { throw RecorderError("PCMコピーに失敗 (\(status))。") }
        var output: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: samples.count / 2, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &output)
        guard status == noErr, let output else { throw RecorderError("音声サンプル生成に失敗 (\(status))。") }
        return output
    }
}
