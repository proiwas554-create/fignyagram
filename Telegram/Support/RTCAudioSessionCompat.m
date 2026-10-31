#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// TgVoipWebrtc calls -[RTCAudioSession setConfiguration:active:error:disableRecording:]
// but the class that wins registration in our process does not implement it.
// Add the method to every registered class with that name and configure
// AVAudioSession directly (equivalent behaviour for the call audio path).
static BOOL FNYSetConfiguration(id self, SEL _cmd, id configuration,
                                BOOL active, NSError **error, BOOL disableRecording) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *localError = nil;
    NSString *category = nil;
    NSString *mode = nil;
    NSNumber *options = nil;
    @try {
        category = [configuration valueForKey:@"category"];
        mode = [configuration valueForKey:@"mode"];
        options = [configuration valueForKey:@"categoryOptions"];
    } @catch (__unused NSException *exception) {}
    if (category.length) {
        [session setCategory:category
                        mode:mode.length ? mode : AVAudioSessionModeVoiceChat
                     options:options.unsignedIntegerValue
                       error:&localError];
    }
    [session setActive:active error:&localError];
    if (localError && error) { *error = localError; }
    return localError == nil;
}

// Replaces the engine's configure implementation so it never calls the missing
// 4-argument selector on an instance from another image.
static BOOL FNYConfigureWebRTCSession(id self, SEL _cmd, NSError **error, BOOL disableRecording) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *localError = nil;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeVoiceChat
                 options:AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionDefaultToSpeaker
                   error:&localError];
    [session setActive:YES error:&localError];
    if (localError && error) { *error = localError; }
    return localError == nil;
}

__attribute__((constructor))
static void FNYInstallAudioSessionCompat(void) {
    SEL selector = NSSelectorFromString(@"setConfiguration:active:error:disableRecording:");
    const char *types = "B@:@B^@B";
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) { return; }
    Class *classes = (Class *)malloc(sizeof(Class) * classCount);
    classCount = objc_getClassList(classes, classCount);
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name || strcmp(name, "RTCAudioSession") != 0) { continue; }
        if (!class_getInstanceMethod(cls, selector)) {
            class_addMethod(cls, selector, (IMP)FNYSetConfiguration, types);
        }
        SEL configure = NSSelectorFromString(@"configureWebRTCSession:disableRecording:");
        Method existing = class_getInstanceMethod(cls, configure);
        if (existing) {
            method_setImplementation(existing, (IMP)FNYConfigureWebRTCSession);
        }
    }
    free(classes);

}
