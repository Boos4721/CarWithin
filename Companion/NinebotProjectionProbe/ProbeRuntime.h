#pragma once
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

// Narrow signature checks and forwarding; shared with the native runtime smoke test.
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

