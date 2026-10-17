#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Narrow, runtime-checked adapter. No private framework is linked or shipped.
@interface OKNativePiPBridge : NSObject
@property(nonatomic, readonly) BOOL isAvailable;
@property(nonatomic, copy, nullable) void (^onWillClose)(void);
@property(nonatomic, copy, nullable) void (^onDidClose)(void);
@property(nonatomic, copy, nullable) void (^onPlay)(void);
@property(nonatomic, copy, nullable) void (^onPause)(void);
@property(nonatomic, copy, nullable) void (^onStop)(void);
- (nullable NSString *)present:(NSViewController *)content window:(NSWindow *)window
    rect:(NSRect)rect aspect:(NSSize)aspect playing:(BOOL)playing title:(NSString *)title
    NS_SWIFT_NAME(present(_:window:rect:aspect:playing:title:));
- (nullable NSString *)updatePlaying:(BOOL)playing aspect:(NSSize)aspect title:(NSString *)title
    NS_SWIFT_NAME(update(playing:aspect:title:));
- (nullable NSString *)dismiss:(NSViewController *)content window:(NSWindow *)window rect:(NSRect)rect
    NS_SWIFT_NAME(dismiss(_:window:rect:));
- (void)setReturnWindow:(NSWindow *)window rect:(NSRect)rect;
/// Suppresses stale callbacks and closes presentation before renderer teardown.
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
