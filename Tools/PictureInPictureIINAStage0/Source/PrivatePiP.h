#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Experiment-only declarations inferred from IINA's published interface.
// No static private-framework link, exported private class reference, or bundled Apple binary.
@protocol OKPrivatePiPSelectors <NSObject>
- (void)setDelegate:(id)delegate;
- (void)setPlaying:(bool)playing;
- (void)setAspectRatio:(NSSize)ratio;
- (void)setReplacementWindow:(NSWindow *)window;
- (void)setReplacementRect:(NSRect)rect;
- (void)presentViewControllerAsPictureInPicture:(NSViewController *)controller;
- (void)dismissViewController:(NSViewController *)controller;
@end

static NSDictionary *OKProbePiP(BOOL simulateUnavailable) {
    void *library = simulateUnavailable ? NULL : dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_LOCAL | RTLD_NOW);
    Class cls = library ? NSClassFromString(@"PIPViewController") : Nil;
    NSDictionary *expected = @{@"setDelegate:": @"object", @"setPlaying:": @"bool", @"setAspectRatio:": @"size",
        @"setReplacementWindow:": @"object", @"setReplacementRect:": @"rect",
        @"presentViewControllerAsPictureInPicture:": @"object", @"dismissViewController:": @"object"};
    NSMutableDictionary *methods = [NSMutableDictionary dictionary];
    BOOL valid = cls != Nil;
    for (NSString *name in expected) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        BOOL compatible = method && method_getNumberOfArguments(method) == 3;
        if (compatible) {
            char result[256] = {0}, arg[256] = {0};
            method_getReturnType(method, result, sizeof(result));
            method_getArgumentType(method, 2, arg, sizeof(arg));
            compatible = strcmp(result, @encode(void)) == 0;
            NSString *type = expected[name];
            if ([type isEqual:@"bool"]) compatible &= strcmp(arg, @encode(bool)) == 0;
            else if ([type isEqual:@"size"]) compatible &= strcmp(arg, @encode(NSSize)) == 0;
            else if ([type isEqual:@"rect"]) compatible &= strcmp(arg, @encode(NSRect)) == 0;
            else compatible &= arg[0] == '@';
        }
        methods[name] = @{@"present": @(method != NULL), @"signatureCompatible": @(compatible),
                          @"encoding": method ? @(method_getTypeEncoding(method)) : @"missing"};
        valid &= compatible;
    }
    return @{@"frameworkLoaded": @(library != NULL), @"classAvailable": @(cls != Nil), @"requiredAPICompatible": @(valid),
             @"simulatedUnavailable": @(simulateUnavailable), @"requiredMethods": methods,
             @"optionalPlaybackStateAvailable": @(class_getInstanceMethod(cls, NSSelectorFromString(@"updatePlaybackStateUsingBlock:")) != NULL),
             @"os": NSProcessInfo.processInfo.operatingSystemVersionString};
}
