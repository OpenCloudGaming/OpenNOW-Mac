import AudioToolbox
import CoreAudio
import Foundation

/// Places decoded channels on the speakers a device reports. A speaker the device lacks is folded
/// into the front pair at -3 dB, LFE is dropped, and the whole matrix is scaled down when a fold
/// could otherwise clip.
public struct NvstSpeakerMatrix: Equatable, Sendable {
    public let source: [AudioChannelLabel]
    public let destination: [AudioChannelLabel]
    /// One row per destination channel, one column per source channel.
    let gains: [Float]

    private static let foldGain: Float = 0.70710677
    private static let left = kAudioChannelLabel_Left
    private static let right = kAudioChannelLabel_Right

    public init(from source: [AudioChannelLabel], to destination: [AudioChannelLabel]) {
        self.source = source
        self.destination = destination
        guard destination.count == 1 else {
            gains = Self.normalized(Self.placement(of: source, on: destination), rows: destination.count)
            return
        }
        let stereo = Self.normalized(Self.placement(of: source, on: [Self.left, Self.right]), rows: 2)
        gains = (0..<source.count).map { (stereo[$0] + stereo[source.count + $0]) / 2 }
    }

    public func render(_ samples: [Float], frames: Int, into output: UnsafeMutablePointer<Int16>) {
        let inputs = source.count
        let outputs = destination.count
        guard inputs > 0, outputs > 0, frames > 0 else { return }
        let available = min(frames, samples.count / inputs)
        for frame in 0..<available {
            let base = frame * inputs
            for channel in 0..<outputs {
                let row = channel * inputs
                var value: Float = 0
                for input in 0..<inputs where gains[row + input] != 0 { value += gains[row + input] * samples[base + input] }
                output[frame * outputs + channel] = NvstCoreAudioFormat.clamped16(value)
            }
        }
        if available < frames {
            output.advanced(by: available * outputs).update(repeating: 0, count: (frames - available) * outputs)
        }
    }

    /// The speakers behind each channel a playout stream of `channels` drives. A device that
    /// reports no usable layout gets the WAVE order every USB and HDMI surround device defaults to.
    public static func speakers(reported: [AudioChannelLabel], channels: Int) -> [AudioChannelLabel] {
        let named = reported.prefix(channels)
        if named.count == channels, named.contains(where: isSpeaker) { return Array(named) }
        return switch channels {
        case 1: [kAudioChannelLabel_Mono]
        case 6: [left, right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                 kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        case 8: [left, right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                 kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        default: [left, right] + Array(repeating: kAudioChannelLabel_Unused, count: max(0, channels - 2))
        }
    }

    /// Expands a layout given as a tag or a bitmap into its per-channel labels.
    public static func labels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions { return descriptionLabels(of: layout) }
        let usesBitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
        let property = usesBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
        var specifier = usesBitmap ? layout.pointee.mChannelBitmap.rawValue : tag
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size) == noErr,
              Int(size) >= MemoryLayout<AudioChannelLayout>.size else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        guard AudioFormatGetProperty(property, specifierSize, &specifier, &size, storage) == noErr else { return [] }
        return descriptionLabels(of: storage.assumingMemoryBound(to: AudioChannelLayout.self))
    }

    private static func descriptionLabels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) ?? 12
        let descriptions = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<Int(layout.pointee.mNumberChannelDescriptions)).map { descriptions[$0].mChannelLabel }
    }

    private static func isSpeaker(_ label: AudioChannelLabel) -> Bool {
        label != kAudioChannelLabel_Unknown && label != kAudioChannelLabel_Unused
            && label < kAudioChannelLabel_Discrete
    }

    private static let equivalents: [AudioChannelLabel: [AudioChannelLabel]] = [
        kAudioChannelLabel_LeftSurround: [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_LeftSurroundDirect],
        kAudioChannelLabel_RightSurround: [kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_RightSurroundDirect],
        kAudioChannelLabel_RearSurroundLeft: [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect],
        kAudioChannelLabel_RearSurroundRight: [kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect],
    ]

    private static let folds: [AudioChannelLabel: [(AudioChannelLabel, Float)]] = [
        kAudioChannelLabel_Center: [(left, foldGain), (right, foldGain)],
        kAudioChannelLabel_LeftSurround: [(left, foldGain)],
        kAudioChannelLabel_RightSurround: [(right, foldGain)],
        kAudioChannelLabel_RearSurroundLeft: [(left, foldGain)],
        kAudioChannelLabel_RearSurroundRight: [(right, foldGain)],
        kAudioChannelLabel_LeftSurroundDirect: [(left, foldGain)],
        kAudioChannelLabel_RightSurroundDirect: [(right, foldGain)],
        kAudioChannelLabel_CenterSurround: [(left, 0.5), (right, 0.5)],
    ]

    private static func placement(of source: [AudioChannelLabel], on destination: [AudioChannelLabel]) -> [Float] {
        var gains = [Float](repeating: 0, count: destination.count * source.count)
        for (column, label) in source.enumerated() {
            let direct = ([label] + (equivalents[label] ?? [])).lazy.compactMap { destination.firstIndex(of: $0) }.first
            if let direct {
                gains[direct * source.count + column] = 1
                continue
            }
            for (target, gain) in folds[label] ?? [] {
                guard let row = destination.firstIndex(of: target) else { continue }
                gains[row * source.count + column] += gain
            }
        }
        return gains
    }

    private static func normalized(_ gains: [Float], rows: Int) -> [Float] {
        guard rows > 0 else { return gains }
        let columns = gains.count / rows
        let loudest = (0..<rows).map { row in gains[(row * columns)..<((row + 1) * columns)].reduce(0) { $0 + abs($1) } }.max() ?? 0
        guard loudest > 1 else { return gains }
        return gains.map { $0 / loudest }
    }
}

/// Playout's render-thread state: the matrix for whatever device is attached now, and a stereo
/// copy of each render for the recorder, replay buffer and Co-Op relay, which all take stereo.
final class NvstPlayoutMixer: @unchecked Sendable {
    private let source: [AudioChannelLabel]
    private let stereo: NvstSpeakerMatrix
    private let lock = NSLock()
    private var device: NvstSpeakerMatrix?
    private var stereoTap: [Int16] = []
    private var stereoTapFrames = 0

    init(source: [AudioChannelLabel]) {
        self.source = source
        stereo = NvstSpeakerMatrix(from: source, to: [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
    }

    func render(_ samples: [Float], frames: Int, speakers: [AudioChannelLabel], into output: UnsafeMutablePointer<Int16>) {
        lock.lock()
        defer { lock.unlock() }
        if device?.destination != speakers { device = NvstSpeakerMatrix(from: source, to: speakers) }
        device?.render(samples, frames: frames, into: output)
        stereoTapFrames = speakers.count > 2 ? frames : 0
        guard stereoTapFrames > 0 else { return }
        if stereoTap.count < frames * 2 { stereoTap = [Int16](repeating: 0, count: frames * 2) }
        stereoTap.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            stereo.render(samples, frames: frames, into: base)
        }
    }

    /// The last render folded to stereo, as the `AudioBufferList` the game-audio tap carries.
    func withStereoTap(_ body: (UnsafeRawPointer, UInt32) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let frames = stereoTapFrames
        guard frames > 0 else { return }
        stereoTap.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(frames * 2 * MemoryLayout<Int16>.size),
                mData: buffer.baseAddress
            ))
            withUnsafePointer(to: &list) { body(UnsafeRawPointer($0), UInt32(frames)) }
        }
    }
}
