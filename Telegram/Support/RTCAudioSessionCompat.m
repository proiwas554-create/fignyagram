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

__attribute__((constructor))
static void FNYInstallAudioSessionCompat(void) {
    SEL selector = NSSelectorFromString(@"setConfiguration:active:error:disableRecording:");
    const char *types = "B@:@B^@B";
    unsigned int imageCount = 0;
    const char **images = objc_copyImageNames(&imageCount);
    for (unsigned int i = 0; i < imageCount; i++) {
        unsigned int classCount = 0;
        const char **names = objc_copyClassNamesForImage(images[i], &classCount);
        for (unsigned int j = 0; j < classCount; j++) {
            if (strcmp(names[j], "RTCAudioSession") != 0) { continue; }
            Class cls = objc_getClass(names[j]);
            if (cls && !class_getInstanceMethod(cls, selector)) {
                class_addMethod(cls, selector, (IMP)FNYSetConfiguration, types);
            }
        }
        if (names) { free(names); }
    }
    if (images) { free(images); }
}
