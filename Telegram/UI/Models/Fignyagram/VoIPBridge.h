#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <TgVoipWebrtc/OngoingCallThreadLocalContext.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C++ bridge over the Telegram VoIP engine
/// (OngoingCallThreadLocalContextWebrtc from TgVoipWebrtc.xcframework).
/// Media: real tgcalls/WebRTC. Signaling: TDLib (sendCallSignalingData /
/// updateNewCallSignalingData) bridged through signalingDataHandler and
/// receiveSignalingData:.
@interface VoIPBridge : NSObject

+ (instancetype)shared;

/// NO when the compiled-in implementation carries no media engine.
+ (BOOL)engineAvailable;

/// Optional SOCKS5 proxy for relay connections.
- (void)configureProxyWithHost:(NSString *)host
                          port:(uint16_t)port
                      username:(NSString *)username
                      password:(NSString *)password;

/// Server config / custom parameters / protocol negotiation, from
/// TDLib CallStateReady (config, customParameters, allowP2p, protocol).
- (void)configureCallWithServerConfig:(NSString *)serverConfig
                     customParameters:(NSString *)customParameters
                             allowP2P:(BOOL)allowP2P
                             maxLayer:(int32_t)maxLayer
                       libraryVersions:(NSArray<NSString *> *)libraryVersions;

/// Starts an audio or video 1-on-1 call.
/// - key:      256-byte encryption key (CallStateReady.encryptionKey).
/// - servers:  dictionaries with keys:
///             "id" (NSNumber), "ipv4"/"ipv6" (NSString), "port" (NSNumber),
///             "tcp" (NSNumber bool), "rtc" (NSNumber bool),
///             "supportsStun"/"supportsTurn" (NSNumber bool),
///             "username"/"password" (NSString),
///             "peerTag" (NSData, 16 bytes, reflectors only).
/// - localView / remoteView: container UIViews for camera preview and the
///   remote video; nil for audio calls.
- (BOOL)startCallWithKey:(NSData *)key
              isOutgoing:(BOOL)isOutgoing
                 isVideo:(BOOL)isVideo
                 servers:(NSArray<NSDictionary *> *)servers
               localView:(nullable UIView *)localView
              remoteView:(nullable UIView *)remoteView;

/// Incoming signaling data from TDLib updateNewCallSignalingData.
- (void)receiveSignalingData:(NSData *)data;

/// Outgoing signaling data produced by the engine; the owner must forward it
/// via TDLib sendCallSignalingData.
@property (nonatomic, copy, nullable) void (^signalingDataHandler)(NSData *data);

/// Engine state callback (OngoingCallStateWebrtc values) on the main thread.
@property (nonatomic, copy, nullable) void (^stateHandler)(NSInteger state);
/// YES when the peer's microphone is muted.
@property (nonatomic, copy, nullable) void (^remoteAudioHandler)(BOOL muted);
/// Called once when the first video frame of each stream arrives.
@property (nonatomic, copy, nullable) void (^remoteVideoFirstFrameHandler)(void);
@property (nonatomic, copy, nullable) void (^localVideoFirstFrameHandler)(void);
/// Connection quality, 0...4 (engine's signal bars).
@property (nonatomic, copy, nullable) void (^signalBarsHandler)(NSInteger bars);

- (void)stopCall;

// MARK: - Group calls
// The engine needs synchronous media crypto, so the Swift side provides these
// handlers (it bridges TDLib's async encrypt/decrypt synchronously).

@property (nonatomic, copy, nullable) void (^groupStateHandler)(BOOL connected);
@property (nonatomic, copy, nullable) void (^groupAudioLevelsHandler)(NSArray<NSNumber *> *levels);
@property (nonatomic, copy, nullable) void (^groupMediaChannelsRequest)(
    NSArray<NSNumber *> *ssrcs,
    void (^completion)(NSArray<OngoingGroupCallMediaChannelDescription *> *descriptions));
@property (nonatomic, copy, nullable) void (^groupCurrentTimeRequest)(void (^completion)(int64_t timeMs));
@property (nonatomic, copy, nullable) void (^groupAudioPartRequest)(
    int64_t timestampMs,
    int64_t durationMs,
    void (^completion)(OngoingGroupCallBroadcastPart *part));
@property (nonatomic, copy, nullable) NSData * (^groupEncryptDecrypt)(
    NSData *data, int64_t ssrc, BOOL encrypt, int32_t channel);

- (BOOL)beginGroupCallWithGroupCallId:(int64_t)groupCallId conference:(BOOL)isConference;
- (void)emitGroupJoinPayload:(void (^)(NSString *payload, uint32_t ssrc))completion;
- (void)setGroupJoinPayload:(NSString *)payload;
- (void)setGroupCallMuted:(BOOL)muted;
- (void)stopGroupCall;
- (void)enableGroupVideoWithLocalView:(UIView *)localView remoteView:(UIView *)remoteView;
- (void)addGroupRemoteVideoForEndpoint:(NSString *)endpointId;
- (void)setGroupVideoEnabled:(BOOL)enabled;

- (void)setMicMute:(BOOL)mute;
/// Toggles outgoing video on/off.
- (void)setVideoEnabled:(BOOL)enabled;
/// Extra 90-degree rotation applied on top of the automatic orientation.
- (void)setVideoRotationOffset:(NSInteger)steps;
/// Mirrors the rendered video horizontally (independent of the automatic fix).
- (void)setVideoFlip:(BOOL)flip;
/// YES fills the screen (crops edges), NO fits the whole frame.
- (void)setVideoFillsScreen:(BOOL)fill;
/// Switches between the front and the back camera.
- (void)switchCamera;
/// YES when the back camera is currently selected.
@property (nonatomic, readonly) BOOL isBackCamera;

/// OngoingCallStateWebrtc; -1 when the engine is not running.
@property (nonatomic, readonly) NSInteger connectionState;
@property (nonatomic, readonly) NSString *stateText;

@end

NS_ASSUME_NONNULL_END
