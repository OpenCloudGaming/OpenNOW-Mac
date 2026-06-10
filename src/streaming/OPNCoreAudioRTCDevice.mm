#include "OPNCoreAudioRTCDevice.h"
#include "OPNLibWebRTCStreamSession.h"

#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudio.h>

#include <algorithm>
#include <cstring>
#include <vector>

namespace OPN {
static AudioDeviceID OPNDefaultAudioDevice(AudioObjectPropertySelector selector) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}
}

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCAudioDevice.h>
#pragma clang diagnostic pop

@interface OPNCoreAudioRTCDevice () {
    dispatch_queue_t _audioQueue;
    AudioUnit _playoutUnit;
    AudioUnit _recordingUnit;
    AudioDeviceID _outputDevice;
    AudioDeviceID _inputDevice;
    std::vector<uint8_t> _recordingScratch;
}
@property(nonatomic, weak) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic, assign) double deviceInputSampleRate;
@property(nonatomic, assign) NSTimeInterval inputIOBufferDuration;
@property(nonatomic, assign) NSInteger inputNumberOfChannels;
@property(nonatomic, assign) NSTimeInterval inputLatency;
@property(nonatomic, assign) double deviceOutputSampleRate;
@property(nonatomic, assign) NSTimeInterval outputIOBufferDuration;
@property(nonatomic, assign) NSInteger outputNumberOfChannels;
@property(nonatomic, assign) NSTimeInterval outputLatency;
@property(nonatomic, assign) BOOL isInitialized;
@property(nonatomic, assign) BOOL isPlayoutInitialized;
@property(nonatomic, assign) BOOL isPlaying;
@property(nonatomic, assign) BOOL isRecordingInitialized;
@property(nonatomic, assign) BOOL isRecording;
- (OSStatus)renderPlayoutWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                         timestamp:(const AudioTimeStamp *)timestamp
                         busNumber:(NSInteger)busNumber
                        frameCount:(UInt32)frameCount
                        outputData:(AudioBufferList *)outputData;
- (OSStatus)captureRecordingWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                            timestamp:(const AudioTimeStamp *)timestamp
                            busNumber:(NSInteger)busNumber
                           frameCount:(UInt32)frameCount;
@end

static OSStatus OPNCoreAudioPlayoutCallback(void *refCon,
                                            AudioUnitRenderActionFlags *actionFlags,
                                            const AudioTimeStamp *timestamp,
                                            UInt32 busNumber,
                                            UInt32 frameCount,
                                            AudioBufferList *outputData) {
    return [(__bridge OPNCoreAudioRTCDevice *)refCon renderPlayoutWithFlags:actionFlags
                                                                  timestamp:timestamp
                                                                  busNumber:(NSInteger)busNumber
                                                                 frameCount:frameCount
                                                                 outputData:outputData];
}

static OSStatus OPNCoreAudioRecordingCallback(void *refCon,
                                              AudioUnitRenderActionFlags *actionFlags,
                                              const AudioTimeStamp *timestamp,
                                              UInt32 busNumber,
                                              UInt32 frameCount,
                                              AudioBufferList *) {
    return [(__bridge OPNCoreAudioRTCDevice *)refCon captureRecordingWithFlags:actionFlags
                                                                     timestamp:timestamp
                                                                     busNumber:(NSInteger)busNumber
                                                                    frameCount:frameCount];
}

@implementation OPNCoreAudioRTCDevice

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioQueue = dispatch_queue_create("io.opencg.opennow.webrtc.coreaudio", DISPATCH_QUEUE_SERIAL);
        _playoutUnit = nullptr;
        _recordingUnit = nullptr;
        _outputDevice = kAudioObjectUnknown;
        _inputDevice = kAudioObjectUnknown;
        [self updateDeviceParameters];
    }
    return self;
}

- (void)dealloc {
    [self terminateDevice];
}

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    dispatch_sync(_audioQueue, ^{
        self.delegate = delegate;
        self.isInitialized = YES;
        [self updateDeviceParameters];
    });
    return YES;
}

- (BOOL)terminateDevice {
    dispatch_sync(_audioQueue, ^{
        [self stopPlayoutLocked];
        [self stopRecordingLocked];
        [self disposePlayoutUnitLocked];
        [self disposeRecordingUnitLocked];
        self.delegate = nil;
        self.isInitialized = NO;
        self.isPlayoutInitialized = NO;
        self.isRecordingInitialized = NO;
    });
    return YES;
}

- (BOOL)initializePlayout {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self initializePlayoutLocked]; });
    return ok;
}

- (BOOL)startPlayout {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self startPlayoutLocked]; });
    return ok;
}

- (BOOL)stopPlayout {
    dispatch_sync(_audioQueue, ^{ [self stopPlayoutLocked]; });
    return YES;
}

- (BOOL)initializeRecording {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self initializeRecordingLocked]; });
    return ok;
}

- (BOOL)startRecording {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self startRecordingLocked]; });
    return ok;
}

- (BOOL)stopRecording {
    dispatch_sync(_audioQueue, ^{ [self stopRecordingLocked]; });
    return YES;
}

- (void)handleDefaultDeviceChange {
    dispatch_async(_audioQueue, ^{
        BOOL restartPlayout = self.isPlaying;
        BOOL restartRecording = self.isRecording;
        [self stopPlayoutLocked];
        [self stopRecordingLocked];
        [self disposePlayoutUnitLocked];
        [self disposeRecordingUnitLocked];
        [self updateDeviceParameters];
        id<RTCAudioDeviceDelegate> delegate = self.delegate;
        if (delegate) {
            [delegate dispatchAsync:^{
                [delegate notifyAudioOutputInterrupted];
                [delegate notifyAudioInputInterrupted];
                [delegate notifyAudioOutputParametersChange];
                [delegate notifyAudioInputParametersChange];
            }];
        }
        if (restartPlayout) [self startPlayoutLocked];
        if (restartRecording) [self startRecordingLocked];
        OPNLogInfo(@"[LibWebRTC] CoreAudio RTC device hot-swapped input=%u output=%u play=%d record=%d",
              _inputDevice,
              _outputDevice,
              self.isPlaying,
              self.isRecording);
    });
}

- (OSStatus)renderPlayoutWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                         timestamp:(const AudioTimeStamp *)timestamp
                         busNumber:(NSInteger)busNumber
                        frameCount:(UInt32)frameCount
                        outputData:(AudioBufferList *)outputData {
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    if (!delegate || !outputData) {
        [self clearAudioBufferList:outputData];
        return noErr;
    }
    OSStatus status = delegate.getPlayoutData(actionFlags, timestamp, busNumber, frameCount, outputData);
    if (status != noErr) [self clearAudioBufferList:outputData];
    if (status == noErr && self.owner && outputData) {
        self.owner->HandleGameAudioFrame(outputData,
                                         frameCount,
                                         self.deviceOutputSampleRate,
                                         (uint32_t)self.outputNumberOfChannels);
    }
    return status;
}

- (OSStatus)captureRecordingWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                            timestamp:(const AudioTimeStamp *)timestamp
                            busNumber:(NSInteger)busNumber
                           frameCount:(UInt32)frameCount {
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    if (!delegate || !_recordingUnit) return noErr;
    AudioStreamBasicDescription format = [self streamFormatWithSampleRate:self.deviceInputSampleRate channels:(UInt32)self.inputNumberOfChannels];
    size_t requiredBytes = (size_t)frameCount * format.mBytesPerFrame;
    if (_recordingScratch.size() < requiredBytes) _recordingScratch.resize(requiredBytes);
    AudioBufferList inputData;
    inputData.mNumberBuffers = 1;
    inputData.mBuffers[0].mNumberChannels = (UInt32)self.inputNumberOfChannels;
    inputData.mBuffers[0].mDataByteSize = (UInt32)requiredBytes;
    inputData.mBuffers[0].mData = _recordingScratch.data();
    OSStatus status = AudioUnitRender(_recordingUnit, actionFlags, timestamp, 1, frameCount, &inputData);
    if (status != noErr) return status;
    return delegate.deliverRecordedData(actionFlags, timestamp, busNumber, frameCount, &inputData, nil, nil);
}

- (BOOL)startPlayoutLocked {
    if (![self initializePlayoutLocked]) return NO;
    OSStatus status = AudioOutputUnitStart(_playoutUnit);
    self.isPlaying = status == noErr;
    if (status != noErr) OPNLogError(@"[LibWebRTC] CoreAudio playout start failed status=%d", status);
    return self.isPlaying;
}

- (BOOL)startRecordingLocked {
    if (![self initializeRecordingLocked]) return NO;
    OSStatus status = AudioOutputUnitStart(_recordingUnit);
    self.isRecording = status == noErr;
    if (status != noErr) OPNLogError(@"[LibWebRTC] CoreAudio recording start failed status=%d", status);
    return self.isRecording;
}

- (void)stopPlayoutLocked {
    if (_playoutUnit && self.isPlaying) AudioOutputUnitStop(_playoutUnit);
    self.isPlaying = NO;
}

- (void)stopRecordingLocked {
    if (_recordingUnit && self.isRecording) AudioOutputUnitStop(_recordingUnit);
    self.isRecording = NO;
}

- (BOOL)initializePlayoutLocked {
    if (self.isPlayoutInitialized && _playoutUnit) return YES;
    [self updateDeviceParameters];
    if (_outputDevice == kAudioObjectUnknown) return NO;
    _playoutUnit = [self createHALOutputUnit];
    if (!_playoutUnit) return NO;
    UInt32 enable = 1;
    UInt32 disable = 0;
    AudioUnitSetProperty(_playoutUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof(enable));
    AudioUnitSetProperty(_playoutUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, sizeof(disable));
    OSStatus status = AudioUnitSetProperty(_playoutUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &_outputDevice, sizeof(_outputDevice));
    if (status != noErr) OPNLogError(@"[LibWebRTC] CoreAudio set output device failed status=%d device=%u", status, _outputDevice);
    AudioStreamBasicDescription format = [self streamFormatWithSampleRate:self.deviceOutputSampleRate channels:(UInt32)self.outputNumberOfChannels];
    AudioUnitSetProperty(_playoutUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    AURenderCallbackStruct callback = { OPNCoreAudioPlayoutCallback, (__bridge void *)self };
    AudioUnitSetProperty(_playoutUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    status = AudioUnitInitialize(_playoutUnit);
    if (status != noErr) {
        OPNLogError(@"[LibWebRTC] CoreAudio playout initialize failed status=%d", status);
        [self disposePlayoutUnitLocked];
        return NO;
    }
    self.isPlayoutInitialized = YES;
    return YES;
}

- (BOOL)initializeRecordingLocked {
    if (self.isRecordingInitialized && _recordingUnit) return YES;
    [self updateDeviceParameters];
    if (_inputDevice == kAudioObjectUnknown) return NO;
    _recordingUnit = [self createHALOutputUnit];
    if (!_recordingUnit) return NO;
    UInt32 enable = 1;
    UInt32 disable = 0;
    AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, sizeof(disable));
    AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, sizeof(enable));
    OSStatus status = AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &_inputDevice, sizeof(_inputDevice));
    if (status != noErr) OPNLogError(@"[LibWebRTC] CoreAudio set input device failed status=%d device=%u", status, _inputDevice);
    AudioStreamBasicDescription format = [self streamFormatWithSampleRate:self.deviceInputSampleRate channels:(UInt32)self.inputNumberOfChannels];
    AudioUnitSetProperty(_recordingUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format));
    AURenderCallbackStruct callback = { OPNCoreAudioRecordingCallback, (__bridge void *)self };
    AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback));
    status = AudioUnitInitialize(_recordingUnit);
    if (status != noErr) {
        OPNLogError(@"[LibWebRTC] CoreAudio recording initialize failed status=%d", status);
        [self disposeRecordingUnitLocked];
        return NO;
    }
    self.isRecordingInitialized = YES;
    return YES;
}

- (AudioUnit)createHALOutputUnit {
    AudioComponentDescription desc = {};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) return nullptr;
    AudioUnit unit = nullptr;
    OSStatus status = AudioComponentInstanceNew(component, &unit);
    if (status != noErr) {
        OPNLogError(@"[LibWebRTC] CoreAudio HAL unit creation failed status=%d", status);
        return nullptr;
    }
    return unit;
}

- (void)disposePlayoutUnitLocked {
    if (!_playoutUnit) return;
    AudioUnitUninitialize(_playoutUnit);
    AudioComponentInstanceDispose(_playoutUnit);
    _playoutUnit = nullptr;
    self.isPlayoutInitialized = NO;
}

- (void)disposeRecordingUnitLocked {
    if (!_recordingUnit) return;
    AudioUnitUninitialize(_recordingUnit);
    AudioComponentInstanceDispose(_recordingUnit);
    _recordingUnit = nullptr;
    self.isRecordingInitialized = NO;
}

- (void)updateDeviceParameters {
    _inputDevice = OPN::OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice);
    _outputDevice = OPN::OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice);
    self.deviceInputSampleRate = [self nominalSampleRateForDevice:_inputDevice fallback:self.delegate.preferredInputSampleRate > 0.0 ? self.delegate.preferredInputSampleRate : 48000.0];
    self.deviceOutputSampleRate = [self nominalSampleRateForDevice:_outputDevice fallback:self.delegate.preferredOutputSampleRate > 0.0 ? self.delegate.preferredOutputSampleRate : 48000.0];
    self.inputNumberOfChannels = std::max<NSInteger>(1, std::min<NSInteger>(2, [self channelCountForDevice:_inputDevice scope:kAudioDevicePropertyScopeInput fallback:1]));
    self.outputNumberOfChannels = std::max<NSInteger>(1, std::min<NSInteger>(2, [self channelCountForDevice:_outputDevice scope:kAudioDevicePropertyScopeOutput fallback:2]));
    self.inputIOBufferDuration = self.delegate.preferredInputIOBufferDuration > 0.0 ? self.delegate.preferredInputIOBufferDuration : 0.01;
    self.outputIOBufferDuration = self.delegate.preferredOutputIOBufferDuration > 0.0 ? self.delegate.preferredOutputIOBufferDuration : 0.01;
    self.inputLatency = [self latencyForDevice:_inputDevice scope:kAudioDevicePropertyScopeInput];
    self.outputLatency = [self latencyForDevice:_outputDevice scope:kAudioDevicePropertyScopeOutput];
}

- (double)nominalSampleRateForDevice:(AudioDeviceID)device fallback:(double)fallback {
    if (device == kAudioObjectUnknown) return fallback;
    Float64 rate = fallback;
    UInt32 size = sizeof(rate);
    AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &rate) != noErr || rate <= 0.0) return fallback;
    return rate;
}

- (NSInteger)channelCountForDevice:(AudioDeviceID)device scope:(AudioObjectPropertyScope)scope fallback:(NSInteger)fallback {
    if (device == kAudioObjectUnknown) return fallback;
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr || size < sizeof(AudioBufferList)) return fallback;
    std::vector<uint8_t> storage(size);
    AudioBufferList *bufferList = reinterpret_cast<AudioBufferList *>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, bufferList) != noErr) return fallback;
    UInt32 channels = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) channels += bufferList->mBuffers[i].mNumberChannels;
    return channels > 0 ? (NSInteger)channels : fallback;
}

- (NSTimeInterval)latencyForDevice:(AudioDeviceID)device scope:(AudioObjectPropertyScope)scope {
    if (device == kAudioObjectUnknown) return 0.0;
    UInt32 latencyFrames = 0;
    UInt32 size = sizeof(latencyFrames);
    AudioObjectPropertyAddress address = { kAudioDevicePropertyLatency, scope, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &latencyFrames) != noErr) return 0.0;
    double rate = scope == kAudioDevicePropertyScopeInput ? self.deviceInputSampleRate : self.deviceOutputSampleRate;
    return rate > 0.0 ? (NSTimeInterval)((double)latencyFrames / rate) : 0.0;
}

- (AudioStreamBasicDescription)streamFormatWithSampleRate:(double)sampleRate channels:(UInt32)channels {
    AudioStreamBasicDescription format = {};
    format.mSampleRate = sampleRate > 0.0 ? sampleRate : 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 16;
    format.mChannelsPerFrame = std::max<UInt32>(1, channels);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = format.mChannelsPerFrame * sizeof(int16_t);
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

- (void)clearAudioBufferList:(AudioBufferList *)bufferList {
    if (!bufferList) return;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        if (bufferList->mBuffers[i].mData && bufferList->mBuffers[i].mDataByteSize > 0) {
            std::memset(bufferList->mBuffers[i].mData, 0, bufferList->mBuffers[i].mDataByteSize);
        }
    }
}

@end

#endif
