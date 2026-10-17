#import "OKNativePiPBridge.h"
#import <objc/runtime.h>
#import <dlfcn.h>

// bool is intentional: the private setter's ABI is C++ bool, not ObjC BOOL.
@protocol OKNativePiPSelectors <NSObject>
- (void)setDelegate:(nullable id)delegate;
- (void)setPlaying:(bool)playing;
- (void)setAspectRatio:(NSSize)size;
- (void)setReplacementWindow:(NSWindow *)window;
- (void)setReplacementRect:(NSRect)rect;
- (void)presentViewControllerAsPictureInPicture:(NSViewController *)content;
- (void)dismissViewController:(NSViewController *)content;
@end

static Class compatibleClass(void) {
    static Class result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep the system library loaded for the lifetime of its ObjC classes.
        if (!dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_LOCAL | RTLD_NOW)) return;
        Class cls = NSClassFromString(@"PIPViewController");
        if (!cls || ![cls isSubclassOfClass:NSViewController.class]) return;
        NSDictionary *types = @{@"setDelegate:": @(@encode(id)), @"setPlaying:": @(@encode(bool)),
            @"setAspectRatio:": @(@encode(NSSize)), @"setReplacementWindow:": @(@encode(id)),
            @"setReplacementRect:": @(@encode(NSRect)),
            @"presentViewControllerAsPictureInPicture:": @(@encode(id)),
            @"dismissViewController:": @(@encode(id))};
        for (NSString *name in types) {
            Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
            if (!method || method_getNumberOfArguments(method) != 3) return;
            char argument[256] = {0}, returned[64] = {0};
            method_getArgumentType(method, 2, argument, sizeof(argument));
            method_getReturnType(method, returned, sizeof(returned));
            if (strcmp(returned, @encode(void)) || strcmp(argument, [types[name] UTF8String])) return;
        }
        result = cls;
    });
    return result;
}

@implementation OKNativePiPBridge {
    NSViewController<OKNativePiPSelectors> *_controller;
    NSViewController *_content;
    BOOL _invalidated;
}
- (BOOL)isAvailable { return compatibleClass() != Nil && !_invalidated; }
- (NSString *)present:(NSViewController *)content window:(NSWindow *)window rect:(NSRect)rect
    aspect:(NSSize)aspect playing:(BOOL)playing title:(NSString *)title {
    NSAssert(NSThread.isMainThread, @"PiP is main-thread only");
    if (!self.isAvailable || _controller) return @"unavailable";
    @try {
        _controller = [[compatibleClass() alloc] init];
        [_controller setDelegate:self];
        _content = content;
        [self setReturnWindow:window rect:rect];
        [_controller setAspectRatio:aspect];
        [_controller setPlaying:playing != NO];
        _controller.title = title;
        [_controller presentViewControllerAsPictureInPicture:content];
        return nil;
    } @catch (NSException *exception) { [self invalidate]; return @"presentation-failed"; }
}
- (NSString *)updatePlaying:(BOOL)playing aspect:(NSSize)aspect title:(NSString *)title {
    if (!_controller || _invalidated) return nil;
    @try {
        [_controller setPlaying:playing != NO]; [_controller setAspectRatio:aspect]; _controller.title = title;
        return nil;
    } @catch (NSException *exception) { return @"update-failed"; }
}
- (void)setReturnWindow:(NSWindow *)window rect:(NSRect)rect {
    @try { [_controller setReplacementWindow:window]; [_controller setReplacementRect:rect]; }
    @catch (NSException *exception) { /* Dismissal still has a non-animated recovery path. */ }
}
- (NSString *)dismiss:(NSViewController *)content window:(NSWindow *)window rect:(NSRect)rect {
    @try { [self setReturnWindow:window rect:rect]; [_controller dismissViewController:content]; return nil; }
    @catch (NSException *exception) { return @"dismissal-failed"; }
}
- (void)invalidate {
    _invalidated = YES;
    self.onWillClose = nil; self.onDidClose = nil; self.onPlay = nil; self.onPause = nil; self.onStop = nil;
    @try { [_controller setDelegate:nil]; if (_content) [_controller dismissViewController:_content]; }
    @catch (NSException *exception) { }
    _content = nil; _controller = nil;
}
- (void)pipWillClose:(id)sender { if (sender == _controller && !_invalidated && self.onWillClose) self.onWillClose(); }
- (void)pipDidClose:(id)sender {
    if (sender != _controller || _invalidated) return;
    _content = nil;
    if (self.onDidClose) self.onDidClose();
}
- (void)pipActionPlay:(id)sender { if (sender == _controller && !_invalidated && self.onPlay) self.onPlay(); }
- (void)pipActionPause:(id)sender { if (sender == _controller && !_invalidated && self.onPause) self.onPause(); }
- (void)pipActionStop:(id)sender { if (sender == _controller && !_invalidated && self.onStop) self.onStop(); }
- (void)dealloc { [self invalidate]; }
@end
