#import "RTCMutableI420Buffer.h"
#import "RTCMacros.h"
#import <string.h>
#import <stdlib.h>

// Concrete RTCMutableI420Buffer class (implementation absent from the M123
// source tree but used by RTCCVPixelBuffer). Minimal own-buffer version.
@interface RTC_OBJC_TYPE (RTCMutableI420Buffer) : NSObject <RTC_OBJC_TYPE(RTCI420Buffer), RTC_OBJC_TYPE(RTCMutableYUVPlanarBuffer)> {
    int _width;
    int _height;
    int _chromaWidth;
    int _chromaHeight;
    int _strideY;
    int _strideU;
    int _strideV;
    uint8_t *_y;
    uint8_t *_u;
    uint8_t *_v;
}
@end

@implementation RTC_OBJC_TYPE (RTCMutableI420Buffer)

- (instancetype)initWithWidth:(int)width height:(int)height {
    return [self initWithWidth:width height:height dataY:NULL dataU:NULL dataV:NULL];
}

- (instancetype)initWithWidth:(int)width height:(int)height
                        dataY:(const uint8_t *)dataY
                        dataU:(const uint8_t *)dataU
                        dataV:(const uint8_t *)dataV {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _chromaWidth = (width + 1) / 2;
        _chromaHeight = (height + 1) / 2;
        _strideY = width;
        _strideU = _chromaWidth;
        _strideV = _chromaWidth;
        _y = (uint8_t *)calloc((size_t)width * height, 1);
        _u = (uint8_t *)calloc((size_t)_chromaWidth * _chromaHeight, 1);
        _v = (uint8_t *)calloc((size_t)_chromaWidth * _chromaHeight, 1);
        if (dataY) { memcpy(_y, dataY, (size_t)width * height); }
        if (dataU) { memcpy(_u, dataU, (size_t)_chromaWidth * _chromaHeight); }
        if (dataV) { memcpy(_v, dataV, (size_t)_chromaWidth * _chromaHeight); }
    }
    return self;
}

- (void)dealloc {
    free(_y); free(_u); free(_v);
}

- (int)width { return _width; }
- (int)height { return _height; }
- (int)chromaWidth { return _chromaWidth; }
- (int)chromaHeight { return _chromaHeight; }
- (const uint8_t *)dataY { return _y; }
- (const uint8_t *)dataU { return _u; }
- (const uint8_t *)dataV { return _v; }
- (uint8_t *)mutableDataY { return _y; }
- (uint8_t *)mutableDataU { return _u; }
- (uint8_t *)mutableDataV { return _v; }
- (int)strideY { return _strideY; }
- (int)strideU { return _strideU; }
- (int)strideV { return _strideV; }

- (id<RTC_OBJC_TYPE(RTCI420Buffer)>)toI420 { return (id<RTC_OBJC_TYPE(RTCI420Buffer)>)(id)self; }

@end
