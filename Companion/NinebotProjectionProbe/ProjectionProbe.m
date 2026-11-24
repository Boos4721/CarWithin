// Original CarWithin diagnostic companion. Observe only; never invoke vehicle commands.
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <limits.h>

static NSLock *CWLock;
static NSMutableArray<NSDictionary *> *CWEvents;
static NSMutableDictionary<NSString *, NSNumber *> *CWHooks;
static NSUUID *CWSession;
static double CWStart;
static NSInteger CWFrames;
static void (*CWOriginalRecord)(id, SEL, id, BOOL);
static void (*CWOriginalStop)(id, SEL);
static CVPixelBufferRef (*CWOriginalPixelClass)(id, SEL, CGImageRef);
static CVPixelBufferRef (*CWOriginalPixelInstance)(id, SEL, CGImageRef);
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
static BOOL CWType(Method method, unsigned index, const char *type) {
    char *actual = method_copyArgumentType(method, index);
    BOOL matches = actual && strcmp(actual, type) == 0;
    free(actual); return matches;
}
static BOOL CWReturns(Method method, char first) {
    char *type = method_copyReturnType(method);
    BOOL matches = type && type[0] == first;
    free(type); return matches;
}
static IMP CWReplace(Class cls, SEL selector, IMP replacement, IMP *saved) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    *saved = original; // Publish the forwarding target before another thread can enter the hook.
    // Add an override when inherited; never overwrite a superclass implementation accidentally.
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    }
    return original;
}

static void CWRecord(id object, SEL selector, id target, BOOL stopAfter) {
    CWEvent(@"recordingStarted", @"NBVideoManager recordVideo:stopAfter: (observed)");
    CWOriginalRecord(object, selector, target, stopAfter);
}
static void CWStop(id object, SEL selector) {
    CWEvent(@"recordingStopped", @"NBVideoManager stop (observed)");
    CWOriginalStop(object, selector);
}
static void CWCountFrame(CVPixelBufferRef frame) {
    if (!frame) return;
    [CWLock lock];
    BOOL first = CWFrames == 0;
    if (CWFrames < INT_MAX) CWFrames++;
    [CWLock unlock];
    if (first) CWEvent(@"firstFrame", @"Non-null official image conversion output; not instrument display confirmation");
}
static CVPixelBufferRef CWPixelClass(id object, SEL selector, CGImageRef image) {
    CVPixelBufferRef result = CWOriginalPixelClass(object, selector, image);
    CWCountFrame(result); return result;
}
static CVPixelBufferRef CWPixelInstance(id object, SEL selector, CGImageRef image) {
    CVPixelBufferRef result = CWOriginalPixelInstance(object, selector, image);
    CWCountFrame(result); return result;
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
    Class converter = NSClassFromString(@"NBPixelBufferConverter");
    SEL pixel = NSSelectorFromString(@"pixelBufferFromCGImage:");
    for (NSNumber *isClass in @[@YES, @NO]) {
        Class owner = isClass.boolValue ? object_getClass(converter) : converter;
        NSString *key = isClass.boolValue ? @"pixelBufferClass" : @"pixelBufferInstance";
        method = class_getInstanceMethod(owner, pixel);
        if (CWHooked(key) || !method || method_getNumberOfArguments(method) != 3
            || !CWType(method, 2, @encode(CGImageRef))) continue;
        char *returnType = method_copyReturnType(method);
        BOOL returnsPixel = returnType && strcmp(returnType, @encode(CVPixelBufferRef)) == 0;
        free(returnType);
        if (!returnsPixel) continue;
        IMP previous = CWReplace(owner, pixel, isClass.boolValue ? (IMP)CWPixelClass : (IMP)CWPixelInstance,
            isClass.boolValue ? (IMP *)&CWOriginalPixelClass : (IMP *)&CWOriginalPixelInstance);
        if (isClass.boolValue) CWOriginalPixelClass = (CVPixelBufferRef (*)(id, SEL, CGImageRef))previous;
        else CWOriginalPixelInstance = (CVPixelBufferRef (*)(id, SEL, CGImageRef))previous;
        CWSetHook(key, previous != NULL); CWEvent(@"hook", [key stringByAppendingString:@" signature matched"]);
    }
    if (!CWHooked(@"controlAction")) {
        SEL action = @selector(sendAction:to:forEvent:);
        method = class_getInstanceMethod(UIControl.class, action);
        if (method && method_getNumberOfArguments(method) == 5 && CWReturns(method, 'v')
            && CWType(method, 2, ":") && CWType(method, 3, "@") && CWType(method, 4, "@")) {
            CWOriginalAction = (void (*)(id, SEL, SEL, id, UIEvent *))CWReplace(UIControl.class, action, (IMP)CWAction, (IMP *)&CWOriginalAction);
            CWSetHook(@"controlAction", CWOriginalAction != NULL);
        }
    }
}

static NSDictionary *CWSnapshot(void) {
    [CWLock lock];
    NSDictionary *hooks = [CWHooks copy]; NSArray *events = [CWEvents copy];
    NSInteger frames = CWFrames; NSString *session = CWSession.UUIDString;
    [CWLock unlock];
    NSBundle *bundle = NSBundle.mainBundle;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    return @{@"schema": @1, @"producer": @"CarWithinNinebotProbe", @"sessionID": session,
        @"generatedAt": [formatter stringFromDate:NSDate.date],
        @"appVersion": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"appBuild": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"systemVersion": UIDevice.currentDevice.systemVersion,
        @"hooks": hooks, @"frameCount": @(frames), @"events": events};
}

@interface CWProjectionProbe : NSObject
@property(nonatomic, strong) UIButton *button;
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
    NSData *data = [NSJSONSerialization dataWithJSONObject:CWSnapshot() options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
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
    UIViewController *presenter = self.presenter;
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    NSDictionary *snapshot = CWSnapshot(); NSDictionary *hooks = snapshot[@"hooks"];
    NSString *message = [NSString stringWithFormat:@"九号出行 %@（%@）\niOS %@\n录制入口：%@ · 停止入口：%@\n图像转换计数：%@\n\n观察模式，不会自动点击、调用车辆指令或切断官方视频。计数不代表仪表已出画。",
        snapshot[@"appVersion"], snapshot[@"appBuild"], snapshot[@"systemVersion"],
        [hooks[@"recordVideo"] boolValue] ? @"已挂钩" : @"未匹配",
        [hooks[@"stop"] boolValue] ? @"已挂钩" : @"未匹配", snapshot[@"frameCount"]];
    UIAlertController *panel = [UIAlertController alertControllerWithTitle:@"CarWithin 投屏诊断" message:message preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *mark in @[@"准备开启官方投屏", @"仪表已出画（人工确认）", @"准备关闭官方投屏"]) {
        [panel addAction:[UIAlertAction actionWithTitle:mark style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            CWEvent(@"mark", action.title);
        }]];
    }
    [panel addAction:[UIAlertAction actionWithTitle:@"导出诊断 JSON" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self share]; });
    }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"开始新的采集" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [CWLock lock]; [CWEvents removeAllObjects]; CWFrames = 0; CWSession = NSUUID.UUID;
        CWStart = NSProcessInfo.processInfo.systemUptime; [CWLock unlock];
        CWEvent(@"loaded", @"New manual capture; hooks remain installed");
    }]];
    [panel addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:panel animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void CWProjectionProbeLoad(void) {
    @autoreleasepool {
        CWLock = [NSLock new]; CWEvents = [NSMutableArray new];
        CWHooks = [@{@"recordVideo": @NO, @"stop": @NO, @"pixelBufferClass": @NO,
                     @"pixelBufferInstance": @NO, @"controlAction": @NO} mutableCopy];
        CWSession = NSUUID.UUID; CWStart = NSProcessInfo.processInfo.systemUptime;
        CWEvent(@"loaded", @"CarWithinNinebotProbe 0.1; observation only");
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [[CWProjectionProbe shared] foreground];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [[CWProjectionProbe shared] foreground];
        });
    }
}
