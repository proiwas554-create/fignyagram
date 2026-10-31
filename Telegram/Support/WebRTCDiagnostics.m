#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Diagnostic-only shim: verifies that the WebRTC classes shipped in
// TgVoipWebrtc respond to the selectors our call path expects. It never
// swizzles behaviour (a fake nativeSdpVideoFormat would silently break SDP),
// it just records missing selectors so a real ABI mismatch is visible in logs.
static void FNYLog(NSString *message) {
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:@"call_diag.log"];
    NSString *line = [NSString stringWithFormat:@"[webrtc-shim] %@\n", message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}

__attribute__((constructor))
static void FNYCheckWebRTCSelectors(void) {
    NSArray<NSString *> *classes = @[@"RTCAudioSession", @"RTCVideoCodecInfo", @"RTCEncodedImage"];
    NSArray<NSString *> *selectors = @[@"configureWebRTCSession:error:",
                                       @"configureWebRTCSession:disableRecording:",
                                       @"setConfiguration:active:error:disableRecording:",
                                       @"nativeSdpVideoFormat",
                                       @"initWithNativeEncodedImage:"];
    for (NSString *className in classes) {
        Class cls = NSClassFromString(className);
        if (!cls) { FNYLog([NSString stringWithFormat:@"class %@ not found", className]); continue; }
        for (NSString *name in selectors) {
            SEL sel = NSSelectorFromString(name);
            BOOL instance = [cls instancesRespondToSelector:sel];
            BOOL meta = [cls respondsToSelector:sel];
            if (!instance && !meta) {
                FNYLog([NSString stringWithFormat:@"%@ missing %@", className, name]);
            } else {
                FNYLog([NSString stringWithFormat:@"%@ ok %@ instance=%d", className, name, instance]);
            }
        }
    }
}
