#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <assert.h>
#import "../Companion/NinebotProjectionProbe/ProbeRuntime.h"

@interface CWRuntimeFixture : NSObject
@property(nonatomic) NSInteger recordCount;
@property(nonatomic) BOOL lastStopAfter;
@property(nonatomic, strong) id lastTarget;
@property(nonatomic, strong) id lastEncoder;
@property(nonatomic, strong) id lastData;
@property(nonatomic) NSInteger encodedCount;
- (void)recordVideo:(id)target stopAfter:(BOOL)stopAfter;
- (void)NBH264Encoder:(id)encoder didEncodeImageWithData:(id)data;
+ (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image;
@end
@implementation CWRuntimeFixture
- (void)recordVideo:(id)target stopAfter:(BOOL)stopAfter {
    self.recordCount++; self.lastStopAfter = stopAfter; self.lastTarget = target;
}
- (void)NBH264Encoder:(id)encoder didEncodeImageWithData:(id)data {
    self.lastEncoder = encoder; self.lastData = data; self.encodedCount++;
}
+ (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image { (void)image; return NULL; }
@end
@interface CWRuntimeChild : CWRuntimeFixture @end
@implementation CWRuntimeChild @end

static void (*CWForward)(id, SEL, id, BOOL);
static NSInteger CWHookCalls;
static void (*CWEncodedForward)(id, SEL, id, id);
static NSInteger CWEncodedCalls;
static void CWFixtureHook(id object, SEL selector, id target, BOOL stopAfter) {
    assert(CWForward != NULL);
    CWHookCalls++;
    CWForward(object, selector, target, stopAfter);
}
static void CWEncodedFixtureHook(id object, SEL selector, id encoder, id data) {
    assert(CWEncodedForward != NULL); CWEncodedCalls++;
    CWEncodedForward(object, selector, encoder, data);
}

int main(void) {
    @autoreleasepool {
        SEL selector = @selector(recordVideo:stopAfter:);
        Method base = class_getInstanceMethod(CWRuntimeFixture.class, selector);
        assert(CWReturns(base, 'v') && CWType(base, 2, "@"));
        assert(CWType(base, 3, @encode(BOOL)));
        assert(!CWType(base, 2, @encode(CGImageRef)) && !CWReturns(base, '^'));
        IMP baseImplementation = method_getImplementation(base);
        IMP replaced = CWReplace(CWRuntimeChild.class, selector, (IMP)CWFixtureHook, (IMP *)&CWForward);
        assert(replaced == baseImplementation && CWForward != NULL);
        assert(method_getImplementation(class_getInstanceMethod(CWRuntimeFixture.class, selector)) == baseImplementation);
        assert([CWImplementationStatus(CWRuntimeChild.class, selector, (IMP)CWFixtureHook, YES) isEqual:@"active"]);
        assert([CWImplementationStatus(CWRuntimeFixture.class, selector, (IMP)CWFixtureHook, YES) isEqual:@"replaced"]);
        assert([CWImplementationStatus(Nil, selector, (IMP)CWFixtureHook, NO) isEqual:@"notInstalled"]);
        NSObject *target = [NSObject new];
        CWRuntimeChild *child = [CWRuntimeChild new];
        [child recordVideo:target stopAfter:YES];
        assert(CWHookCalls == 1 && child.recordCount == 1 && child.lastTarget == target && child.lastStopAfter);
        [child recordVideo:nil stopAfter:NO];
        assert(CWHookCalls == 2 && child.recordCount == 2 && child.lastTarget == nil && !child.lastStopAfter);
        CWRuntimeFixture *parent = [CWRuntimeFixture new];
        [parent recordVideo:target stopAfter:NO];
        assert(CWHookCalls == 2 && parent.recordCount == 1);
        SEL encodedSelector = @selector(NBH264Encoder:didEncodeImageWithData:);
        Method encoded = class_getInstanceMethod(CWRuntimeFixture.class, encodedSelector);
        assert(method_getNumberOfArguments(encoded) == 4 && CWReturns(encoded, 'v')
            && CWType(encoded, 2, "@") && CWType(encoded, 3, "@"));
        CWReplace(CWRuntimeChild.class, encodedSelector, (IMP)CWEncodedFixtureHook, (IMP *)&CWEncodedForward);
        NSData *data = [@"fixture" dataUsingEncoding:NSUTF8StringEncoding];
        [child NBH264Encoder:target didEncodeImageWithData:data];
        assert(CWEncodedCalls == 1 && child.encodedCount == 1 && child.lastEncoder == target && child.lastData == data);
        [child NBH264Encoder:nil didEncodeImageWithData:nil];
        assert(CWEncodedCalls == 2 && child.encodedCount == 2 && child.lastEncoder == nil && child.lastData == nil);
        Method pixel = class_getClassMethod(CWRuntimeFixture.class, @selector(pixelBufferFromCGImage:));
        assert(method_getNumberOfArguments(pixel) == 3 && CWType(pixel, 2, @encode(CGImageRef)));
        char *returnType = method_copyReturnType(pixel);
        assert(strcmp(returnType, @encode(CVPixelBufferRef)) == 0); free(returnType);
        method_setImplementation(class_getInstanceMethod(CWRuntimeChild.class, selector), baseImplementation);
        assert([CWImplementationStatus(CWRuntimeChild.class, selector, (IMP)CWFixtureHook, YES) isEqual:@"replaced"]);
        puts("Ninebot probe runtime: signature checks, hook replacement detection, early forwarding publication, inherited isolation and record/encoded argument forwarding passed");
    }
    return 0;
}
