#import "VoIPBridge.h"
#import <AVFoundation/AVFoundation.h>

extern void CallDiagLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#import <TgVoipWebrtc/OngoingCallThreadLocalContext.h>

// MARK: - Own video renderer
//
// The archive's VideoMetalView never receives frames in this process, so the
// app renders the decoded frames itself: the engine exposes them through
// addVideoOutputWithIsIncoming:sink: (remote) and capturer addVideoOutput:
// (local). Frames are enqueued into an AVSampleBufferDisplayLayer, which is the
// most efficient path available without Metal plumbing of our own.
@interface VoIPVideoLayerView : UIView {
    int64_t _frameIndex;
    BOOL _mirrorAllowed;
    NSInteger _videoOrientation;
    BOOL _videoMirror;
    NSInteger _rotationOffset;
    BOOL _flip;
    BOOL _fillsScreen;
    CGFloat _appliedScale;
    CGSize _lastAppliedSize;
    NSInteger _lastAppliedOrientation;
    BOOL _lastAppliedMirror;
    BOOL _lastAppliedFlip;
    CGFloat _lastAppliedScale;
    dispatch_queue_t _renderQueue;
    BOOL _scheduledFlush;
}
@end

@implementation VoIPVideoLayerView

- (void)setFillsScreen:(BOOL)fill {
    _fillsScreen = fill;
    AVSampleBufferDisplayLayer *layer = [self displayLayer];
    layer.videoGravity = AVLayerVideoGravityResize;
    [self setNeedsLayout];
    [self applyVideoTransform];
}

- (void)setFlip:(BOOL)flip {
    _flip = flip;
    [self setNeedsLayout];
    [self applyVideoTransform];
}

- (void)setRotationOffset:(NSInteger)steps {
    _rotationOffset = ((steps % 4) + 4) % 4;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
    });
}

- (void)setMirrorAllowed:(BOOL)allowed {
    _mirrorAllowed = allowed;
}

/// Rotates the whole view (not its layer) and compensates the scale so the
/// rotated video still fills its container without being cropped.
- (void)applyVideoTransform {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (width <= 0 || height <= 0) { return; }
    // Guard: changing layer bounds inside layoutSubviews re-triggers layout.
    // Applying only when something actually changed breaks that feedback loop,
    // which was starving the UI even though the main thread was not blocked.
    if (CGSizeEqualToSize(_lastAppliedSize, self.bounds.size)
        && _lastAppliedOrientation == _videoOrientation
        && _lastAppliedMirror == _videoMirror
        && _lastAppliedFlip == _flip
        && fabs(_lastAppliedScale - _appliedScale) < 0.001) {
        return;
    }
    _lastAppliedSize = self.bounds.size;
    _lastAppliedOrientation = _videoOrientation;
    _lastAppliedMirror = _videoMirror;
    _lastAppliedFlip = _flip;
    _lastAppliedScale = _appliedScale;
    CGFloat angle = 0;
    switch ((_videoOrientation + _rotationOffset) % 4) {
        case 1: angle = -M_PI_2; break;
        case 2: angle = M_PI; break;
        case 3: angle = M_PI_2; break;
        default: angle = 0; break;
    }
    CGAffineTransform transform = CGAffineTransformMakeRotation(angle);
    if (_videoMirror) {
        transform = CGAffineTransformConcat(CGAffineTransformMakeScale(-1, 1), transform);
    }
    (void)transform;
    // Rotate the layer inside fixed bounds and let videoGravity fill it. No
    // bounds swap and no mirroring: the swap cropped the image and the extra
    // horizontal flip made it look mirrored/"upside down".
    self.transform = CGAffineTransformIdentity;
    AVSampleBufferDisplayLayer *displayLayer = [self displayLayer];
    // Both streams arrive rotated by 180 degrees on this device.
    if (_rotationOffset == 0) {
        angle += M_PI;
    }
    if (!_fillsScreen) {
        _appliedScale = 1.0;
    }
    CATransform3D layerTransform = CATransform3DMakeRotation(angle, 0, 0, 1);
    layerTransform = CATransform3DScale(layerTransform, _appliedScale, _appliedScale, 1);
    if (_flip) {
        layerTransform = CATransform3DScale(layerTransform, -1, 1, 1);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    displayLayer.bounds = CGRectMake(0, 0, width, height);
    displayLayer.position = CGPointMake(width / 2.0, height / 2.0);
    displayLayer.transform = layerTransform;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyVideoTransform];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.userInteractionEnabled = NO;
        _renderQueue = dispatch_queue_create("fignyagram.video.render", DISPATCH_QUEUE_SERIAL);
        AVSampleBufferDisplayLayer *layer = [self displayLayer];
        layer.videoGravity = AVLayerVideoGravityResize;
        layer.backgroundColor = [UIColor blackColor].CGColor;
    }
    return self;
}

+ (Class)layerClass {
    return [AVSampleBufferDisplayLayer class];
}

- (AVSampleBufferDisplayLayer *)displayLayer {
    return (AVSampleBufferDisplayLayer *)self.layer;
}

- (void)renderFrame:(CallVideoFrameData *)frame {
    AVSampleBufferDisplayLayer *display = [self displayLayer];
    if (display.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [display flush];
        _frameIndex = 0;
    }
    // Dropping frames keeps latency low: the display layer is the bottleneck.
    if (!display.isReadyForMoreMediaData) {
        return;
    }
    id buffer = frame.buffer;
    CVPixelBufferRef pixelBuffer = NULL;
    if ([buffer isKindOfClass:[CallVideoFrameNativePixelBuffer class]]) {
        pixelBuffer = ((CallVideoFrameNativePixelBuffer *)buffer).pixelBuffer;
    }
    if (pixelBuffer == NULL) {
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            CallDiagLog(@"video frame buffer type unsupported: %@", NSStringFromClass(((NSObject *)buffer).class));
        }
        return;
    }
    AVSampleBufferDisplayLayer *layer = [self displayLayer];
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr || format == NULL) {
        CallDiagLog(@"video render: cannot create format description");
        return;
    }
    _frameIndex += 1;
    CMTime pts = CMTimeMake(_frameIndex, 30);
    CMSampleTimingInfo timing = { CMTimeMake(1, 30), pts, kCMTimeInvalid };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, format, &timing, &sample);
    CFRelease(format);
    if (status != noErr || sample == NULL) {
        CallDiagLog(@"video render: cannot create sample buffer status=%d", (int)status);
        return;
    }
    CGFloat bufferAspect = (CGFloat)CVPixelBufferGetWidth(pixelBuffer) /
                           (CGFloat)MAX(1, CVPixelBufferGetHeight(pixelBuffer));
    BOOL quarterTurn = (frame.orientation == OngoingCallVideoOrientation90 ||
                        frame.orientation == OngoingCallVideoOrientation270);
    CGFloat contentAspect = quarterTurn ? 1.0 / bufferAspect : bufferAspect;
    CGFloat viewport = self.bounds.size.height > 0 ? self.bounds.size.width / self.bounds.size.height : 0;
    CGFloat requiredZoom = 1.0;
    if (contentAspect > 0 && viewport > 0) {
        requiredZoom = MAX(viewport / contentAspect, contentAspect / viewport);
    }
    // The layer stretches the frame to its bounds, so no extra zoom is needed.
    (void)requiredZoom;
    _appliedScale = 1.0;

    // Orientation is applied to the view itself (see applyVideoTransform),
    // rotating the CALayer inside fixed bounds cropped the picture and made it
    // look rotated by 90 degrees.
    NSInteger orientation = (NSInteger)frame.orientation;
    BOOL mirror = _mirrorAllowed && frame.mirrorHorizontally;
    if (orientation != _videoOrientation || mirror != _videoMirror) {
        _videoOrientation = orientation;
        _videoMirror = mirror;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsLayout];
        });
    }
    [layer enqueueSampleBuffer:sample];
    if (_frameIndex == 1) {
        CallDiagLog(@"video render: first frame size=%dx%d view=%.0fx%.0f layer=%.0fx%.0f orientation=%ld",
                    frame.width, frame.height,
                    self.bounds.size.width, self.bounds.size.height,
                    layer.bounds.size.width, layer.bounds.size.height,
                    (long)frame.orientation);
    }
    CFRelease(sample);
}

@end


// MARK: - RTCAudioSession compatibility
//
// The prebuilt engine's C++ audio layer is newer than the ObjC classes shipped
// in the same archive: it sends -setConfiguration:active:error:disableRecording:
// while the registered RTCAudioSession only implements the 3-argument variant.
// Without this shim the engine raises NSInvalidArgumentException on its audio
// thread and the app dies right after the call is answered.
#import <objc/message.h>

@interface RTCAudioSession : NSObject
@end

@implementation RTCAudioSession (FignyagramCompatibility)

- (BOOL)setConfiguration:(id)configuration
                  active:(BOOL)active
                   error:(NSError **)error
         disableRecording:(BOOL)disableRecording {
    // The bundled RTC clas only exposes the granular AVAudioSession wrappers.
    // Using them (instead of touching AVAudioSession directly) keeps the
    // WebRTC ADM's internal activation state consistent, which is required for
    // the audio unit to actually start.
    BOOL ok = YES;
    NSError *localError = nil;
    // The WebRTC ADM already holds RTCAudioSession's configuration lock when it
    // calls this method; locking/unlocking here would break its internal
    // recursive-lock counter and trip an RTC_CHECK inside unlockForConfiguration.
    if (configuration != nil) {
        NSString *category = [configuration valueForKey:@"category"];
        NSString *mode = [configuration valueForKey:@"mode"];
        NSNumber *optionsValue = [configuration valueForKey:@"categoryOptions"];
        NSNumber *sampleRate = [configuration valueForKey:@"sampleRate"];
        NSNumber *ioBuffer = [configuration valueForKey:@"ioBufferDuration"];
        if ([category isKindOfClass:[NSString class]]) {
            SEL sel = NSSelectorFromString(@"setCategory:withOptions:error:");
            if ([self respondsToSelector:sel]) {
                BOOL (*send)(id, SEL, NSString *, NSUInteger, NSError **) =
                    (BOOL (*)(id, SEL, NSString *, NSUInteger, NSError **))objc_msgSend;
                ok = send(self, sel, category, optionsValue.unsignedIntegerValue, &localError) && ok;
            }
        }
        if ([mode isKindOfClass:[NSString class]]) {
            SEL sel = NSSelectorFromString(@"setMode:error:");
            if ([self respondsToSelector:sel]) {
                BOOL (*send)(id, SEL, NSString *, NSError **) =
                    (BOOL (*)(id, SEL, NSString *, NSError **))objc_msgSend;
                ok = send(self, sel, mode, &localError) && ok;
            }
        }
        if (sampleRate.doubleValue > 0) {
            SEL sel = NSSelectorFromString(@"setPreferredSampleRate:error:");
            if ([self respondsToSelector:sel]) {
                BOOL (*send)(id, SEL, double, NSError **) =
                    (BOOL (*)(id, SEL, double, NSError **))objc_msgSend;
                ok = send(self, sel, sampleRate.doubleValue, &localError) && ok;
            }
        }
        if (ioBuffer.doubleValue > 0) {
            SEL sel = NSSelectorFromString(@"setPreferredIOBufferDuration:error:");
            if ([self respondsToSelector:sel]) {
                BOOL (*send)(id, SEL, double, NSError **) =
                    (BOOL (*)(id, SEL, double, NSError **))objc_msgSend;
                ok = send(self, sel, ioBuffer.doubleValue, &localError) && ok;
            }
        }
    }
    if (active) {
        SEL sel = NSSelectorFromString(@"setActive:error:");
        if ([self respondsToSelector:sel]) {
            BOOL (*send)(id, SEL, BOOL, NSError **) =
                (BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend;
            ok = send(self, sel, YES, &localError) && ok;
        } else {
            ok = [[AVAudioSession sharedInstance] setActive:YES error:&localError] && ok;
        }
    }
    // The original implementation also toggles the recording gate; without it
    // the ADM records silence while playback keeps working (one-way audio).
    SEL enableSelector = NSSelectorFromString(@"setIsAudioEnabled:");
    if ([self respondsToSelector:enableSelector]) {
        void (*send)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
        send(self, enableSelector, disableRecording ? NO : YES);
        CallDiagLog(@"RTCAudioSession compat isAudioEnabled=%d", disableRecording ? 0 : 1);
    }
    SEL activeSelector = NSSelectorFromString(@"setIsActive:");
    if ([self respondsToSelector:activeSelector]) {
        void (*send)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
        send(self, activeSelector, active);
    }
    CallDiagLog(@"RTCAudioSession compat applied ok=%d active=%d error=%@", ok, active, localError);
    if (error != NULL) {
        *error = localError;
    }
    return ok;
}
@end




// Forward-declared Swift diagnostic sink (CallDiag).
extern void CallDiagLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

void CallDiagLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"FignyagramCall %@", message);

    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [docs stringByAppendingPathComponent:@"call_diag.log"];
    });
    @synchronized (path) {
        NSString *line = [NSString stringWithFormat:@"%.3f %@\n", [NSDate date].timeIntervalSince1970, message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        } else {
            @try { [handle seekToEndOfFile]; [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
            @finally { [handle closeFile]; }
        }
    }
}

static NSData *VoIPDerivedState(void) {
    static NSData *state = nil;
    return state ?: [NSData data];
}

static void VoIPSaveDerivedState(NSData *state) {
    static NSData *stored = nil;
    stored = [state copy];
}

static NSString *VoIPHexString(NSData *data) {
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [result appendFormat:@"%02x", bytes[i]];
    }
    return result;
}

@interface VoIPQueue : NSObject <OngoingCallThreadLocalContextQueueWebrtc>
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation VoIPQueue

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.fignyagram.voip", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, (__bridge const void *)self,
                                    (__bridge void *)self, NULL);
    }
    return self;
}

- (void)dispatch:(void (^)(void))f {
    dispatch_async(self.queue, f);
}

- (bool)isCurrent {
    return dispatch_get_specific((__bridge const void *)self) != NULL;
}

- (GroupCallDisposable *)scheduleBlock:(void (^)(void))f after:(double)timeout {
    __block BOOL cancelled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(MAX(0.0, timeout) * NSEC_PER_SEC)),
                   self.queue, ^{
        if (!cancelled) { f(); }
    });
    return [[GroupCallDisposable alloc] initWithBlock:^{
        cancelled = YES;
    }];
}

@end

@interface VoIPBridge () {
    VoipProxyServerWebrtc *_proxy;
    OngoingCallThreadLocalContextWebrtc *_context;
    OngoingCallThreadLocalContextVideoCapturer *_capturer;
    SharedCallAudioDevice *_audioDevice;
    VoIPVideoLayerView *_localRenderView;
    VoIPVideoLayerView *_remoteRenderView;
    GroupCallDisposable *_localVideoOutput;
    GroupCallDisposable *_remoteVideoOutput;
    GroupCallThreadLocalContext *_groupContext;
    OngoingCallThreadLocalContextVideoCapturer *_groupCapturer;
    VoIPVideoLayerView *_groupLocalVideoView;
    UIView *_groupLocalContainer;
    UIView *_groupRemoteContainer;
    NSMutableDictionary<NSString *, GroupCallDisposable *> *_groupRemoteOutputs;
    NSMutableDictionary<NSString *, VoIPVideoLayerView *> *_groupRemoteViews;
    VoIPQueue *_queue;
    NSString *_serverConfig;
    NSString *_customParameters;
    NSArray<NSString *> *_libraryVersions;
    BOOL _allowP2P;
    int32_t _maxLayer;
    BOOL _isBackCamera;
    BOOL _videoRequested;
}
@property(nonatomic, readwrite) NSInteger connectionState;
@property(nonatomic, copy, readwrite) NSString *stateText;
@end



@implementation VoIPBridge

+ (BOOL)engineAvailable {
    // The engine runs as an isolated dynamic framework, so its BoringSSL and
    // webrtc symbols cannot interpose TDLib's OpenSSL 3.
    return YES;
}

+ (instancetype)shared {
    static VoIPBridge *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = [[VoIPQueue alloc] init];
        _serverConfig = @"";
        _customParameters = @"";
        _libraryVersions = @[];
        _connectionState = -1;
        _stateText = @"Ожидание звонка";
    }
    return self;
}

- (void)configureProxyWithHost:(NSString *)host
                          port:(uint16_t)port
                      username:(NSString *)username
                      password:(NSString *)password {
    _proxy = [[VoipProxyServerWebrtc alloc]
        initWithHost:host port:port username:username password:password];
}

- (void)configureCallWithServerConfig:(NSString *)serverConfig
                     customParameters:(NSString *)customParameters
                             allowP2P:(BOOL)allowP2P
                             maxLayer:(int32_t)maxLayer
                       libraryVersions:(NSArray<NSString *> *)libraryVersions {
    _serverConfig = [serverConfig copy] ?: @"";
    _customParameters = [customParameters copy] ?: @"";
    _allowP2P = allowP2P;
    _maxLayer = maxLayer;
    _libraryVersions = [libraryVersions copy] ?: @[];
}

- (NSString *)negotiateVersion {
    NSArray<NSString *> *engineVersions =
        [OngoingCallThreadLocalContextWebrtc versionsWithIncludeReference:NO];
    CallDiagLog(@"engine versions=%@ peerVersions=%@",
                [engineVersions componentsJoinedByString:@","],
                [_libraryVersions componentsJoinedByString:@","]);

    // Order matters: newest first. Only these versions map to InstanceV2Impl in
    // the archive, which carries the real signaling implementation.
    // 7/8/9 hang in this prebuilt engine: signaling is retransmitted forever
    // and the transport never connects.
    NSArray<NSString *> *usable = @[@"13.0.0", @"12.0.0"];
    for (NSString *candidate in usable) {
        if ([engineVersions containsObject:candidate] &&
            [_libraryVersions containsObject:candidate]) {
            return candidate;
        }
    }
    // Unknown peer protocol: use the newest engine version as a last resort.
    NSString *fallback = engineVersions.firstObject ?: @"";
    CallDiagLog(@"engine negotiation: no common version, fallback=%@", fallback);
    return fallback;
}

- (void)configureAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeVoiceChat
                 options:AVAudioSessionCategoryOptionAllowBluetooth |
                         AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                         AVAudioSessionCategoryOptionDefaultToSpeaker
                   error:&error];
    [session setPreferredSampleRate:48000 error:&error];
    [session setPreferredIOBufferDuration:0.01 error:&error];
    [session setActive:YES error:&error];
    CallDiagLog(@"audio session configured error=%@", error);
}

- (BOOL)startCallWithKey:(NSData *)key
              isOutgoing:(BOOL)isOutgoing
                isVideo:(BOOL)isVideo
                servers:(NSArray<NSDictionary *> *)servers
               localView:(UIView *)localView
              remoteView:(UIView *)remoteView {
    // The prebuilt engine can raise Objective-C exceptions for API mismatches
    // between its internal WebRTC revisions. Never let that terminate the app:
    // report the failure and keep the process alive.
    @try {
        return [self startCallImplWithKey:key
                               isOutgoing:isOutgoing
                                 isVideo:isVideo
                                 servers:servers
                                localView:localView
                               remoteView:remoteView];
    } @catch (NSException *exception) {
        CallDiagLog(@"engine exception name=%@ reason=%@", exception.name, exception.reason);
        self.connectionState = 2;
        self.stateText = @"Ошибка запуска аудио-модуля";
        return NO;
    }
}

- (BOOL)startCallImplWithKey:(NSData *)key
              isOutgoing:(BOOL)isOutgoing
                isVideo:(BOOL)isVideo
                servers:(NSArray<NSDictionary *> *)servers
               localView:(UIView *)localView
              remoteView:(UIView *)remoteView {
    if (key.length == 0 || _context != nil) {
        self.stateText = @"Не удалось запустить звонок";
        return NO;
    }

    // Map TDLib CallStateReady.servers exactly like the official client:
    //   - Telegram reflectors: sequential reflectorId starting from 1,
    //     username "reflector", password = hex(peerTag);
    //   - WebRTC servers: reflectorId 0 with STUN/TURN flags and credentials.
    NSMutableArray<NSNumber *> *reflectorIds = [NSMutableArray array];
    for (NSDictionary *server in servers) {
        if (![server[@"rtc"] boolValue]) {
            [reflectorIds addObject:server[@"id"]];
        }
    }
    [reflectorIds sortUsingSelector:@selector(compare:)];
    NSMutableDictionary<NSNumber *, NSNumber *> *idMapping =
        [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < reflectorIds.count; i++) {
        idMapping[reflectorIds[i]] = @(i + 1);
    }

    NSMutableArray<OngoingCallConnectionDescriptionWebrtc *> *connections =
        [NSMutableArray array];
    for (NSDictionary *server in servers) {
        BOOL rtc = [server[@"rtc"] boolValue];
        int32_t port = [server[@"port"] intValue];
        if (port <= 0) { continue; }

        NSArray<NSString *> *ips = @[];
        if ([server[@"ipv4"] isKindOfClass:NSString.class] &&
            [server[@"ipv4"] length] > 0) {
            ips = [ips arrayByAddingObject:server[@"ipv4"]];
        }
        if ([server[@"ipv6"] isKindOfClass:NSString.class] &&
            [server[@"ipv6"] length] > 0) {
            ips = [ips arrayByAddingObject:server[@"ipv6"]];
        }
        if (ips.count == 0) { continue; }

        if (rtc) {
            for (NSString *ip in ips) {
                [connections addObject:
                    [[OngoingCallConnectionDescriptionWebrtc alloc]
                        initWithReflectorId:0
                        hasStun:[server[@"supportsStun"] boolValue]
                        hasTurn:[server[@"supportsTurn"] boolValue]
                        hasTcp:NO
                        ip:ip
                        port:port
                        username:server[@"username"] ?: @""
                        password:server[@"password"] ?: @""]];
            }
        } else {
            uint8_t reflectorId =
                [idMapping[server[@"id"]] unsignedCharValue];
            NSData *peerTag = server[@"peerTag"];
            NSString *password = [peerTag isKindOfClass:NSData.class]
                ? VoIPHexString(peerTag) : @"";
            for (NSString *ip in ips) {
                [connections addObject:
                    [[OngoingCallConnectionDescriptionWebrtc alloc]
                        initWithReflectorId:reflectorId
                        hasStun:NO
                        hasTurn:YES
                        hasTcp:[server[@"tcp"] boolValue]
                        ip:ip
                        port:port
                        username:@"reflector"
                        password:password]];
            }
        }
    }

    if (connections.count == 0) {
        self.stateText = @"Telegram не предоставил подходящих серверов";
        return NO;
    }

    NSString *version = [self negotiateVersion];
    CallDiagLog(@"engine version=%@ keyBytes=%lu servers=%lu outgoing=%d video=%d p2p=%d maxLayer=%d",
                version, (unsigned long)key.length, (unsigned long)connections.count,
                isOutgoing, isVideo, _allowP2P, _maxLayer);
    if (version.length == 0) {
        self.stateText = @"Не найдена совместимая версия WebRTC";
        return NO;
    }

    [OngoingCallThreadLocalContextWebrtc applyServerConfig:_serverConfig];
    // Let the engine configure the session through its own RTCAudioSession
    // wrapper (the missing selectors are supplied by the compatibility
    // category). Fall back to a plain AVAudioSession setup if it throws.
    @try {
        [SharedCallAudioDevice setupAudioSession];
        CallDiagLog(@"engine setupAudioSession ok");
    } @catch (NSException *exception) {
        CallDiagLog(@"engine setupAudioSession exception=%@", exception.reason);
        [self configureAudioSession];
    }
    // enableSystemMute:YES makes the engine mute the microphone while the
    // iPhone's hardware silent switch is engaged, which produced one-way audio
    // (playback fine, microphone silent for the peer).
    _audioDevice = [[SharedCallAudioDevice alloc]
        initWithDisableRecording:NO enableSystemMute:NO];
    [_audioDevice setManualAudioSessionIsActive:YES];

    // Video capture, if requested.
    __weak VoIPBridge *weakSignalSelf = self;
    _context.signalBarsChanged = ^(int32_t bars) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VoIPBridge *strongSelf = weakSignalSelf;
            if (strongSelf.signalBarsHandler) {
                strongSelf.signalBarsHandler((NSInteger)bars);
            }
        });
    };

    if (isVideo) {
        _capturer = [[OngoingCallThreadLocalContextVideoCapturer alloc]
            initWithDeviceId:@"" keepLandscape:NO];

        __weak VoIPBridge *weakSelf = self;
        VoIPVideoLayerView *localRender = [[VoIPVideoLayerView alloc] initWithFrame:CGRectZero];
        localRender.backgroundColor = [UIColor blackColor];
        _localRenderView = localRender;
        [localRender setMirrorAllowed:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf installVideoView:localRender inContainer:localView];
        });
        __block NSInteger localFrameCount = 0;
        _localVideoOutput = [_capturer addVideoOutput:^(CallVideoFrameData *frame) {
            localFrameCount += 1;
            if (localFrameCount == 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (weakSelf.localVideoFirstFrameHandler) { weakSelf.localVideoFirstFrameHandler(); }
                });
            }
            [localRender renderFrame:frame];
        }];
    }

    NSString *base = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Caches/FignyagramVoIP"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    _context = [[OngoingCallThreadLocalContextWebrtc alloc]
        initWithVersion:version
        customParameters:_customParameters
        queue:_queue
        proxy:_proxy
        networkType:OngoingCallNetworkTypeWifi
        dataSaving:OngoingCallDataSavingNever
        derivedState:VoIPDerivedState()
        key:key
        isOutgoing:isOutgoing
        connections:connections
        maxLayer:_maxLayer > 0 ? _maxLayer :
            [OngoingCallThreadLocalContextWebrtc maxLayer]
        allowP2P:_allowP2P
        allowTCP:YES
        enableStunMarking:YES
        logPath:[base stringByAppendingPathComponent:@"call.log"]
        statsLogPath:[base stringByAppendingPathComponent:@"stats.log"]
        sendSignalingData:^(NSData *data) {
            CallDiagLog(@"engine signaling.out bytes=%lu", (unsigned long)data.length);
            if (self.signalingDataHandler) {
                self.signalingDataHandler(data);
            }
        }
        videoCapturer:isVideo ? _capturer : nil
        preferredVideoCodec:@"H264"
        audioInputDeviceId:@""
        audioDevice:_audioDevice
        directConnection:nil];

    __weak VoIPBridge *weakSelf = self;
    _context.stateChanged = ^(OngoingCallStateWebrtc state,
                              OngoingCallVideoStateWebrtc videoState,
                              OngoingCallRemoteVideoStateWebrtc remoteVideoState,
                              OngoingCallRemoteAudioStateWebrtc remoteAudioState,
                              OngoingCallRemoteBatteryLevelWebrtc battery,
                              float level) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VoIPBridge *strongSelf = weakSelf;
            if (!strongSelf) { return; }
            strongSelf.connectionState = state;
            if (state == OngoingCallStateConnected && strongSelf->_capturer != nil && !strongSelf->_videoRequested) {
                [strongSelf->_context requestVideo:strongSelf->_capturer];
                strongSelf->_videoRequested = YES;
                CallDiagLog(@"engine requestVideo on connect");
            }
            CallDiagLog(@"engine state=%ld video=%ld remoteVideo=%ld remoteAudio=%ld battery=%ld level=%.3f",
                        (long)state, (long)videoState, (long)remoteVideoState,
                        (long)remoteAudioState, (long)battery, level);
            switch (state) {
                case OngoingCallStateInitializing:
                    strongSelf.stateText = @"Соединение…";
                    break;
                case OngoingCallStateConnected:
                    strongSelf.stateText = @"Звонок подключён";
                    break;
                case OngoingCallStateReconnecting:
                    strongSelf.stateText = @"Переподключение…";
                    break;
                case OngoingCallStateFailed:
                    strongSelf.stateText = @"Ошибка соединения";
                    break;
            }
            if (strongSelf.stateHandler) {
                strongSelf.stateHandler(state);
            }
            if (strongSelf.remoteAudioHandler) {
                strongSelf.remoteAudioHandler(remoteAudioState == OngoingCallRemoteAudioStateMuted);
            }
        });
    };

    if (isVideo) {
        VoIPVideoLayerView *remoteRender = [[VoIPVideoLayerView alloc] initWithFrame:CGRectZero];
        remoteRender.backgroundColor = [UIColor blackColor];
        _remoteRenderView = remoteRender;
        [remoteRender setMirrorAllowed:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf installVideoView:remoteRender inContainer:remoteView];
        });
        __block NSInteger remoteFrameCount = 0;
        _remoteVideoOutput = [_context addVideoOutputWithIsIncoming:YES sink:^(CallVideoFrameData *frame) {
            remoteFrameCount += 1;
            if (remoteFrameCount == 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (weakSelf.remoteVideoFirstFrameHandler) { weakSelf.remoteVideoFirstFrameHandler(); }
                });
            }
            if (remoteFrameCount == 1 || remoteFrameCount % 120 == 0) {
                CallDiagLog(@"remote video frames=%ld", (long)remoteFrameCount);
            }
            [remoteRender renderFrame:frame];
        }];
        [_context requestVideo:_capturer];
        _videoRequested = YES;
    }

    self.connectionState = OngoingCallStateInitializing;
    self.stateText = @"Соединение…";
    return YES;
}

- (void)installVideoView:(UIView *)view inContainer:(UIView *)container {
    if (!container) {
        CallDiagLog(@"video view install skipped: container=nil class=%@", NSStringFromClass(view.class));
        return;
    }
    CallDiagLog(@"video view install class=%@ container=%@ bounds=%@",
                NSStringFromClass(view.class), NSStringFromClass(container.class),
                NSStringFromCGRect(container.bounds));
    if ([view respondsToSelector:@selector(setOnFirstFrameReceived:)]) {
        __weak UIView *weakView = view;
        [(id<OngoingCallThreadLocalContextWebrtcVideoView>)view setOnFirstFrameReceived:^(float aspect) {
            CallDiagLog(@"video first frame class=%@ aspect=%.2f frame=%@ hidden=%d alpha=%.2f",
                        NSStringFromClass(weakView.class), aspect,
                        NSStringFromCGRect(weakView.frame), weakView.isHidden, weakView.alpha);
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CallDiagLog(@"video layout check class=%@ frame=%@ superview=%@ hidden=%d alpha=%.2f",
                    NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
                    NSStringFromClass(view.superview.class), view.isHidden, view.alpha);
    });
    view.frame = container.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                            UIViewAutoresizingFlexibleHeight;
    [container addSubview:view];
}

- (void)receiveSignalingData:(NSData *)data {
    if (data.length > 0 && _context != nil) {
        CallDiagLog(@"engine signaling.in bytes=%lu", (unsigned long)data.length);
        [_context addSignalingData:data];
    } else {
        CallDiagLog(@"engine signaling.in dropped (context=%@) bytes=%lu",
                    _context ? @"yes" : @"nil", (unsigned long)data.length);
    }
}

- (void)stopCall {
    OngoingCallThreadLocalContextWebrtc *context = _context;
    _context = nil;
    if (context) {
        [context beginTermination];
        [context stop:^(NSString *debugLog, int64_t sentWifi,
                        int64_t receivedWifi, int64_t sentMobile,
                        int64_t receivedMobile) {
            VoIPSaveDerivedState([context getDerivedState]);
        }];
    }
    _capturer = nil;
    _videoRequested = NO;
    [_audioDevice setManualAudioSessionIsActive:YES];
    _audioDevice = nil;
    self.connectionState = -1;
    self.stateText = @"Звонок завершён";
}

// MARK: - Group calls

- (BOOL)beginGroupCallWithGroupCallId:(int64_t)groupCallId conference:(BOOL)isConference {
    [self stopGroupCall];
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/FignyagramVoIP"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];

    [self configureAudioSession];
    SharedCallAudioDevice *audioDevice = [[SharedCallAudioDevice alloc] initWithDisableRecording:NO enableSystemMute:NO];
    [audioDevice setManualAudioSessionIsActive:NO];

    __weak VoIPBridge *weakSelf = self;
    _groupContext = [[GroupCallThreadLocalContext alloc]
        initWithQueue:_queue
        networkStateUpdated:^(GroupCallNetworkState state) {
            dispatch_async(dispatch_get_main_queue(), ^{
                VoIPBridge *strongSelf = weakSelf;
                if (strongSelf.groupStateHandler) {
                    strongSelf.groupStateHandler(state.isConnected);
                }
            });
        }
        audioLevelsUpdated:^(NSArray<NSNumber *> *levels) {
            dispatch_async(dispatch_get_main_queue(), ^{
                VoIPBridge *strongSelf = weakSelf;
                if (strongSelf.groupAudioLevelsHandler) {
                    strongSelf.groupAudioLevelsHandler(levels);
                }
            });
        }
        activityUpdated:^(NSArray<NSNumber *> *activity) {
        }
        inputDeviceId:@""
        outputDeviceId:@""
        videoCapturer:nil
        requestMediaChannelDescriptions:^id<OngoingGroupCallMediaChannelDescriptionTask>(NSArray<NSNumber *> *ssrcs, void (^completion)(NSArray<OngoingGroupCallMediaChannelDescription *> *)) {
            void (^handler)(NSArray<NSNumber *> *, void (^)(NSArray<OngoingGroupCallMediaChannelDescription *> *)) = weakSelf.groupMediaChannelsRequest;
            if (handler) {
                handler(ssrcs, completion);
            } else {
                completion(@[]);
            }
            return [[GroupCallDisposable alloc] initWithBlock:^{
            }];
        }
        requestCurrentTime:^id<OngoingGroupCallBroadcastPartTask>(void (^completion)(int64_t)) {
            void (^handler)(void (^)(int64_t)) = weakSelf.groupCurrentTimeRequest;
            if (handler) {
                handler(completion);
            } else {
                completion((int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0));
            }
            return [[GroupCallDisposable alloc] initWithBlock:^{
            }];
        }
        requestAudioBroadcastPart:^id<OngoingGroupCallBroadcastPartTask>(int64_t timestampMs, int64_t durationMs, void (^completion)(OngoingGroupCallBroadcastPart *)) {
            void (^handler)(int64_t, int64_t, void (^)(OngoingGroupCallBroadcastPart *)) = weakSelf.groupAudioPartRequest;
            if (handler) {
                handler(timestampMs, durationMs, completion);
            } else {
                completion(nil);
            }
            return [[GroupCallDisposable alloc] initWithBlock:^{
            }];
        }
        requestVideoBroadcastPart:^id<OngoingGroupCallBroadcastPartTask>(int64_t timestampMs, int64_t durationMs, int32_t channelId, OngoingGroupCallRequestedVideoQuality quality, void (^completion)(OngoingGroupCallBroadcastPart *)) {
            completion(nil);
            return [[GroupCallDisposable alloc] initWithBlock:^{
            }];
        }
        outgoingAudioBitrateKbit:32
        videoContentType:OngoingGroupCallVideoContentTypeNone
        enableNoiseSuppression:YES
        disableAudioInput:NO
        enableSystemMute:NO
        prioritizeVP8:NO
        logPath:[base stringByAppendingPathComponent:@"group.log"]
        statsLogPath:[base stringByAppendingPathComponent:@"group_stats.log"]
        onMutedSpeechActivityDetected:nil
        audioDevice:audioDevice
        isConference:isConference
        isActiveByDefault:YES
        encryptDecrypt:^NSData *(NSData *data, int64_t ssrc, BOOL encrypt, int32_t channel) {
            NSData * (^handler)(NSData *, int64_t, BOOL, int32_t) = weakSelf.groupEncryptDecrypt;
            return handler ? handler(data, ssrc, encrypt, channel) : data;
        }
        useReferenceImpl:NO];
    if (_groupContext == nil) {
        return NO;
    }
    CallDiagLog(@"group call engine started id=%lld conference=%d", (long long)groupCallId, isConference);
    return YES;
}

- (void)emitGroupJoinPayload:(void (^)(NSString *, uint32_t))completion {
    if (_groupContext == nil) {
        completion(@"", 0);
        return;
    }
    [_groupContext emitJoinPayload:completion];
}

- (void)setGroupJoinPayload:(NSString *)payload {
    [_groupContext setJoinResponsePayload:payload];
}

- (void)setGroupCallMuted:(BOOL)muted {
    [_groupContext setIsMuted:muted];
}

- (void)stopGroupCall {
    if (_groupContext == nil) { return; }
    GroupCallThreadLocalContext *context = _groupContext;
    _groupContext = nil;
    for (GroupCallDisposable *output in _groupRemoteOutputs.allValues) { [output dispose]; }
    [_groupRemoteOutputs removeAllObjects];
    [_groupLocalVideoView removeFromSuperview];
    _groupLocalVideoView = nil;
    _groupCapturer = nil;
    [_groupRemoteViews.allValues makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [_groupRemoteViews removeAllObjects];
    [context stop:^{
    }];
    CallDiagLog(@"group call engine stopped");
}

- (void)enableGroupVideoWithLocalView:(UIView *)localView remoteView:(UIView *)remoteView {
    if (_groupContext == nil) { return; }
    _groupLocalContainer = localView;
    _groupRemoteContainer = remoteView;
    if (_groupCapturer == nil) {
        _groupCapturer = [[OngoingCallThreadLocalContextVideoCapturer alloc] initWithDeviceId:@"" keepLandscape:NO];
    }
    if (_groupLocalVideoView == nil) {
        VoIPVideoLayerView *render = [[VoIPVideoLayerView alloc] initWithFrame:CGRectZero];
        render.backgroundColor = [UIColor blackColor];
        _groupLocalVideoView = render;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self installVideoView:render inContainer:localView];
        });
        __weak VoIPBridge *weakSelf = self;
        [_groupCapturer addVideoOutput:^(CallVideoFrameData *frame) {
            [weakSelf renderGroupLocalFrame:frame];
        }];
    }
    [_groupContext requestVideo:_groupCapturer completion:^(NSString *endpointId, uint32_t ssrc) {
        CallDiagLog(@"group video requested endpoint=%@ ssrc=%u", endpointId, ssrc);
    }];
}

- (void)renderGroupLocalFrame:(CallVideoFrameData *)frame {
    [_groupLocalVideoView renderFrame:frame];
}

- (void)setGroupVideoEnabled:(BOOL)enabled {
    [_groupCapturer setIsVideoEnabled:enabled];
}

- (void)addGroupRemoteVideoForEndpoint:(NSString *)endpointId {
    if (_groupContext == nil || endpointId.length == 0) { return; }
    if (_groupRemoteOutputs[endpointId] != nil) { return; }
    VoIPVideoLayerView *render = [[VoIPVideoLayerView alloc] initWithFrame:CGRectZero];
    render.backgroundColor = [UIColor blackColor];
    if (_groupRemoteViews == nil) {
        _groupRemoteViews = [NSMutableDictionary dictionary];
    }
    _groupRemoteViews[endpointId] = render;
    UIView *container = _groupRemoteContainer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (container != nil) {
            [self installVideoView:render inContainer:container];
        }
    });
    GroupCallDisposable *output = [_groupContext addVideoOutputWithEndpointId:endpointId sink:^(CallVideoFrameData *frame) {
        [render renderFrame:frame];
    }];
    if (_groupRemoteOutputs == nil) {
        _groupRemoteOutputs = [NSMutableDictionary dictionary];
    }
    _groupRemoteOutputs[endpointId] = output;
    CallDiagLog(@"group remote video attached endpoint=%@", endpointId);
}


- (void)setMicMute:(BOOL)mute {
    [_context setIsMuted:mute];
}

- (void)setVideoFillsScreen:(BOOL)fill {
    [_localRenderView setFillsScreen:fill];
    [_remoteRenderView setFillsScreen:fill];
}

- (void)setVideoFlip:(BOOL)flip {
    [_localRenderView setFlip:flip];
    [_remoteRenderView setFlip:flip];
}

- (void)setVideoRotationOffset:(NSInteger)steps {
    [_localRenderView setRotationOffset:steps];
    [_remoteRenderView setRotationOffset:steps];
    [_groupLocalVideoView setRotationOffset:steps];
}

- (void)setVideoEnabled:(BOOL)enabled {
    if (enabled) {
        if (_context && _capturer && !_videoRequested) {
            [_context requestVideo:_capturer];
            _videoRequested = YES;
        }
        [_capturer setIsVideoEnabled:YES];
    } else {
        [_capturer setIsVideoEnabled:NO];
        if (_context) {
            [_context disableVideo];
            _videoRequested = NO;
        }
    }
}

- (void)switchCamera {
    if (!_capturer) { return; }
    _isBackCamera = !_isBackCamera;
    [_capturer switchVideoInput:_isBackCamera ? @"back" : @""];
}

- (BOOL)isBackCamera {
    return _isBackCamera;
}

@end
