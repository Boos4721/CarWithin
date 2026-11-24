#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <assert.h>
#import "../Companion/NinebotProjectionProbe/ProbeRuntime.h"

@interface CWRuntimeFixture : NSObject
@property(nonatomic) NSInteger recordCount;
@property(nonatomic) BOOL lastStopAfter;
@property(nonatomic, strong) id lastTarget;
- (void)recordVideo:(id)target stopAfter:(BOOL)stopAfter;
+ (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image;
@end
@implementation CWRuntimeFixture
- (void)recordVideo:(id)target stopAfter:(BOOL)stopAfter {
    self.recordCount++; self.lastStopAfter = stopAfter; self.lastTarget = target;
}
+ (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image { (void)image; return NULL; }
@end
@interface CWRuntimeChild : CWRuntimeFixture @end
@implementation CWRuntimeChild @end

static void (*CWForward)(id, SEL, id, BOOL);
static NSInteger CWHookCalls;
static void CWFixtureHook(id object, SEL selector, id target, BOOL stopAfter) {
    assert(CWForward != NULL);
    CWHookCalls++;
    CWForward(object, selector, target, stopAfter);
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
        NSObject *target = [NSObject new];
        CWRuntimeChild *child = [CWRuntimeChild new];
        [child recordVideo:target stopAfter:YES];
        assert(CWHookCalls == 1 && child.recordCount == 1 && child.lastTarget == target && child.lastStopAfter);
        [child recordVideo:nil stopAfter:NO];
        assert(CWHookCalls == 2 && child.recordCount == 2 && child.lastTarget == nil && !child.lastStopAfter);
        CWRuntimeFixture *parent = [CWRuntimeFixture new];
        [parent recordVideo:target stopAfter:NO];
        assert(CWHookCalls == 2 && parent.recordCount == 1);
        Method pixel = class_getClassMethod(CWRuntimeFixture.class, @selector(pixelBufferFromCGImage:));
        assert(method_getNumberOfArguments(pixel) == 3 && CWType(pixel, 2, @encode(CGImageRef)));
        char *returnType = method_copyReturnType(pixel);
        assert(strcmp(returnType, @encode(CVPixelBufferRef)) == 0); free(returnType);
        puts("Ninebot probe runtime: signature checks, early forwarding publication, inherited method isolation and argument forwarding passed");
    }
    return 0;
}
