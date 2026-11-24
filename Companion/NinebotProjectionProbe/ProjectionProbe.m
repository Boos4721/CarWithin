// Original CarWithin diagnostic companion. Observe only; never invoke vehicle commands.
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <limits.h>
#import "ProbeRuntime.h"

static NSLock *CWLock;
static NSMutableArray<NSDictionary *> *CWEvents;
static NSMutableDictionary<NSString *, NSNumber *> *CWHooks;
static NSUUID *CWSession;
static double CWStart;
static NSInteger CWFrames;
static NSMutableDictionary<NSString *, NSNumber *> *CWCounters;
static NSMutableDictionary<NSString *, NSDictionary *> *CWObservations;
static void (*CWOriginalRecord)(id, SEL, id, BOOL);
static void (*CWOriginalStop)(id, SEL);
static CVPixelBufferRef (*CWOriginalPixelClass)(id, SEL, CGImageRef);
static CVPixelBufferRef (*CWOriginalPixelInstance)(id, SEL, CGImageRef);
static CVPixelBufferRef (*CWOriginalMjpegClass)(id, SEL, CGImageRef);
static CVPixelBufferRef (*CWOriginalMjpegInstance)(id, SEL, CGImageRef);
static void (*CWOriginalEncoded)(id, SEL, id, id);
static void (*CWOriginalAction)(id, SEL, SEL, id, UIEvent *);

static void CWEvent(NSString *kind, NSString *detail) {
    if (!kind || !detail) return;
    if (detail.length > 120) detail = [detail substringToIndex:120];
    [CWLock lock];
    [CWEvents addObject:@{@"elapsed": @(MAX(0, NSProcessInfo.processInfo.systemUptime - CWStart)),
                         @"kind": kind, @"detail": detail}];
    if (CWEvents.count > 80) [CWEvents removeObjectsInRange:NSMakeRange(0, CWEvents.count - 80)];
    [CWLock unlock];
}

static BOOL CWHooked(NSString *key) {
    [CWLock lock]; BOOL installed = [CWHooks[key] boolValue]; [CWLock unlock];
    return installed;
}
static void CWSetHook(NSString *key, BOOL value) {
    [CWLock lock]; CWHooks[key] = @(value); [CWLock unlock];
}
static BOOL CWIncrement(NSString *key) {
    [CWLock lock];
    NSInteger previous = [CWCounters[key] integerValue];
    CWCounters[key] = @(MIN(INT_MAX, previous + 1));
    [CWLock unlock];
    return previous == 0;
}
static void CWObservation(NSString *key, Class owner, SEL selector, BOOL installed) {
    Method method = owner ? class_getInstanceMethod(owner, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    NSString *status = installed ? @"hooked" : !owner ? @"classMissing" : !method ? @"methodMissing" : @"signatureMismatch";
    NSString *type = encoding ? [NSString stringWithUTF8String:encoding] : @"";
    if (type.length > 120) type = [type substringToIndex:120];
    [CWLock lock]; CWObservations[key] = @{@"status": status, @"encoding": type}; [CWLock unlock];
}
static void CWRecord(id object, SEL selector, id target, BOOL stopAfter) {
    CWIncrement(@"recordCalls");
    CWEvent(@"recordingStarted", @"NBVideoManager recordVideo:stopAfter: (observed)");
    CWOriginalRecord(object, selector, target, stopAfter);
}
static void CWStop(id object, SEL selector) {
    CWIncrement(@"stopCalls");
    CWEvent(@"recordingStopped", @"NBVideoManager stop (observed)");
    CWOriginalStop(object, selector);
}
static void CWCountFrame(CVPixelBufferRef frame, BOOL mjpeg) {
    if (!frame) { CWIncrement(mjpeg ? @"mjpegNilOutputs" : @"pixelNilOutputs"); return; }
    [CWLock lock];
    BOOL first = CWFrames == 0;
    if (CWFrames < INT_MAX) CWFrames++;
    [CWLock unlock];
    if (first) CWEvent(@"firstFrame", mjpeg ? @"Non-null MJPEG image conversion; not instrument display confirmation"
        : @"Non-null image conversion; not instrument display confirmation");
}
static CVPixelBufferRef CWPixelClass(id object, SEL selector, CGImageRef image) {
    CWIncrement(@"pixelCalls");
    CVPixelBufferRef result = CWOriginalPixelClass(object, selector, image);
    CWCountFrame(result, NO); return result;
}
static CVPixelBufferRef CWPixelInstance(id object, SEL selector, CGImageRef image) {
    CWIncrement(@"pixelCalls");
    CVPixelBufferRef result = CWOriginalPixelInstance(object, selector, image);
    CWCountFrame(result, NO); return result;
}
static CVPixelBufferRef CWMjpegClass(id object, SEL selector, CGImageRef image) {
    CWIncrement(@"mjpegCalls");
    CVPixelBufferRef result = CWOriginalMjpegClass(object, selector, image);
    CWCountFrame(result, YES); return result;
}
static CVPixelBufferRef CWMjpegInstance(id object, SEL selector, CGImageRef image) {
    CWIncrement(@"mjpegCalls");
    CVPixelBufferRef result = CWOriginalMjpegInstance(object, selector, image);
    CWCountFrame(result, YES); return result;
}
static void CWEncoded(id object, SEL selector, id encoder, id image) {
    if (CWIncrement(@"encodedCallbacks")) CWEvent(@"firstFrame", @"Official encoded callback observed; payload not inspected");
    CWOriginalEncoded(object, selector, encoder, image);
}
static BOOL CWRelevant(NSString *name) {
    NSString *lower = name.lowercaseString;
    for (NSString *word in @[@"projection", @"mirroring", @"broadcast", @"naviscreen", @"cruise"]) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}
static void CWAction(id object, SEL selector, SEL action, id target, UIEvent *event) {
    // Store class/selector names only. No labels, user text, arguments, credentials or payloads.
    NSString *targetName = target ? NSStringFromClass([target class]) : @"nil";
    NSString *actionName = action ? NSStringFromSelector(action) : @"nil";
    if ([targetName hasPrefix:@"CWProjectionProbe"]) {
        CWOriginalAction(object, selector, action, target, event);
        return;
    }
    BOOL relevant = CWRelevant(targetName) || CWRelevant(actionName);
    if (!relevant && [object isKindOfClass:UIView.class]) {
        UIView *ancestor = object;
        for (NSInteger i = 0; ancestor && i < 8; i++, ancestor = ancestor.superview) {
            if (CWRelevant(NSStringFromClass(ancestor.class))) { relevant = YES; break; }
        }
    }
    if (relevant) CWEvent(@"action", [NSString stringWithFormat:@"%@ %@", targetName, actionName]);
    CWOriginalAction(object, selector, action, target, event);
}

static void CWInstallHooks(void) {
    Class manager = NSClassFromString(@"NBVideoManager");
    SEL record = NSSelectorFromString(@"recordVideo:stopAfter:");
    Method method = class_getInstanceMethod(manager, record);
    if (!CWHooked(@"recordVideo") && method && method_getNumberOfArguments(method) == 4
        && CWReturns(method, 'v') && CWType(method, 2, "@")
        && (CWType(method, 3, "B") || CWType(method, 3, "c"))) {
        CWOriginalRecord = (void (*)(id, SEL, id, BOOL))CWReplace(manager, record, (IMP)CWRecord, (IMP *)&CWOriginalRecord);
        CWSetHook(@"recordVideo", CWOriginalRecord != NULL);
        CWEvent(@"hook", @"recordVideo signature matched");
    }
    SEL stop = NSSelectorFromString(@"stop"); method = class_getInstanceMethod(manager, stop);
    if (!CWHooked(@"stop") && method && method_getNumberOfArguments(method) == 2 && CWReturns(method, 'v')) {
        CWOriginalStop = (void (*)(id, SEL))CWReplace(manager, stop, (IMP)CWStop, (IMP *)&CWOriginalStop);
        CWSetHook(@"stop", CWOriginalStop != NULL); CWEvent(@"hook", @"stop signature matched");
    }
    CWObservation(@"recordVideo", manager, record, CWHooked(@"recordVideo"));
    CWObservation(@"stop", manager, stop, CWHooked(@"stop"));
    Class converter = NSClassFromString(@"NBPixelBufferConverter");
    for (NSNumber *mjpeg in @[@NO, @YES]) {
        SEL pixel = NSSelectorFromString(mjpeg.boolValue ? @"pixelBufferFromCGImage_Mjpeg:" : @"pixelBufferFromCGImage:");
        for (NSNumber *isClass in @[@YES, @NO]) {
            Class owner = isClass.boolValue ? object_getClass(converter) : converter;
            NSString *key = mjpeg.boolValue
                ? (isClass.boolValue ? @"mjpegClass" : @"mjpegInstance")
                : (isClass.boolValue ? @"pixelBufferClass" : @"pixelBufferInstance");
            IMP *saved = mjpeg.boolValue
                ? (isClass.boolValue ? (IMP *)&CWOriginalMjpegClass : (IMP *)&CWOriginalMjpegInstance)
                : (isClass.boolValue ? (IMP *)&CWOriginalPixelClass : (IMP *)&CWOriginalPixelInstance);
            BOOL installed = *saved != NULL;
            method = owner ? class_getInstanceMethod(owner, pixel) : NULL;
            char *returnType = method ? method_copyReturnType(method) : NULL;
            BOOL signatureMatches = method && method_getNumberOfArguments(method) == 3
                && CWType(method, 2, @encode(CGImageRef)) && returnType
                && strcmp(returnType, @encode(CVPixelBufferRef)) == 0;
            free(returnType);
            if (!installed && signatureMatches) {
                IMP replacement = mjpeg.boolValue
                    ? (isClass.boolValue ? (IMP)CWMjpegClass : (IMP)CWMjpegInstance)
                    : (isClass.boolValue ? (IMP)CWPixelClass : (IMP)CWPixelInstance);
                installed = CWReplace(owner, pixel, replacement, saved) != NULL;
                CWEvent(@"hook", [key stringByAppendingString:@" signature matched"]);
            }
            // Keep original five keys so old CarWithin builds can still read schema 1.
            if (!mjpeg.boolValue) CWSetHook(key, installed);
            CWObservation(key, owner, pixel, installed);
        }
    }
    SEL encoded = NSSelectorFromString(@"imageVideoEncoder:didEncodedImage:");
    method = manager ? class_getInstanceMethod(manager, encoded) : NULL;
    if (!CWOriginalEncoded && method && method_getNumberOfArguments(method) == 4
        && CWReturns(method, 'v') && CWType(method, 2, "@") && CWType(method, 3, "@")) {
        CWReplace(manager, encoded, (IMP)CWEncoded, (IMP *)&CWOriginalEncoded);
        CWEvent(@"hook", @"encoded callback signature matched");
    }
    CWObservation(@"encodedCallback", manager, encoded, CWOriginalEncoded != NULL);
    if (!CWHooked(@"controlAction")) {
        SEL action = @selector(sendAction:to:forEvent:);
        method = class_getInstanceMethod(UIControl.class, action);
        if (method && method_getNumberOfArguments(method) == 5 && CWReturns(method, 'v')
            && CWType(method, 2, ":") && CWType(method, 3, "@") && CWType(method, 4, "@")) {
            CWOriginalAction = (void (*)(id, SEL, SEL, id, UIEvent *))CWReplace(UIControl.class, action, (IMP)CWAction, (IMP *)&CWOriginalAction);
            CWSetHook(@"controlAction", CWOriginalAction != NULL);
        }
    }
    CWObservation(@"controlAction", UIControl.class, @selector(sendAction:to:forEvent:), CWHooked(@"controlAction"));
}

static NSArray<NSString *> *CWInventory(void) {
    NSMutableArray<NSString *> *result = [NSMutableArray new];
    for (NSString *name in @[@"NBVideoManager", @"NBPixelBufferConverter"]) {
        Class cls = NSClassFromString(name);
        for (NSNumber *isClass in @[@NO, @YES]) {
            Class owner = isClass.boolValue ? object_getClass(cls) : cls;
            if (!owner) continue;
            unsigned count = 0; Method *methods = class_copyMethodList(owner, &count);
            for (unsigned index = 0; index < count && result.count < 32; index++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[index]));
                NSString *lower = selector.lowercaseString;
                BOOL relevant = NO;
                for (NSString *term in @[@"pixel", @"image", @"encod", @"record", @"stop", @"suspend"]) {
                    if ([lower containsString:term]) { relevant = YES; break; }
                }
                if (!relevant) continue;
                const char *type = method_getTypeEncoding(methods[index]);
                NSString *entry = [NSString stringWithFormat:@"%@ %@%@ | %s", name, isClass.boolValue ? @"+" : @"-", selector, type ?: ""];
                if (entry.length > 120) entry = [entry substringToIndex:120];
                [result addObject:entry];
            }
            free(methods);
        }
    }
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

static NSDictionary *CWSnapshot(BOOL includeInventory) {
    [CWLock lock];
    NSDictionary *hooks = [CWHooks copy]; NSArray *events = [CWEvents copy];
    NSDictionary *counters = [CWCounters copy], *observations = [CWObservations copy];
    NSInteger frames = CWFrames; NSString *session = CWSession.UUIDString;
    [CWLock unlock];
    NSBundle *bundle = NSBundle.mainBundle;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    return @{@"schema": @1, @"producer": @"CarWithinNinebotProbe", @"sessionID": session,
        @"generatedAt": [formatter stringFromDate:NSDate.date],
        @"appVersion": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"appBuild": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"systemVersion": UIDevice.currentDevice.systemVersion,
        @"hooks": hooks, @"frameCount": @(frames), @"events": events,
        @"pluginVersion": @"0.2", @"counters": counters, @"observations": observations, @"methodInventory": includeInventory ? CWInventory() : @[]};
}

static NSString *CWPanelMessage(void) {
    NSDictionary *snapshot = CWSnapshot(NO); NSDictionary *hooks = snapshot[@"hooks"];
    NSDictionary *counters = snapshot[@"counters"], *observations = snapshot[@"observations"];
    BOOL pixel = [hooks[@"pixelBufferClass"] boolValue] || [hooks[@"pixelBufferInstance"] boolValue];
    BOOL mjpeg = [observations[@"mjpegClass"][@"status"] isEqual:@"hooked"] || [observations[@"mjpegInstance"][@"status"] isEqual:@"hooked"];
    BOOL encoded = [observations[@"encodedCallback"][@"status"] isEqual:@"hooked"];
    return [NSString stringWithFormat:@"插件 0.2 · 九号 %@（%@）\niOS %@\n录制：%@ · %@ 次\n停止：%@ · %@ 次\n普通转换：%@ · %@ 次\nMJPEG 转换：%@ · %@ 次\n编码回调：%@ · %@ 次\n非空转换输出：%@ 次\n\n已挂钩表示方法匹配，不代表被调用。按钮只标记时刻，不开启投屏。详细匹配原因和方法签名在 JSON 中。",
        snapshot[@"appVersion"], snapshot[@"appBuild"], snapshot[@"systemVersion"],
        [hooks[@"recordVideo"] boolValue] ? @"已挂钩" : @"未匹配", counters[@"recordCalls"] ?: @0,
        [hooks[@"stop"] boolValue] ? @"已挂钩" : @"未匹配", counters[@"stopCalls"] ?: @0,
        pixel ? @"已挂钩" : @"未匹配", counters[@"pixelCalls"] ?: @0,
        mjpeg ? @"已挂钩" : @"未匹配", counters[@"mjpegCalls"] ?: @0,
        encoded ? @"已挂钩" : @"未匹配", counters[@"encodedCallbacks"] ?: @0, snapshot[@"frameCount"]];
}

@interface CWProjectionProbe : NSObject
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) NSTimer *panelTimer;
+ (instancetype)shared;
- (void)foreground;
- (void)showPanel;
@end
@implementation CWProjectionProbe
+ (instancetype)shared {
    static CWProjectionProbe *probe; static dispatch_once_t once;
    dispatch_once(&once, ^{ probe = [CWProjectionProbe new]; }); return probe;
}
- (UIWindow *)activeWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    return nil;
}
- (UIViewController *)presenter {
    UIViewController *controller = self.activeWindow.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}
- (void)foreground {
    CWInstallHooks(); CWEvent(@"foreground", @"Official app entered foreground");
    UIWindow *window = self.activeWindow;
    if (!window) return;
    if (!self.button) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:@"投屏诊断" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.9];
        button.layer.cornerRadius = 18;
        button.accessibilityHint = @"查看 Hook 状态、标记实车操作并导出报告";
        [button addTarget:self action:@selector(showPanel) forControlEvents:UIControlEventTouchUpInside];
        self.button = button;
    }
    if (self.button.superview != window) { [self.button removeFromSuperview]; [window addSubview:self.button]; }
    self.button.frame = CGRectMake(12, window.safeAreaInsets.top + 48, 100, 36);
    [window bringSubviewToFront:self.button];
}
- (void)share {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:CWSnapshot(YES) options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"CarWithinProbe"] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    NSURL *file = [directory URLByAppendingPathComponent:@"CarWithin-ninebot-probe.json"];
    if (!data || ![data writeToURL:file options:NSDataWritingAtomic error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导出失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self.presenter presentViewController:alert animated:YES completion:nil]; return;
    }
    UIViewController *presenter = self.presenter;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = presenter.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
    [presenter presentViewController:sheet animated:YES completion:nil];
}
- (void)showPanel {
    CWInstallHooks(); // Recheck modules loaded after the app first became active.
    UIViewController *presenter = self.presenter;
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *panel = [UIAlertController alertControllerWithTitle:@"CarWithin 投屏诊断" message:CWPanelMessage() preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *mark in @[@"标记：准备开启官方投屏", @"标记：仪表已出画（人工确认）", @"标记：准备关闭官方投屏"]) {
        [panel addAction:[UIAlertAction actionWithTitle:mark style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            CWEvent(@"mark", action.title);
        }]];
    }
    [panel addAction:[UIAlertAction actionWithTitle:@"导出诊断 JSON" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self share]; });
    }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"开始新的采集" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [CWLock lock]; [CWEvents removeAllObjects]; [CWCounters removeAllObjects]; CWFrames = 0; CWSession = NSUUID.UUID;
        CWStart = NSProcessInfo.processInfo.systemUptime; [CWLock unlock];
        CWEvent(@"loaded", @"New manual capture; hooks remain installed");
    }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self.panelTimer invalidate];
    __weak UIAlertController *weakPanel = panel;
    __weak CWProjectionProbe *weakSelf = self;
    self.panelTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        UIAlertController *visible = weakPanel;
        if (!visible || !visible.viewIfLoaded.window || visible.isBeingDismissed) {
            [timer invalidate]; weakSelf.panelTimer = nil; return;
        }
        NSString *message = CWPanelMessage();
        if (![visible.message isEqualToString:message]) visible.message = message;
    }];
    [presenter presentViewController:panel animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void CWProjectionProbeLoad(void) {
    @autoreleasepool {
        CWLock = [NSLock new]; CWEvents = [NSMutableArray new];
        CWCounters = [NSMutableDictionary new]; CWObservations = [NSMutableDictionary new];
        CWHooks = [@{@"recordVideo": @NO, @"stop": @NO, @"pixelBufferClass": @NO,
                     @"pixelBufferInstance": @NO, @"controlAction": @NO} mutableCopy];
        CWSession = NSUUID.UUID; CWStart = NSProcessInfo.processInfo.systemUptime;
        CWEvent(@"loaded", @"CarWithinNinebotProbe 0.2; observation only");
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [[CWProjectionProbe shared] foreground];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [[CWProjectionProbe shared] foreground];
        });
    }
}
