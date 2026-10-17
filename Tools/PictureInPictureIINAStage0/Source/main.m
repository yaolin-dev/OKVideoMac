#import "PrivatePiP.h"
#import "OKMPVBridge.h"
#import <OpenGL/gl3.h>
#import <mach/mach.h>

@class Experiment;
@interface VideoSurface : NSOpenGLView
@property(nonatomic, weak) Experiment *owner;
@property(nonatomic) OKMPVClient *client;
@property(nonatomic) OKMPVRenderContext *renderer;
@property(nonatomic, strong) NSOpenGLContext *originalContext;
@property(nonatomic) NSUInteger creates, renders, skips, destroys;
@property(nonatomic) BOOL shuttingDown;
- (void)service;
- (void)shutdown;
@end

@interface Experiment : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSView *inlineHost;
@property(nonatomic, strong) VideoSurface *surface;
@property(nonatomic, strong) NSViewController *pipContent;
@property(nonatomic, strong) NSViewController<OKPrivatePiPSelectors> *pip;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSButton *pipButton;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) NSString *runID, *state;
@property(nonatomic, strong) NSDictionary *capabilities;
@property(nonatomic, strong) NSMutableArray *events, *samples;
@property(nonatomic, strong) NSDictionary *stats;
@property(nonatomic, strong) dispatch_queue_t controlQueue;
@property(nonatomic, strong) dispatch_source_t controlTimer;
@property(nonatomic) OKMPVClient *client;
@property(nonatomic) NSUInteger starts, stops, loadCount;
@property(nonatomic) double transitionStarted, lastSample;
@property(nonatomic) BOOL paused, closed, returning;
- (void)record:(NSString *)name;
- (void)fail:(NSString *)message;
- (void)writeEvidence;
- (void)loadFixture;
- (NSString *)stat:(NSString *)key;
@end

static void *getGL(void *context, const char *name) { return dlsym(RTLD_DEFAULT, name); }
static NSString *property(OKMPVClient *client, const char *name) {
    char value[256] = {0};
    return client && okmpv_get_property_string(client, name, value, sizeof(value)) >= 0 ? @(value) : @"unavailable";
}
static double seconds(void) { return NSProcessInfo.processInfo.systemUptime; }
static void renderWakeup(void *context) {
    __weak VideoSurface *surface=(__bridge VideoSurface *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [surface service]; });
}

@implementation VideoSurface
- (instancetype)init {
    NSOpenGLPixelFormatAttribute attrs[] = {NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFAAccelerated, NSOpenGLPFADoubleBuffer, NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0};
    self = [super initWithFrame:NSMakeRect(0, 0, 800, 450) pixelFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs]];
    if (self) { self.wantsBestResolutionOpenGLSurface = YES; self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; }
    return self;
}
- (void)prepareOpenGL {
    [super prepareOpenGL];
    if (self.renderer || self.shuttingDown) return;
    [self.openGLContext makeCurrentContext];
    self.originalContext = self.openGLContext;
    GLint swap = 1; [self.openGLContext setValues:&swap forParameter:NSOpenGLContextParameterSwapInterval];
    OKMPVRenderContext *renderer = NULL;
    int result = okmpv_render_create(self.client, getGL, NULL, 1, &renderer);
    if (result < 0) { [self.owner fail:[NSString stringWithFormat:@"render-create:%d", result]]; return; }
    self.renderer = renderer; self.creates++;
    okmpv_render_set_update_callback(renderer,renderWakeup,(__bridge void *)self);
    [self.owner record:@"render-created"];
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self setNeedsDisplay:YES]; [self.owner record:@"surface-window-changed"]; }
- (void)reshape { [super reshape]; [self.openGLContext update]; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
    if (!self.renderer || self.shuttingDown || !self.window || self.window.isMiniaturized) return;
    if (self.openGLContext != self.originalContext) { [self.owner fail:@"OpenGL-context-replaced"]; return; }
    NSSize pixels = [self convertRectToBacking:self.bounds].size;
    if (pixels.width < 1 || pixels.height < 1) return;
    [self.originalContext makeCurrentContext]; [self.originalContext update];
    int result = okmpv_render(self.renderer, 0, (int)pixels.width, (int)pixels.height, 1);
    if (result < 0) { [self.owner fail:[NSString stringWithFormat:@"render:%d", result]]; return; }
    [self.originalContext flushBuffer]; okmpv_render_report_swap(self.renderer); self.renders++;
}
- (void)service {
    if (!self.renderer || self.shuttingDown) return;
    [self.originalContext makeCurrentContext];
    uint64_t update = okmpv_render_update(self.renderer);
    if (!(update & 1)) return;
    if (self.window && !self.window.isMiniaturized) [self setNeedsDisplay:YES];
    else { okmpv_render_skip(self.renderer); self.skips++; }
}
- (void)shutdown {
    self.shuttingDown = YES;
    if (self.renderer) {
        [self.originalContext makeCurrentContext]; okmpv_render_set_update_callback(self.renderer,NULL,NULL);
        okmpv_render_destroy(self.renderer); self.renderer = NULL; self.destroys++;
    }
}
@end

@implementation Experiment
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.root = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    self.runID = NSUUID.UUID.UUIDString; self.state = @"inline";
    self.events = [NSMutableArray array]; self.samples = [NSMutableArray array];
    self.stats=@{}; self.controlQueue=dispatch_queue_create("prototype.mpv.control",DISPATCH_QUEUE_SERIAL);
    BOOL unavailable = [NSProcessInfo.processInfo.arguments containsObject:@"--simulate-unavailable"];
    self.capabilities = OKProbePiP(unavailable);
    NSMenu *main = [NSMenu new], *menu = [NSMenu new]; NSMenuItem *item = [NSMenuItem new];
    item.submenu = menu; [main addItem:item];
    for (NSArray *entry in @[@[@"Show Player", @"showPlayer:", @"0"], @[@"Enter PiP", @"enterPiP:", @"p"],
          @[@"Return to Player", @"returnPlayer:", @"r"], @[@"Play / Pause", @"togglePause:", @" "], @[@"Quit Prototype", @"terminate:", @"q"]]) {
        NSMenuItem *action = [[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]];
        action.target = [entry[1] isEqual:@"terminate:"] ? NSApp : self; [menu addItem:action];
    }
    NSApp.mainMenu = main;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(150, 160, 800, 560)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"OKVideo — IINA-style mpv PiP Stage 0";
    self.window.identifier = @"OKVideo.PiP.IINA.Stage0"; self.window.delegate = self; self.window.releasedWhenClosed = NO;
    self.inlineHost = [[NSView alloc] initWithFrame:NSMakeRect(0, 110, 800, 450)];
    self.inlineHost.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    [self.window.contentView addSubview:self.inlineHost];
    NSArray *entries = @[@[@"Enter Native PiP", @"enterPiP:"], @[@"Return to Player", @"returnPlayer:"],
                          @[@"Play / Pause", @"togglePause:"], @[@"Minimize Main", @"minimizeMain:"]];
    for (NSUInteger i=0;i<entries.count;i++) {
        NSButton *button = [NSButton buttonWithTitle:entries[i][0] target:self action:NSSelectorFromString(entries[i][1])];
        button.frame = NSMakeRect(12 + i*195, 58, 185, 32); [self.window.contentView addSubview:button];
        if (i==0) self.pipButton=button;
    }
    self.label = [NSTextField labelWithString:@"Preparing mpv"];
    self.label.frame=NSMakeRect(16, 12, 770, 35); self.label.autoresizingMask=NSViewWidthSizable;
    [self.window.contentView addSubview:self.label];
    self.pipButton.enabled = [self.capabilities[@"requiredAPICompatible"] boolValue];
    if (self.pipButton.enabled) {
        Class cls = NSClassFromString(@"PIPViewController");
        self.pip = [[cls alloc] init]; [self.pip setDelegate:self]; [self.pip setAspectRatio:NSMakeSize(16,9)];
        self.pip.title = @"mpv native PiP — Stage 0";
    }
    self.client = okmpv_create();
    if (!self.client) { [self fail:@"mpv-create"]; return; }
    NSDictionary *options = @{@"config":@"no", @"terminal":@"no", @"vo":@"libmpv", @"hwdec":@"auto-safe", @"ao":@"coreaudio",
        @"log-file":[[self.root URLByAppendingPathComponent:@"Evidence/mpv.log"] path], @"msg-level":@"all=v", @"loop-file":@"inf", @"keep-open":@"yes", @"volume":@"15", @"input-default-bindings":@"no", @"input-vo-keyboard":@"no"};
    for (NSString *key in options) {
        int result=okmpv_set_option_string(self.client,key.UTF8String,[options[key] UTF8String]);
        if(result<0) { [self fail:[@"option:" stringByAppendingString:key]]; return; }
    }
    int result=okmpv_initialize(self.client);
    if(result<0) { [self fail:[NSString stringWithFormat:@"initialize:%d",result]]; return; }
    self.surface=[VideoSurface new]; self.surface.owner=self; self.surface.client=self.client;
    self.surface.frame=self.inlineHost.bounds; [self.inlineHost addSubview:self.surface];
    [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    __weak Experiment *weakSelf=self;
    self.controlTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.controlQueue);
    dispatch_source_set_timer(self.controlTimer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/10,NSEC_PER_MSEC*5);
    dispatch_source_set_event_handler(self.controlTimer,^{
        Experiment *owner=weakSelf; if(!owner) return;
        for(int i=0;i<32;i++) { OKMPVEvent event={0}; if(okmpv_wait_event(owner.client,0,&event)<0 || event.event_id==0) break; }
        NSMutableDictionary *stats=[NSMutableDictionary dictionary];
        for(NSString *key in @[@"time-pos",@"audio-pts",@"current-ao",@"audio-codec-name",@"hwdec-current",@"video-codec",@"pause",@"paused-for-cache",@"core-idle",@"audio-device",@"audio-speed-correction",@"video-speed-correction",@"avsync",@"vo-delayed-frame-count",@"eof-reached"]) stats[key]=property(owner.client,key.UTF8String);
        dispatch_async(dispatch_get_main_queue(),^{ if(!owner.closed) owner.stats=stats; });
    });
    dispatch_resume(self.controlTimer);
    self.timer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer){ [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self record:@"launched"];
}
- (void)loadFixture {
    NSString *path=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"fixture.mov"].path;
    self.loadCount++;
    dispatch_async(self.controlQueue,^{
        const char *args[]={"loadfile",path.UTF8String,"replace"}; int result=okmpv_command(self.client,3,args);
        dispatch_async(dispatch_get_main_queue(),^{
            if(result<0) [self fail:[NSString stringWithFormat:@"load:%d",result]];
            else [self record:@"fixture-loaded-after-render-ready"];
        });
    });
}
- (void)tick {
    if (self.closed) return;
    if(self.surface.renderer && self.loadCount==0) [self loadFixture];
    [self.surface service];
    if ([self.state isEqual:@"entering"] && self.surface.window && self.surface.window != self.window && self.surface.renders>0) {
        self.state=@"pip"; self.starts++; [self record:@"pip-attached"];
    }
    if ([self.state isEqual:@"entering"] && seconds()-self.transitionStarted>5) {
        [self fail:@"pip-entry-timeout"]; [self returnPlayer:nil];
    }
    if (seconds()-self.lastSample>=1) { self.lastSample=seconds(); [self writeEvidence]; }
}
- (void)enterPiP:(id)sender {
    if(!self.pip || ![self.state isEqual:@"inline"] || !self.surface.renderer) { [self record:@"entry-rejected-not-ready"]; return; }
    self.state=@"entering"; self.transitionStarted=seconds();
    self.pipContent=[NSViewController new]; self.pipContent.view=self.surface;
    [self.pip setPlaying:!self.paused];
    @try { [self.pip presentViewControllerAsPictureInPicture:self.pipContent]; }
    @catch(NSException *exception) { [self fail:[@"private-exception:" stringByAppendingString:exception.name]]; [self restoreSurface]; return; }
    [self.surface setNeedsDisplay:YES]; [self record:@"entry-request"];
}
- (void)prepareReturn {
    if (!self.pip) return;
    [self.pip setReplacementWindow:self.window];
    [self.pip setReplacementRect:[self.inlineHost convertRect:self.inlineHost.bounds toView:nil]];
    [self.window deminiaturize:nil]; [self.window makeKeyAndOrderFront:nil];
}
- (void)returnPlayer:(id)sender {
    if (![self.state isEqual:@"pip"] && ![self.state isEqual:@"entering"]) return;
    self.returning=YES; self.state=@"returning"; [self prepareReturn];
    [self.pip dismissViewController:self.pipContent]; [self record:@"return-request"];
}
- (void)restoreSurface {
    [self.surface removeFromSuperview]; self.surface.frame=self.inlineHost.bounds;
    [self.inlineHost addSubview:self.surface]; [self.surface setNeedsDisplay:YES];
    self.state=@"inline"; self.returning=NO; self.pipContent=nil;
}
- (void)pipWillClose:(id)pip { [self prepareReturn]; [self record:@"pip-will-close"]; }
- (void)pipDidClose:(id)pip { [self restoreSurface]; self.stops++; [self record:@"pip-did-close"]; }
- (void)pipActionPlay:(id)pip { [self setPaused:NO]; [self record:@"system-play"]; }
- (void)pipActionPause:(id)pip { [self setPaused:YES]; [self record:@"system-pause"]; }
- (void)pipActionStop:(id)pip { [self setPaused:YES]; [self record:@"system-stop"]; }
- (void)togglePause:(id)sender { [self setPaused:!self.paused]; }
- (void)setPaused:(BOOL)paused {
    _paused=paused;
    dispatch_async(self.controlQueue,^{
        int result=okmpv_set_property_flag(self.client,"pause",paused);
        if(result<0) dispatch_async(dispatch_get_main_queue(),^{ [self fail:@"pause-command"]; });
    });
    [self.pip setPlaying:!paused]; [self record:paused?@"paused":@"playing"];
}
- (void)minimizeMain:(id)sender { [self.window miniaturize:nil]; }
- (void)showPlayer:(id)sender { [self.window deminiaturize:nil]; [self.window makeKeyAndOrderFront:nil]; }
- (void)windowDidMiniaturize:(NSNotification *)notification { [self record:@"main-minimized"]; }
- (void)windowDidDeminiaturize:(NSNotification *)notification { [self record:@"main-restored"]; }
- (void)fail:(NSString *)message { self.state=@"failed"; [self record:message]; }
- (NSString *)stat:(NSString *)key { return self.stats[key]?:@"unavailable"; }
- (void)record:(NSString *)name {
    if (!self.events) return;
    [self.events addObject:@{@"event":name,@"uptime":@(seconds()),@"state":self.state?:@"initializing",
        @"frames":@(self.surface.renders),@"position":[self stat:@"time-pos"]}];
    [self writeEvidence];
}
- (void)writeEvidence {
    struct mach_task_basic_info memory={0}; mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&memory,&count);
    NSString *position=[self stat:@"time-pos"], *audio=[self stat:@"audio-pts"];
    NSDictionary *sample=@{@"uptime":@(seconds()),@"position":position,@"audioPTS":audio,@"frames":@(self.surface.renders),
        @"state":self.state?:@"initializing",@"paused":@(self.paused),@"mainMiniaturized":@(self.window.isMiniaturized),
        @"surfaceInMain":@(self.surface.window==self.window),@"rssBytes":@(memory.resident_size)};
    [self.samples addObject:sample]; if(self.samples.count>600) [self.samples removeObjectAtIndex:0];
    NSMutableDictionary *data=[@{@"audioTestMode":@"real-coreaudio",@"runID":self.runID,@"state":self.state?:@"initializing",@"capabilities":self.capabilities,
        @"starts":@(self.starts),@"stops":@(self.stops),@"mpvClientsCreated":@1,@"loadCommands":@(self.loadCount),
        @"renderContextsCreated":@(self.surface.creates),@"renderContextsDestroyed":@(self.surface.destroys),
        @"sameOpenGLContext":@(self.surface.originalContext && self.surface.originalContext==self.surface.openGLContext),
        @"audioOutput":[self stat:@"current-ao"],@"audioCodec":[self stat:@"audio-codec-name"],
        @"hwdec":[self stat:@"hwdec-current"],@"videoCodec":[self stat:@"video-codec"],
        @"stats":self.stats,@"latest":sample,@"events":self.events,@"samples":self.samples} mutableCopy];
    NSData *json=[NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    NSURL *dir=[self.root URLByAppendingPathComponent:@"Evidence"];
    [json writeToURL:[dir URLByAppendingPathComponent:@"runtime.json"] atomically:YES];
    [json writeToURL:[dir URLByAppendingPathComponent:[NSString stringWithFormat:@"run-%@.json",self.runID]] atomically:YES];
    self.label.stringValue=[NSString stringWithFormat:@"%@ · %@s · %@ · renders %lu · contexts %lu · PiP %lu/%lu",self.state,position,self.paused?@"paused":@"playing",self.surface.renders,self.surface.creates,self.starts,self.stops];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    self.closed=YES; [self.timer invalidate]; [self.surface shutdown]; [self record:@"terminated"];
    if(self.controlTimer) dispatch_source_cancel(self.controlTimer);
    dispatch_sync(self.controlQueue,^{ if(self.client) { okmpv_destroy(self.client); self.client=NULL; } });
}
@end

int main(int argc,const char **argv) {
    @autoreleasepool {
        NSApplication *app=NSApplication.sharedApplication; Experiment *delegate=[Experiment new]; app.delegate=delegate; [app run];
    }
    return 0;
}
