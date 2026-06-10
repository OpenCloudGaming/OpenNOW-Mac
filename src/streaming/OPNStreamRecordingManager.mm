#import "OPNStreamRecordingManager.h"
#include "OPNStreamPreferences.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#define OPN_HAVE_SCREENCAPTUREKIT 1
#else
#define OPN_HAVE_SCREENCAPTUREKIT 0
#endif

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCI420Buffer.h>
#pragma clang diagnostic pop
#endif

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

typedef NS_ENUM(NSInteger, OPNRecordingAudioKind) {
    OPNRecordingAudioKindSystem = 0,
    OPNRecordingAudioKindMicrophone = 1,
};

#if OPN_HAVE_SCREENCAPTUREKIT
@interface OPNRecordingScreenCaptureOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, weak) OPNStreamRecordingManager *manager;
@end
#endif

@interface OPNStreamRecordingManager () <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, readwrite, getter=isRecording) BOOL recording;
@property (nonatomic, readwrite, getter=isStarting) BOOL starting;
@property (nonatomic, readwrite) NSString *statusText;
@property (nonatomic, readwrite) NSURL *currentRecordingURL;
@property (nonatomic, readwrite) NSArray<NSURL *> *recentRecordingURLs;
@end

@implementation OPNStreamRecordingManager {
    dispatch_queue_t _writerQueue;
    dispatch_queue_t _audioQueue;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_systemAudioInput;
    AVAssetWriterInput *_microphoneAudioInput;
    AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;
    CIContext *_ciContext;
    CGSize _videoSize;
    BOOL _acceptingSamples;
    BOOL _finishRequested;
    CFTimeInterval _recordingStartHostTime;
    CMTime _lastVideoTime;
    CMTime _systemAudioSourceStartTime;
    CMTime _microphoneAudioSourceStartTime;
    CMTime _systemAudioTimelineOffset;
    CMTime _microphoneAudioTimelineOffset;
    BOOL _videoFrameAppendInFlight;
    BOOL _prefersEnhancedVideoCapture;
    BOOL _enhancedVideoActive;
    CFTimeInterval _enhancedVideoFallbackDeadlineHostTime;
    uint64_t _droppedVideoFrames;
    CFTimeInterval _lastDroppedVideoFrameLogTime;
    AVCaptureSession *_microphoneCaptureSession;
#if OPN_HAVE_SCREENCAPTUREKIT
    SCStream *_audioStream;
    OPNRecordingScreenCaptureOutput *_audioOutput;
#endif
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _writerQueue = dispatch_queue_create("com.opennow.recording.writer", DISPATCH_QUEUE_SERIAL);
        _audioQueue = dispatch_queue_create("com.opennow.recording.audio", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:nil];
        _statusText = @"Ready";
        _recentRecordingURLs = @[];
        _lastVideoTime = kCMTimeInvalid;
        _systemAudioSourceStartTime = kCMTimeInvalid;
        _microphoneAudioSourceStartTime = kCMTimeInvalid;
        _systemAudioTimelineOffset = kCMTimeInvalid;
        _microphoneAudioTimelineOffset = kCMTimeInvalid;
        _videoFrameAppendInFlight = NO;
        _prefersEnhancedVideoCapture = NO;
        _enhancedVideoActive = NO;
        _enhancedVideoFallbackDeadlineHostTime = 0.0;
        _droppedVideoFrames = 0;
        _lastDroppedVideoFrameLogTime = 0.0;
        [self refreshRecentRecordings];
    }
    return self;
}

- (void)dealloc {
    [self stopRecording];
}

- (void)toggleRecordingForGameTitle:(NSString *)gameTitle window:(NSWindow *)window {
    if (self.recording || self.starting) {
        [self stopRecording];
    } else {
        [self startRecordingForGameTitle:gameTitle window:window];
    }
}

- (void)startRecordingForGameTitle:(NSString *)gameTitle window:(NSWindow *)window {
    if (self.recording || self.starting) return;

    NSURL *moviesURL = [NSFileManager.defaultManager URLsForDirectory:NSMoviesDirectory inDomains:NSUserDomainMask].firstObject;
    if (!moviesURL) {
        [self updateStatus:@"Movies folder unavailable" starting:NO recording:NO notify:YES];
        return;
    }

    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:moviesURL withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        NSString *message = directoryError.localizedDescription ?: @"Unable to create Movies folder";
        [self updateStatus:message starting:NO recording:NO notify:YES];
        return;
    }

    NSString *filename = OPNRecordingFilename(gameTitle);
    NSURL *outputURL = [moviesURL URLByAppendingPathComponent:filename];
    [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];

    self.currentRecordingURL = outputURL;
    [self updateStatus:@"Starting recording" starting:YES recording:NO notify:YES];

    dispatch_async(_writerQueue, ^{
        self->_writer = nil;
        self->_videoInput = nil;
        self->_systemAudioInput = nil;
        self->_microphoneAudioInput = nil;
        self->_pixelBufferAdaptor = nil;
        self->_videoSize = CGSizeZero;
        self->_acceptingSamples = YES;
        self->_finishRequested = NO;
        self->_recordingStartHostTime = CACurrentMediaTime();
        self->_lastVideoTime = kCMTimeInvalid;
        self->_systemAudioSourceStartTime = kCMTimeInvalid;
        self->_microphoneAudioSourceStartTime = kCMTimeInvalid;
        self->_systemAudioTimelineOffset = kCMTimeInvalid;
        self->_microphoneAudioTimelineOffset = kCMTimeInvalid;
        self->_videoFrameAppendInFlight = NO;
        self->_enhancedVideoFallbackDeadlineHostTime = self->_prefersEnhancedVideoCapture ? CACurrentMediaTime() + 1.25 : 0.0;
        self->_enhancedVideoActive = NO;
        self->_droppedVideoFrames = 0;
        self->_lastDroppedVideoFrameLogTime = 0.0;
    });

    [self startAudioCaptureForWindow:window];
}

- (void)setPrefersEnhancedVideoCapture:(BOOL)prefersEnhancedVideoCapture {
    @synchronized (self) {
        BOOL changed = _prefersEnhancedVideoCapture != prefersEnhancedVideoCapture;
        _prefersEnhancedVideoCapture = prefersEnhancedVideoCapture;
        if (!prefersEnhancedVideoCapture) {
            _enhancedVideoFallbackDeadlineHostTime = 0.0;
            return;
        }
        if (changed || _enhancedVideoFallbackDeadlineHostTime <= 0.0) {
            _enhancedVideoFallbackDeadlineHostTime = CACurrentMediaTime() + 1.25;
        }
    }
}

- (void)stopRecording {
    if (!self.recording && !self.starting) return;

    [self updateStatus:@"Finishing recording" starting:NO recording:NO notify:YES];
    [self stopAudioCapture];
    [self stopAVMicrophoneCapture];

    dispatch_async(_writerQueue, ^{
        self->_acceptingSamples = NO;
        self->_finishRequested = YES;
        self->_videoFrameAppendInFlight = NO;
        AVAssetWriter *writer = self->_writer;
        NSURL *outputURL = self.currentRecordingURL;
        if (!writer) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (outputURL) [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
                self.currentRecordingURL = nil;
                [self updateStatus:@"Recording canceled" starting:NO recording:NO notify:YES];
            });
            return;
        }

        [self->_videoInput markAsFinished];
        [self->_systemAudioInput markAsFinished];
        [self->_microphoneAudioInput markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            NSError *error = writer.error;
            dispatch_async(self->_writerQueue, ^{
                self->_writer = nil;
                self->_videoInput = nil;
                self->_systemAudioInput = nil;
                self->_microphoneAudioInput = nil;
                self->_pixelBufferAdaptor = nil;
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                if (writer.status == AVAssetWriterStatusCompleted && !error) {
                    [self refreshRecentRecordings];
                    [self updateStatus:@"Recording saved" starting:NO recording:NO notify:YES];
                    OPNLogInfo(@"[Recording] Saved %@", outputURL.path);
                } else {
                    if (outputURL) [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
                    NSString *message = error.localizedDescription ?: @"Recording failed";
                    [self updateStatus:message starting:NO recording:NO notify:YES];
                    OPNLogError(@"[Recording] Finish failed status=%ld error=%@", (long)writer.status, error ?: (NSError *)nil);
                }
            });
        }];
    });
}

- (void)appendWebRTCVideoFrame:(void *)frame {
#if defined(OPN_HAVE_LIBWEBRTC)
    if (!frame || (!self.recording && !self.starting)) return;
    RTCVideoFrame *videoFrame = (__bridge RTCVideoFrame *)frame;
    @synchronized (self) {
        if (_enhancedVideoActive) return;
        if (_prefersEnhancedVideoCapture && !_writer && CACurrentMediaTime() < _enhancedVideoFallbackDeadlineHostTime) return;
        if (_videoFrameAppendInFlight) {
            [self recordDroppedVideoFrame];
            return;
        }
        _videoFrameAppendInFlight = YES;
    }
    dispatch_async(_writerQueue, ^{
        @autoreleasepool {
            RTCVideoFrame *retainedFrame = videoFrame;
            if (!retainedFrame || !self->_acceptingSamples || !self.currentRecordingURL) {
                [self finishVideoFrameAppend];
                return;
            }

            CGSize size = OPNRecordingFrameSize(retainedFrame);
            if (size.width < 2.0 || size.height < 2.0) {
                [self finishVideoFrameAppend];
                return;
            }
            if (!self->_writer && ![self createWriterWithVideoSize:size]) {
                [self finishVideoFrameAppend];
                return;
            }
            if (self->_writer.status != AVAssetWriterStatusWriting || !self->_videoInput.readyForMoreMediaData) {
                [self finishVideoFrameAppend];
                return;
            }

            CVPixelBufferRef pixelBuffer = [self copyPixelBufferFromVideoFrame:retainedFrame];
            if (!pixelBuffer) {
                [self finishVideoFrameAppend];
                return;
            }

            CMTime presentationTime = [self nextVideoPresentationTime];
            BOOL appended = [self->_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
            CVPixelBufferRelease(pixelBuffer);
            if (!appended) {
                OPNLogError(@"[Recording] Video append failed: %@", self->_writer.error ?: (NSError *)nil);
            } else if (self.starting) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateStatus:@"Recording" starting:NO recording:YES notify:YES];
                });
            }
            [self finishVideoFrameAppend];
        }
    });
#else
    (void)frame;
#endif
}

- (void)appendEnhancedPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer || (!self.recording && !self.starting)) return;
    CVPixelBufferRetain(pixelBuffer);
    @synchronized (self) {
        if (_videoFrameAppendInFlight) {
            CVPixelBufferRelease(pixelBuffer);
            [self recordDroppedVideoFrame];
            return;
        }
        _videoFrameAppendInFlight = YES;
    }
    dispatch_async(_writerQueue, ^{
        @autoreleasepool {
            if (!self->_acceptingSamples || !self.currentRecordingURL) {
                CVPixelBufferRelease(pixelBuffer);
                [self finishVideoFrameAppend];
                return;
            }

            CGSize size = CGSizeMake(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
            if (size.width < 2.0 || size.height < 2.0) {
                CVPixelBufferRelease(pixelBuffer);
                [self finishVideoFrameAppend];
                return;
            }
            long long writerWidth = std::llround(self->_videoSize.width);
            long long writerHeight = std::llround(self->_videoSize.height);
            long long frameWidth = std::llround(size.width);
            long long frameHeight = std::llround(size.height);
            if (self->_writer && (writerWidth != frameWidth || writerHeight != frameHeight)) {
                CVPixelBufferRelease(pixelBuffer);
                @synchronized (self) {
                    self->_enhancedVideoActive = NO;
                }
                [self finishVideoFrameAppend];
                return;
            }
            if (!self->_writer && ![self createWriterWithVideoSize:size]) {
                CVPixelBufferRelease(pixelBuffer);
                [self finishVideoFrameAppend];
                return;
            }
            @synchronized (self) {
                self->_enhancedVideoActive = YES;
            }
            if (self->_writer.status != AVAssetWriterStatusWriting || !self->_videoInput.readyForMoreMediaData) {
                CVPixelBufferRelease(pixelBuffer);
                [self finishVideoFrameAppend];
                return;
            }

            CMTime presentationTime = [self nextVideoPresentationTime];
            BOOL appended = [self->_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
            CVPixelBufferRelease(pixelBuffer);
            if (!appended) {
                OPNLogError(@"[Recording] Enhanced video append failed: %@", self->_writer.error ?: (NSError *)nil);
            } else if (self.starting) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateStatus:@"Recording" starting:NO recording:YES notify:YES];
                });
            }
            [self finishVideoFrameAppend];
        }
    });
}

- (void)finishVideoFrameAppend {
    @synchronized (self) {
        _videoFrameAppendInFlight = NO;
    }
}

- (void)recordDroppedVideoFrame {
    _droppedVideoFrames++;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastDroppedVideoFrameLogTime >= 5.0) {
        OPNLogError(@"[Recording] Dropping video frames while writer is busy (total=%llu)", (unsigned long long)_droppedVideoFrames);
        _lastDroppedVideoFrameLogTime = now;
    }
}

- (NSImage *)thumbnailForRecordingURL:(NSURL *)url size:(NSSize)size {
    if (!url) return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = size;
    NSError *error = nil;
    CGImageRef image = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.5, 600) actualTime:nil error:&error];
    if (!image) image = [generator copyCGImageAtTime:kCMTimeZero actualTime:nil error:&error];
    if (!image) return nil;
    NSImage *thumbnail = [[NSImage alloc] initWithCGImage:image size:size];
    CGImageRelease(image);
    return thumbnail;
}

- (BOOL)createWriterWithVideoSize:(CGSize)size {
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:self.currentRecordingURL fileType:AVFileTypeMPEG4 error:&error];
    if (!writer || error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStatus:error.localizedDescription ?: @"Unable to start writer" starting:NO recording:NO notify:YES];
        });
        return NO;
    }

    NSInteger width = std::max<NSInteger>(2, (NSInteger)std::llround(size.width));
    NSInteger height = std::max<NSInteger>(2, (NSInteger)std::llround(size.height));
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    const NSInteger kMinAutomaticVideoBitrate = 5000000;
    const NSInteger kMaxAutomaticVideoBitrate = 60000000;
    // Heuristic for resolution-based bitrate estimate before clamping.
    const NSInteger kTargetBitsPerPixel = 8;
    NSInteger automaticVideoBitrate = std::min<NSInteger>(kMaxAutomaticVideoBitrate, std::max<NSInteger>(kMinAutomaticVideoBitrate, width * height * kTargetBitsPerPixel));
    NSInteger videoBitrate = profile.recordingVideoBitrateMbps > 0 ? (NSInteger)profile.recordingVideoBitrateMbps * 1000000 : automaticVideoBitrate;
    NSInteger systemAudioBitrate = std::max<NSInteger>(64000, (NSInteger)profile.recordingAudioBitrateKbps * 1000);
    NSInteger microphoneAudioBitrate = std::max<NSInteger>(64000, (systemAudioBitrate * 3) / 5);
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(videoBitrate),
            AVVideoExpectedSourceFrameRateKey: @60,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        },
    };
    AVAssetWriterInput *videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    videoInput.expectsMediaDataInRealTime = YES;
    NSDictionary *pixelAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:videoInput sourcePixelBufferAttributes:pixelAttributes];

    AVAssetWriterInput *systemAudio = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:OPNRecordingAudioSettings(2, systemAudioBitrate)];
    systemAudio.expectsMediaDataInRealTime = YES;
    AVAssetWriterInput *microphoneAudio = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:OPNRecordingAudioSettings(1, microphoneAudioBitrate)];
    microphoneAudio.expectsMediaDataInRealTime = YES;

    if (![writer canAddInput:videoInput]) return NO;
    [writer addInput:videoInput];
    if ([writer canAddInput:systemAudio]) [writer addInput:systemAudio];
    if ([writer canAddInput:microphoneAudio]) [writer addInput:microphoneAudio];

    if (![writer startWriting]) {
        OPNLogError(@"[Recording] startWriting failed: %@", writer.error ?: (NSError *)nil);
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    _writer = writer;
    _videoInput = videoInput;
    _systemAudioInput = systemAudio;
    _microphoneAudioInput = microphoneAudio;
    _pixelBufferAdaptor = adaptor;
    _videoSize = CGSizeMake(width, height);
    OPNLogInfo(@"[Recording] Writer started %@ %.0fx%.0f", self.currentRecordingURL.path, _videoSize.width, _videoSize.height);
    return YES;
}

- (CMTime)nextVideoPresentationTime {
    CFTimeInterval elapsed = std::max<CFTimeInterval>(0.0, CACurrentMediaTime() - _recordingStartHostTime);
    CMTime time = CMTimeMakeWithSeconds(elapsed, 600);
    if (CMTIME_IS_VALID(_lastVideoTime) && CMTimeCompare(time, _lastVideoTime) <= 0) {
        time = CMTimeAdd(_lastVideoTime, CMTimeMake(1, 600));
    }
    _lastVideoTime = time;
    return time;
}

#if defined(OPN_HAVE_LIBWEBRTC)
- (CVPixelBufferRef)copyPixelBufferFromVideoFrame:(RTCVideoFrame *)frame {
    CVPixelBufferRef output = nil;
    CVPixelBufferPoolRef pool = _pixelBufferAdaptor.pixelBufferPool;
    if (!pool || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) != kCVReturnSuccess || !output) {
        return nil;
    }

    id<RTCVideoFrameBuffer> buffer = frame.buffer;
    if ([buffer isKindOfClass:RTCCVPixelBuffer.class]) {
        RTCCVPixelBuffer *cvBuffer = (RTCCVPixelBuffer *)buffer;
        CIImage *image = [CIImage imageWithCVPixelBuffer:cvBuffer.pixelBuffer];
        if (cvBuffer.requiresCropping) {
            CGRect crop = CGRectMake(cvBuffer.cropX, cvBuffer.cropY, cvBuffer.cropWidth, cvBuffer.cropHeight);
            image = [[image imageByCroppingToRect:crop] imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
        }
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        [_ciContext render:image toCVPixelBuffer:output bounds:CGRectMake(0, 0, _videoSize.width, _videoSize.height) colorSpace:colorSpace];
        CGColorSpaceRelease(colorSpace);
        return output;
    }

    RTCVideoFrame *i420Frame = [frame newI420VideoFrame];
    id<RTCI420Buffer> i420 = (id<RTCI420Buffer>)i420Frame.buffer;
    if (!i420) {
        CVPixelBufferRelease(output);
        return nil;
    }
    [self copyI420Buffer:i420 toBGRAOutput:output];
    return output;
}

- (void)copyI420Buffer:(id)buffer toBGRAOutput:(CVPixelBufferRef)output {
#if defined(OPN_HAVE_LIBWEBRTC)
    id<RTCI420Buffer> i420 = (id<RTCI420Buffer>)buffer;
    CVPixelBufferLockBaseAddress(output, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(output);
    const size_t dstStride = CVPixelBufferGetBytesPerRow(output);
    const int width = std::min<int>((int)_videoSize.width, i420.width);
    const int height = std::min<int>((int)_videoSize.height, i420.height);
    for (int y = 0; y < height; y++) {
        uint8_t *row = dst + (size_t)y * dstStride;
        const uint8_t *yRow = i420.dataY + y * i420.strideY;
        const uint8_t *uRow = i420.dataU + (y / 2) * i420.strideU;
        const uint8_t *vRow = i420.dataV + (y / 2) * i420.strideV;
        for (int x = 0; x < width; x++) {
            int yy = (int)yRow[x];
            int uu = (int)uRow[x / 2] - 128;
            int vv = (int)vRow[x / 2] - 128;
            int r = yy + (int)std::lround(1.402 * vv);
            int g = yy - (int)std::lround(0.344136 * uu + 0.714136 * vv);
            int b = yy + (int)std::lround(1.772 * uu);
            row[x * 4 + 0] = (uint8_t)std::max(0, std::min(255, b));
            row[x * 4 + 1] = (uint8_t)std::max(0, std::min(255, g));
            row[x * 4 + 2] = (uint8_t)std::max(0, std::min(255, r));
            row[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(output, 0);
#else
    (void)buffer;
    (void)output;
#endif
}
#endif

- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer kind:(OPNRecordingAudioKind)kind {
    if (!sampleBuffer || (!self.recording && !self.starting)) return;
    CFRetain(sampleBuffer);
    dispatch_async(_writerQueue, ^{
        if (!self->_acceptingSamples || !self->_writer || self->_writer.status != AVAssetWriterStatusWriting) {
            CFRelease(sampleBuffer);
            return;
        }
        AVAssetWriterInput *input = kind == OPNRecordingAudioKindMicrophone ? self->_microphoneAudioInput : self->_systemAudioInput;
        if (!input || !input.readyForMoreMediaData) {
            CFRelease(sampleBuffer);
            return;
        }
        CMSampleBufferRef retimed = [self copyAudioSampleBuffer:sampleBuffer kind:kind];
        CFRelease(sampleBuffer);
        if (!retimed) return;
        BOOL appended = [input appendSampleBuffer:retimed];
        CFRelease(retimed);
        if (!appended) {
            OPNLogError(@"[Recording] Audio append failed: %@", self->_writer.error ?: (NSError *)nil);
        }
    });
}

- (void)appendPreparedAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer kind:(OPNRecordingAudioKind)kind {
    if (!sampleBuffer || (!self.recording && !self.starting)) return;
    CFRetain(sampleBuffer);
    dispatch_async(_writerQueue, ^{
        if (!self->_acceptingSamples || !self->_writer || self->_writer.status != AVAssetWriterStatusWriting) {
            CFRelease(sampleBuffer);
            return;
        }
        AVAssetWriterInput *input = kind == OPNRecordingAudioKindMicrophone ? self->_microphoneAudioInput : self->_systemAudioInput;
        if (!input || !input.readyForMoreMediaData) {
            CFRelease(sampleBuffer);
            return;
        }
        BOOL appended = [input appendSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
        if (!appended) {
            OPNLogError(@"[Recording] Prepared audio append failed: %@", self->_writer.error ?: (NSError *)nil);
        }
    });
}

- (void)appendWebRTCAudioBufferList:(const AudioBufferList *)audioBufferList frameCount:(UInt32)frameCount sampleRate:(double)sampleRate channels:(UInt32)channels {
    if (!audioBufferList || frameCount == 0 || (!self.recording && !self.starting)) return;
    if (audioBufferList->mNumberBuffers == 0 || !audioBufferList->mBuffers[0].mData || audioBufferList->mBuffers[0].mDataByteSize == 0) return;

    AudioStreamBasicDescription format = {};
    format.mSampleRate = sampleRate > 0.0 ? sampleRate : 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 16;
    format.mChannelsPerFrame = std::max<UInt32>(1, channels);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = format.mChannelsPerFrame * sizeof(int16_t);
    format.mBytesPerPacket = format.mBytesPerFrame;

    const UInt32 expectedBytes = frameCount * format.mBytesPerFrame;
    const UInt32 dataBytes = std::min<UInt32>(expectedBytes, audioBufferList->mBuffers[0].mDataByteSize);
    if (dataBytes == 0) return;

    CMFormatDescriptionRef formatDescription = nil;
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, 0, nullptr, 0, nullptr, nullptr, &formatDescription);
    if (status != noErr || !formatDescription) return;

    CMBlockBufferRef blockBuffer = nil;
    status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, dataBytes, kCFAllocatorDefault, nullptr, 0, dataBytes, 0, &blockBuffer);
    if (status != noErr || !blockBuffer) {
        CFRelease(formatDescription);
        return;
    }
    status = CMBlockBufferReplaceDataBytes(audioBufferList->mBuffers[0].mData, blockBuffer, 0, dataBytes);
    if (status != noErr) {
        CFRelease(blockBuffer);
        CFRelease(formatDescription);
        return;
    }

    CMSampleTimingInfo timing = {};
    timing.duration = CMTimeMake(1, (int32_t)format.mSampleRate);
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(std::max<CFTimeInterval>(0.0, CACurrentMediaTime() - _recordingStartHostTime), 600);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef sampleBuffer = nil;
    const CMItemCount sampleCount = std::max<CMItemCount>(1, dataBytes / format.mBytesPerFrame);
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, formatDescription, sampleCount, 1, &timing, 0, nullptr, &sampleBuffer);
    CFRelease(blockBuffer);
    CFRelease(formatDescription);
    if (status != noErr || !sampleBuffer) return;

    [self appendPreparedAudioSampleBuffer:sampleBuffer kind:OPNRecordingAudioKindSystem];
    CFRelease(sampleBuffer);
}

- (CMSampleBufferRef)copyAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer kind:(OPNRecordingAudioKind)kind {
    CMTime sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_VALID(sourceTime)) return nil;

    CMTime *sourceStart = kind == OPNRecordingAudioKindMicrophone ? &_microphoneAudioSourceStartTime : &_systemAudioSourceStartTime;
    CMTime *timelineOffset = kind == OPNRecordingAudioKindMicrophone ? &_microphoneAudioTimelineOffset : &_systemAudioTimelineOffset;
    if (!CMTIME_IS_VALID(*sourceStart)) {
        *sourceStart = sourceTime;
        *timelineOffset = CMTimeMakeWithSeconds(std::max<CFTimeInterval>(0.0, CACurrentMediaTime() - _recordingStartHostTime), 600);
    }

    CMTime delta = CMTimeSubtract(sourceTime, *sourceStart);
    CMTime targetTime = CMTimeAdd(*timelineOffset, delta);
    CMItemCount count = CMSampleBufferGetNumSamples(sampleBuffer);
    if (count <= 0) return nil;

    std::vector<CMSampleTimingInfo> timing((size_t)count);
    OSStatus status = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, count, timing.data(), nullptr);
    if (status != noErr) return nil;
    CMTime shift = CMTimeSubtract(targetTime, sourceTime);
    for (CMSampleTimingInfo &info : timing) {
        if (CMTIME_IS_VALID(info.presentationTimeStamp)) info.presentationTimeStamp = CMTimeAdd(info.presentationTimeStamp, shift);
        if (CMTIME_IS_VALID(info.decodeTimeStamp)) info.decodeTimeStamp = CMTimeAdd(info.decodeTimeStamp, shift);
    }
    CMSampleBufferRef copy = nil;
    status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, count, timing.data(), &copy);
    return status == noErr ? copy : nil;
}

- (void)startAudioCaptureForWindow:(NSWindow *)window {
    (void)window;
    [self startAVMicrophoneCapture];
    OPNLogInfo(@"[Recording] Direct WebRTC game audio enabled; system audio capture disabled");
}

- (void)stopAudioCapture {
}

- (void)startAVMicrophoneCapture {
    if (_microphoneCaptureSession) return;
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
        OPNLogError(@"[Recording] Microphone recording unavailable: permission denied");
        return;
    }
    if (status == AVAuthorizationStatusNotDetermined) {
        __weak OPNStreamRecordingManager *weakSelf = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            if (!granted) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf startAVMicrophoneCapture];
            });
        }];
        return;
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (!device) return;
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input || error) {
        OPNLogError(@"[Recording] Microphone input failed: %@", error.localizedDescription ?: @"unknown");
        return;
    }
    AVCaptureAudioDataOutput *output = [[AVCaptureAudioDataOutput alloc] init];
    [output setSampleBufferDelegate:self queue:_audioQueue];
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if (![session canAddInput:input] || ![session canAddOutput:output]) return;
    [session addInput:input];
    [session addOutput:output];
    _microphoneCaptureSession = session;
    [session startRunning];
    OPNLogInfo(@"[Recording] AVFoundation microphone capture started");
}

- (void)stopAVMicrophoneCapture {
    AVCaptureSession *session = _microphoneCaptureSession;
    _microphoneCaptureSession = nil;
    if (!session) return;
    dispatch_async(_audioQueue, ^{
        [session stopRunning];
    });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;
    [self appendAudioSampleBuffer:sampleBuffer kind:OPNRecordingAudioKindMicrophone];
}

- (void)refreshRecentRecordings {
    NSURL *moviesURL = [NSFileManager.defaultManager URLsForDirectory:NSMoviesDirectory inDomains:NSUserDomainMask].firstObject;
    if (!moviesURL) {
        self.recentRecordingURLs = @[];
        return;
    }
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:moviesURL includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSMutableArray<NSURL *> *recordings = [NSMutableArray array];
    for (NSURL *url in files) {
        if (![url.lastPathComponent hasPrefix:@"OpenNOW-"] || ![url.pathExtension.lowercaseString isEqualToString:@"mp4"]) continue;
        [recordings addObject:url];
    }
    [recordings sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA = nil;
        NSDate *dateB = nil;
        [a getResourceValue:&dateA forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&dateB forKey:NSURLContentModificationDateKey error:nil];
        return [dateB ?: NSDate.distantPast compare:dateA ?: NSDate.distantPast];
    }];
    if (recordings.count > 6) {
        self.recentRecordingURLs = [recordings subarrayWithRange:NSMakeRange(0, 6)];
    } else {
        self.recentRecordingURLs = recordings;
    }
}

- (void)updateStatus:(NSString *)status starting:(BOOL)starting recording:(BOOL)recording notify:(BOOL)notify {
    self.statusText = status ?: @"Ready";
    self.starting = starting;
    self.recording = recording;
    if (notify && self.onStateChanged) self.onStateChanged();
}

static NSDictionary *OPNRecordingAudioSettings(NSInteger channels, NSInteger bitrate) {
    return @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @(channels),
        AVEncoderBitRateKey: @(bitrate),
    };
}

static NSString *OPNRecordingFilename(NSString *gameTitle) {
    NSString *title = gameTitle.length > 0 ? gameTitle : @"Stream";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < title.length; i++) {
        unichar c = [title characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [safe appendFormat:@"%C", c];
        } else if (safe.length == 0 || ![[safe substringFromIndex:safe.length - 1] isEqualToString:@"-"]) {
            [safe appendString:@"-"];
        }
    }
    while ([safe hasSuffix:@"-"]) [safe deleteCharactersInRange:NSMakeRange(safe.length - 1, 1)];
    if (safe.length == 0) [safe appendString:@"Stream"];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    return [NSString stringWithFormat:@"OpenNOW-%@-%@.mp4", safe, [formatter stringFromDate:NSDate.date]];
}

#if defined(OPN_HAVE_LIBWEBRTC)
static CGSize OPNRecordingFrameSize(RTCVideoFrame *frame) {
    if (!frame) return CGSizeZero;
    if (frame.rotation == RTCVideoRotation_90 || frame.rotation == RTCVideoRotation_270) {
        return CGSizeMake(frame.height, frame.width);
    }
    return CGSizeMake(frame.width, frame.height);
}
#endif

@end

#if OPN_HAVE_SCREENCAPTUREKIT
@implementation OPNRecordingScreenCaptureOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (!sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) return;
    if (@available(macOS 13.0, *)) {
        if (type == SCStreamOutputTypeScreen) {
            // Screen/video frames are handled by the dedicated video capture path;
            // this SCStreamOutput instance is used only for audio sample forwarding.
            return;
        }
        if (type == SCStreamOutputTypeAudio) {
            [self.manager appendAudioSampleBuffer:sampleBuffer kind:OPNRecordingAudioKindSystem];
        }
    }
    if (@available(macOS 15.0, *)) {
        if (type == SCStreamOutputTypeMicrophone) {
            [self.manager appendAudioSampleBuffer:sampleBuffer kind:OPNRecordingAudioKindMicrophone];
        }
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    if (error) OPNLogError(@"[Recording] ScreenCaptureKit stopped: %@", error.localizedDescription ?: @"unknown");
}

@end
#endif
