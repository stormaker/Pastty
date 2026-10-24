#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <ImageIO/ImageIO.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Pastty.h"

static NSString *const PasttyMarker = @"org.stormaker.pastty.restored";
static const NSUInteger MaxImageBytes = 16 * 1024 * 1024;
static const NSUInteger MaxTextBytes = 1024 * 1024;
static const uint64_t MaxImagePixels = 40000000;
static const NSUInteger ThumbnailCacheLimit = 8 * 1024 * 1024;
static int SmokeResult = 0;
static void SmokeCheck(BOOL pass, const char *name) {
    printf("%s %s\n", pass ? "PASS" : "FAIL", name);
    fflush(stdout);
    if (!pass) SmokeResult = 1;
}
static const uint32_t HotkeySignature = 'Psty';
static NSEvent *SmokeKeyEvent(NSWindow *window, unsigned short keycode, unichar character) {
    NSString *characters = [NSString stringWithCharacters:&character length:1];
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keycode];
}

@class PasttyDelegate;
@interface PasttyPanel : NSPanel
@property(nonatomic, copy) void (^dismissHandler)(void);
@end
@implementation PasttyPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)resignKeyWindow {
    [super resignKeyWindow];
    if (self.dismissHandler) self.dismissHandler();
}
@end

@interface PasttyTable : NSTableView
@property(nonatomic, copy) void (^acceptHandler)(void);
@property(nonatomic, copy) void (^dismissHandler)(void);
@property(nonatomic, strong) NSTrackingArea *hoverTracking;
@end
@implementation PasttyTable
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTracking) [self removeTrackingArea:self.hoverTracking];
    self.hoverTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:(NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect) owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTracking];
}
- (void)mouseMoved:(NSEvent *)event {
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row >= 0 && row != self.selectedRow) [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 || event.keyCode == 76) {
        if (!event.isARepeat && self.acceptHandler) self.acceptHandler();
    } else if (event.keyCode == 53) {
        if (self.dismissHandler) self.dismissHandler();
    } else {
        [super keyDown:event];
    }
}
@end

@interface PasttyDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) PasttyPanel *panel;
@property(nonatomic, strong) PasttyTable *table;
@property(nonatomic, strong) NSScrollView *scroll;
@property(nonatomic, strong) NSTextField *historyFooter;
@property(nonatomic, strong) NSTextField *historyHeading;
@property(nonatomic, strong) NSTextField *historyCount;
@property(nonatomic, strong) NSTextField *emptyHistory;
@property(nonatomic, strong) NSBox *historyDivider;
@property(nonatomic, strong) NSButton *historySettings;
@property(nonatomic, strong) NSButton *historyQuit;
@property(nonatomic) BOOL anchoredToStatusItem;
@property(nonatomic) NSPoint historyAnchor;
@property(nonatomic, strong) NSWindow *settings;
@property(nonatomic, strong) NSButton *iconToggle;
@property(nonatomic, strong) NSButton *loginToggle;
@property(nonatomic, strong) NSButton *hotkeyButton;
@property(nonatomic, strong) NSTextField *settingsMessage;
@property(nonatomic, strong) NSArray<NSDictionary *> *rows;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *thumbnails;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *thumbnailCosts;
@property(nonatomic, strong) NSMutableArray<NSString *> *thumbnailOrder;
@property(nonatomic, strong) NSHashTable<NSImageView *> *thumbnailViews;
@property(nonatomic) NSUInteger thumbnailBytes;
@property(nonatomic, strong) NSTimer *clipboardTimer;
@property(nonatomic, strong) NSTimer *pasteTimer;
@property(nonatomic, strong) NSRunningApplication *targetApp;
@property(nonatomic, strong) id keyMonitor;
@property(nonatomic, strong) id outsideMonitor;
@property(nonatomic, strong) id localOutsideMonitor;
@property(nonatomic, strong) id wakeObserver;
@property(nonatomic, strong) id sleepObserver;
@property(nonatomic) NSInteger lastChangeCount;
@property(nonatomic) BOOL captureBusy;
@property(nonatomic) BOOL pasteBusy;
@property(nonatomic) BOOL recordingHotkey;
@property(nonatomic) BOOL hotkeyDown;
@property(nonatomic) BOOL smoke;
@property(nonatomic) uint32_t hotkeyCode;
@property(nonatomic) uint32_t hotkeyModifiers;
@property(nonatomic) uint32_t hotkeyID;
@property(nonatomic) EventHotKeyRef hotkeyRef;
@property(nonatomic) EventHandlerRef eventHandler;
@property(nonatomic, strong) dispatch_queue_t worker;
- (void)dismissHistory;
- (void)openHistory:(id)sender;
- (void)finishRecording;
@end

static NSString *KeyName(uint32_t code) {
    NSDictionary<NSNumber *, NSString *> *names = @{
        @0:@"A", @1:@"S", @2:@"D", @3:@"F", @4:@"H", @5:@"G", @6:@"Z", @7:@"X", @8:@"C", @9:@"V", @11:@"B",
        @12:@"Q", @13:@"W", @14:@"E", @15:@"R", @16:@"Y", @17:@"T", @18:@"1", @19:@"2", @20:@"3", @21:@"4", @22:@"6", @23:@"5",
        @24:@"=", @25:@"9", @26:@"7", @27:@"−", @28:@"8", @29:@"0", @30:@"]", @31:@"O", @32:@"U", @33:@"[", @34:@"I", @35:@"P",
        @37:@"L", @38:@"J", @39:@"'", @40:@"K", @41:@";", @42:@"\\", @43:@",", @44:@"/", @45:@"N", @46:@"M", @47:@".", @49:@"Space", @50:@"`",
        @96:@"F5", @97:@"F6", @98:@"F7", @99:@"F3", @100:@"F8", @101:@"F9", @103:@"F11", @109:@"F10", @111:@"F12", @118:@"F4", @120:@"F2", @122:@"F1"
    };
    return names[@(code)] ?: [NSString stringWithFormat:@"Key %u", code];
}
static NSString *HotkeyName(uint32_t code, uint32_t modifiers) {
    NSMutableString *name = [NSMutableString string];
    if (modifiers & controlKey) [name appendString:@"⌃"];
    if (modifiers & optionKey) [name appendString:@"⌥"];
    if (modifiers & shiftKey) [name appendString:@"⇧"];
    if (modifiers & cmdKey) [name appendString:@"⌘"];
    [name appendString:KeyName(code)];
    return name;
}
static uint32_t CarbonModifiers(NSEventModifierFlags flags) {
    uint32_t result = 0;
    if (flags & NSEventModifierFlagCommand) result |= cmdKey;
    if (flags & NSEventModifierFlagOption) result |= optionKey;
    if (flags & NSEventModifierFlagControl) result |= controlKey;
    if (flags & NSEventModifierFlagShift) result |= shiftKey;
    return result;
}
static NSTextField *Label(NSString *text, NSRect frame, CGFloat size) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size];
    return label;
}
static NSData *ImageThumbnail(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    uint64_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    uint64_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    if (!width || !height || width > MaxImagePixels || height > MaxImagePixels || width > MaxImagePixels / height) {
        CFRelease(source); return nil;
    }
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@160,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES,
        (__bridge NSString *)kCGImageSourceShouldCache:@NO
    };
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumb) return nil;
    NSMutableData *output = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    BOOL ok = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, thumb, NULL);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(thumb);
    return ok ? output : nil;
}

static OSStatus HotkeyCallback(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next;
    PasttyDelegate *owner = (__bridge PasttyDelegate *)context;
    EventHotKeyID identity = {0};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(identity), NULL, &identity) != noErr || identity.signature != HotkeySignature || identity.id != owner.hotkeyID) return eventNotHandledErr;
    if (GetEventKind(event) == kEventHotKeyReleased) { owner.hotkeyDown = NO; return noErr; }
    if (owner.recordingHotkey) {
        owner.hotkeyDown = YES;
        [owner finishRecording];
        owner.settingsMessage.stringValue = @"快捷键保持不变。";
        return noErr;
    }
    if (owner.hotkeyDown) return noErr;
    owner.hotkeyDown = YES;
    if (owner.panel.isVisible) [owner dismissHistory]; else [owner openHistory:nil];
    return noErr;
}

@implementation PasttyDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.smoke = getenv("PASTTY_SMOKE_TEST") != NULL;
    self.rows = @[];
    self.thumbnails = [NSMutableDictionary new];
    self.thumbnailCosts = [NSMutableDictionary new];
    self.thumbnailOrder = [NSMutableArray new];
    self.thumbnailViews = NSHashTable.weakObjectsHashTable;
    self.worker = dispatch_queue_create("org.stormaker.pastty.clipboard", DISPATCH_QUEUE_SERIAL);
    self.lastChangeCount = self.smoke ? 0 : NSPasteboard.generalPasteboard.changeCount;
    EventTypeSpec types[] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
    InstallEventHandler(GetApplicationEventTarget(), HotkeyCallback, 2, types, (__bridge void *)self, &_eventHandler);
    char *saved = pastty_get_hotkey();
    NSDictionary *hotkey = saved ? [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:saved] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    if (saved) pastty_free_string(saved);
    self.hotkeyCode = hotkey ? [hotkey[@"keycode"] unsignedIntValue] : 9;
    self.hotkeyModifiers = hotkey ? [hotkey[@"modifiers"] unsignedIntValue] : optionKey;
    BOOL registered = [self registerHotkey:self.hotkeyCode modifiers:self.hotkeyModifiers persist:NO];
    [self updateStatusItem];
    [self buildHistory];
    __weak PasttyDelegate *weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        PasttyDelegate *owner = weakSelf;
        if (!owner.recordingHotkey) return event;
        if (event.keyCode == 53) { [owner finishRecording]; return nil; }
        if (event.isARepeat) return nil;
        uint32_t modifiers = CarbonModifiers(event.modifierFlags);
        if (!(modifiers & (cmdKey | optionKey | controlKey)) || (event.keyCode == 9 && modifiers == cmdKey) || event.keyCode == 36 || event.keyCode == 48) {
            owner.settingsMessage.stringValue = @"请使用 ⌘、⌥ 或 ⌃ 组合键；⌘V 保留给系统粘贴。";
            return nil;
        }
        if ([owner registerHotkey:event.keyCode modifiers:modifiers persist:YES]) {
            [owner finishRecording];
            owner.settingsMessage.stringValue = @"快捷键已保存。";
        } else {
            owner.settingsMessage.stringValue = @"快捷键已被占用或保存失败，请换一个组合。";
        }
        return nil;
    }];
    self.outsideMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^(NSEvent *event) { (void)event; [weakSelf dismissHistory]; }];
    self.localOutsideMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^NSEvent *(NSEvent *event) {
        PasttyDelegate *owner = weakSelf;
        NSStatusBarButton *button = owner.statusItem.button;
        BOOL onStatusButton = button && event.window == button.window && NSPointInRect([button convertPoint:event.locationInWindow fromView:nil], button.bounds);
        if (owner.panel.isVisible && event.window != owner.panel && !onStatusButton) [owner dismissHistory];
        return event;
    }];
    NSNotificationCenter *workspaceNotifications = NSWorkspace.sharedWorkspace.notificationCenter;
    self.sleepObserver = [workspaceNotifications addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; [weakSelf.clipboardTimer invalidate]; weakSelf.clipboardTimer = nil; }];
    self.wakeObserver = [workspaceNotifications addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; [weakSelf startClipboardTimer]; [weakSelf checkClipboard]; }];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(reopenRequested:) name:@"org.stormaker.pastty.reopen" object:NSProcessInfo.processInfo.environment[@"PASTTY_DATA_DIR"] ?: @"main" suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    if (self.smoke) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ [self runSmokeChecks]; });
    } else {
        [self startClipboardTimer];
        NSAppleEventDescriptor *launchEvent = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
        OSType launchReason = [launchEvent paramDescriptorForKeyword:keyAEPropData].enumCodeValue;
        BOOL loginLaunch = launchEvent.eventID == kAEOpenApplication && (launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem);
        if (!loginLaunch && ![NSUserDefaults.standardUserDefaults boolForKey:@"hasLaunched"]) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"hasLaunched"];
            [self showSettings:nil];
        } else if (!loginLaunch && !registered) {
            [self showSettings:nil];
            self.settingsMessage.stringValue = @"历史快捷键注册失败，请选择其它组合键。";
        }
    }
}
- (BOOL)registerHotkey:(uint32_t)keycode modifiers:(uint32_t)modifiers persist:(BOOL)persist {
    if (self.hotkeyRef && keycode == self.hotkeyCode && modifiers == self.hotkeyModifiers) return YES;
    EventHotKeyRef candidate = NULL;
    uint32_t nextID = self.hotkeyID + 1;
    EventHotKeyID identity = {HotkeySignature, nextID};
    OSStatus status = RegisterEventHotKey(keycode, modifiers, identity, GetApplicationEventTarget(), 0, &candidate);
    if (status != noErr) return NO;
    if (persist && pastty_set_hotkey(keycode, modifiers) != 0) { UnregisterEventHotKey(candidate); return NO; }
    if (self.hotkeyRef) UnregisterEventHotKey(self.hotkeyRef);
    self.hotkeyRef = candidate;
    self.hotkeyID = nextID;
    self.hotkeyCode = keycode;
    self.hotkeyModifiers = modifiers;
    self.hotkeyDown = NO;
    self.hotkeyButton.title = HotkeyName(keycode, modifiers);
    return YES;
}
- (void)startClipboardTimer {
    [self.clipboardTimer invalidate];
    if (self.smoke) return;
    __weak PasttyDelegate *weakSelf = self;
    self.clipboardTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) { (void)timer; @autoreleasepool { [weakSelf checkClipboard]; } }];
    self.clipboardTimer.tolerance = 0.1;
}
- (void)checkClipboard {
    if (self.captureBusy || self.smoke) return;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    NSInteger count = board.changeCount;
    if (count == self.lastChangeCount) return;
    self.lastChangeCount = count;
    NSArray<NSPasteboardType> *types = board.types;
    for (NSString *ignored in @[PasttyMarker, @"org.nspasteboard.ConcealedType", @"org.nspasteboard.TransientType", @"org.nspasteboard.AutoGeneratedType"]) {
        if ([types containsObject:ignored]) return;
    }
    // File references and rich text do not become image/text history entries.
    if ([types containsObject:NSPasteboardTypeFileURL]) return;
    NSString *uti = nil;
    NSData *data = nil;
    if ([types containsObject:NSPasteboardTypePNG]) uti = NSPasteboardTypePNG;
    else if ([types containsObject:NSPasteboardTypeTIFF]) uti = NSPasteboardTypeTIFF;
    if (uti) data = [board dataForType:uti];
    else if ([types containsObject:NSPasteboardTypeString]) {
        uti = NSPasteboardTypeString;
        data = [[board stringForType:NSPasteboardTypeString] dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (board.changeCount != count) { self.lastChangeCount = count; return; }
    BOOL image = [uti isEqualToString:NSPasteboardTypePNG] || [uti isEqualToString:NSPasteboardTypeTIFF];
    if (!data.length || data.length > (image ? MaxImageBytes : MaxTextBytes)) return;
    self.captureBusy = YES;
    __weak PasttyDelegate *weakSelf = self;
    dispatch_async(self.worker, ^{
        @autoreleasepool {
            NSData *thumbnail = image ? ImageThumbnail(data) : nil;
            int status = 1;
            // Reject malformed or extreme pixel dimensions instead of decoding full originals.
            if (!image || thumbnail) status = pastty_capture(data.bytes, data.length, uti.UTF8String, thumbnail.bytes, thumbnail.length);
            dispatch_async(dispatch_get_main_queue(), ^{
                PasttyDelegate *owner = weakSelf;
                owner.captureBusy = NO;
                if (status < 0) owner.historyFooter.stringValue = @"保存历史失败，请检查磁盘空间。";
                if (owner.panel.isVisible && status == 0) [owner reloadHistory];
                [owner checkClipboard];
            });
        }
    });
}
- (void)updateStatusItem {
    if (!pastty_get_bool("show_icon", 1)) {
        if (self.statusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
        self.statusItem = nil;
        return;
    }
    if (self.statusItem) return;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"MenuIconTemplate" ofType:@"png"];
    NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if (!icon) icon = [NSImage imageWithSystemSymbolName:@"clipboard" accessibilityDescription:@"Pastty"];
    icon.size = NSMakeSize(18, 18);
    icon.template = YES;
    self.statusItem.button.image = icon;
    self.statusItem.button.toolTip = @"Pastty";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(openHistory:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp];
}
- (void)buildHistory {
    self.panel = [[PasttyPanel alloc] initWithContentRect:NSMakeRect(0, 0, 376, 124) styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel) backing:NSBackingStoreBuffered defer:NO];
    self.panel.title = @"Pastty";
    self.panel.level = NSFloatingWindowLevel;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.acceptsMouseMovedEvents = YES;
    NSVisualEffectView *content = [[NSVisualEffectView alloc] initWithFrame:self.panel.contentView.bounds];
    content.material = NSVisualEffectMaterialMenu;
    content.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    content.state = NSVisualEffectStateActive;
    content.wantsLayer = YES;
    content.layer.cornerRadius = 10;
    content.layer.masksToBounds = YES;
    self.panel.contentView = content;
    self.historyHeading = Label(@"Pastty", NSZeroRect, 12);
    self.historyHeading.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.historyHeading.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.historyHeading];
    self.historyCount = Label(@"", NSZeroRect, 11);
    self.historyCount.textColor = NSColor.tertiaryLabelColor;
    self.historyCount.alignment = NSTextAlignmentRight;
    [content addSubview:self.historyCount];
    self.historyFooter = Label(@"↑↓ 选择  ·  ↩ 粘贴  ·  Esc 关闭", NSZeroRect, 10.5);
    self.historyFooter.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.historyFooter];
    self.historyDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    self.historyDivider.boxType = NSBoxSeparator;
    [content addSubview:self.historyDivider];
    self.historySettings = [NSButton buttonWithTitle:@"设置…" target:self action:@selector(showSettings:)];
    self.historySettings.bordered = NO;
    self.historySettings.alignment = NSTextAlignmentLeft;
    self.historySettings.font = [NSFont menuFontOfSize:12];
    self.historySettings.keyEquivalent = @",";
    self.historySettings.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [content addSubview:self.historySettings];
    self.historyQuit = [NSButton buttonWithTitle:@"退出" target:self action:@selector(quit:)];
    self.historyQuit.bordered = NO;
    self.historyQuit.alignment = NSTextAlignmentRight;
    self.historyQuit.font = [NSFont menuFontOfSize:12];
    self.historyQuit.keyEquivalent = @"q";
    self.historyQuit.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [content addSubview:self.historyQuit];
    self.emptyHistory = Label(@"复制文字或图片后，会显示在这里", NSZeroRect, 12);
    self.emptyHistory.textColor = NSColor.secondaryLabelColor;
    self.emptyHistory.alignment = NSTextAlignmentCenter;
    [content addSubview:self.emptyHistory];
    self.scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scroll.hasVerticalScroller = YES;
    self.scroll.borderType = NSNoBorder;
    self.scroll.drawsBackground = NO;
    self.scroll.autohidesScrollers = YES;
    self.table = [[PasttyTable alloc] initWithFrame:NSMakeRect(0, 0, 364, 32)];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"history"];
    column.width = 364;
    [self.table addTableColumn:column];
    self.table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.table.headerView = nil;
    self.table.rowHeight = 30;
    self.table.intercellSpacing = NSMakeSize(0, 2);
    self.table.backgroundColor = NSColor.clearColor;
    self.table.focusRingType = NSFocusRingTypeNone;
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.target = self;
    self.table.action = @selector(selectHistory:);
    self.table.allowsMultipleSelection = NO;
    self.table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.table.style = NSTableViewStyleFullWidth;
    self.scroll.documentView = self.table;
    [content addSubview:self.scroll];
    __weak PasttyDelegate *weakSelf = self;
    self.table.acceptHandler = ^{ [weakSelf acceptSelected]; };
    self.table.dismissHandler = ^{ [weakSelf dismissHistory]; };
    self.panel.dismissHandler = ^{ [weakSelf dismissHistory]; };
    [self layoutHistory];
}
- (void)layoutHistory {
    const CGFloat width = 376;
    CGFloat listHeight = self.rows.count ? 0 : 42;
    for (NSUInteger i = 0; i < MIN((NSUInteger)8, self.rows.count); i++) {
        listHeight += [self.rows[i][@"kind"] isEqual:@"image"] ? 44 : 30;
        if (i > 0) listHeight += 2;
    }
    CGFloat height = 30 + listHeight + 58;
    NSRect frame = self.panel.frame;
    frame.origin.y += frame.size.height - height;
    frame.size = NSMakeSize(width, height);
    [self.panel setFrame:frame display:NO];
    self.historyHeading.frame = NSMakeRect(14, height - 24, 160, 18);
    self.historyCount.frame = NSMakeRect(width - 100, height - 23, 86, 16);
    self.historyCount.stringValue = [NSString stringWithFormat:@"%lu 项", (unsigned long)self.rows.count];
    self.scroll.frame = NSMakeRect(6, 58, width - 12, listHeight);
    self.scroll.hidden = self.rows.count == 0;
    self.table.tableColumns.firstObject.width = width - 12;
    self.emptyHistory.frame = NSMakeRect(14, 58 + (listHeight - 18) / 2, width - 28, 18);
    self.emptyHistory.hidden = self.rows.count > 0;
    self.historyDivider.frame = NSMakeRect(12, 53, width - 24, 1);
    self.historyFooter.frame = NSMakeRect(14, 32, width - 28, 16);
    self.historySettings.frame = NSMakeRect(8, 5, 92, 25);
    self.historyQuit.frame = NSMakeRect(width - 72, 5, 60, 25);
    if (self.panel.isVisible) [self positionHistory];
}
- (void)positionHistory {
    NSPoint point = self.historyAnchor;
    if (self.anchoredToStatusItem && self.statusItem.button.window) {
        NSRect button = [self.statusItem.button.window convertRectToScreen:[self.statusItem.button convertRect:self.statusItem.button.bounds toView:nil]];
        point = NSMakePoint(NSMidX(button), NSMinY(button) - 5);
    }
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) if (NSPointInRect(point, candidate.frame)) screen = candidate;
    NSRect visible = NSInsetRect(screen.visibleFrame, 6, 6);
    NSRect frame = self.panel.frame;
    frame.origin.x = self.anchoredToStatusItem ? point.x - frame.size.width / 2 : point.x + 8;
    frame.origin.y = point.y - frame.size.height - (self.anchoredToStatusItem ? 0 : 8);
    frame.origin.x = MAX(NSMinX(visible), MIN(frame.origin.x, NSMaxX(visible) - frame.size.width));
    frame.origin.y = MAX(NSMinY(visible), MIN(frame.origin.y, NSMaxY(visible) - frame.size.height));
    [self.panel setFrame:frame display:NO];
}
- (void)reloadHistory {
    char *json = pastty_list();
    NSArray *rows = json ? [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    if (json) pastty_free_string(json);
    self.rows = [rows isKindOfClass:NSArray.class] ? rows : @[];
    [self layoutHistory];
    [self.table reloadData];
    if (self.rows.count) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    self.historyFooter.stringValue = self.rows.count ? @"↑↓ 选择  ·  ↩ 粘贴  ·  Esc 关闭" : @"文字和图片，随时取用";
}
- (void)openHistory:(id)sender {
    if (self.pasteBusy) return;
    BOOL fromIcon = sender != nil && sender == self.statusItem.button;
    if (fromIcon && self.panel.isVisible) { [self dismissHistory]; return; }
    self.targetApp = NSWorkspace.sharedWorkspace.frontmostApplication;
    self.anchoredToStatusItem = fromIcon;
    self.historyAnchor = NSEvent.mouseLocation;
    [self checkClipboard];
    [self reloadHistory];
    [self positionHistory];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.table];
    self.statusItem.button.highlighted = fromIcon;
}
- (void)dismissHistory {
    if (!self.panel.isVisible) return;
    [self.panel orderOut:nil];
    self.statusItem.button.highlighted = NO;
    self.rows = @[];
    [self.table reloadData];
    for (NSImageView *view in self.thumbnailViews) view.image = nil;
    [self.thumbnails removeAllObjects];
    [self.thumbnailCosts removeAllObjects];
    [self.thumbnailOrder removeAllObjects];
    self.thumbnailBytes = 0;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return self.rows.count; }
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    (void)tableView;
    return [self.rows[row][@"kind"] isEqual:@"image"] ? 44 : 30;
}
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)column;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"entry" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 364, 30)];
        cell.identifier = @"entry";
        NSImageView *image = [[NSImageView alloc] initWithFrame:NSZeroRect];
        image.imageScaling = NSImageScaleProportionallyUpOrDown;
        image.contentTintColor = NSColor.secondaryLabelColor;
        [cell addSubview:image]; cell.imageView = image;
        [self.thumbnailViews addObject:image];
        NSTextField *text = Label(@"", NSZeroRect, 13);
        text.maximumNumberOfLines = 1;
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        text.usesSingleLineMode = YES;
        [cell addSubview:text]; cell.textField = text;
    }
    NSDictionary *item = self.rows[row];
    BOOL image = [item[@"kind"] isEqual:@"image"];
    CGFloat height = image ? 44 : 30;
    CGFloat leading = image ? 50 : 32;
    cell.imageView.frame = image ? NSMakeRect(10, 6, 32, 32) : NSMakeRect(11, 8, 14, 14);
    cell.textField.frame = NSMakeRect(leading, (height - 18) / 2, 352 - leading, 18);
    NSString *preview = [item[@"preview"] isKindOfClass:NSString.class] ? item[@"preview"] : @"";
    NSArray *lines = [preview componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    preview = [[lines filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    cell.textField.stringValue = image ? @"图片" : preview;
    cell.textField.toolTip = nil;
    cell.imageView.image = [NSImage imageWithSystemSymbolName:(image ? @"photo" : @"doc.plaintext") accessibilityDescription:nil];
    NSString *path = item[@"thumbnail_path"];
    if (image && [path isKindOfClass:NSString.class]) {
        NSImage *thumb = [self cachedThumbnailAtPath:path];
        if (thumb) cell.imageView.image = thumb;
    }
    return cell;
}
- (NSImage *)cachedThumbnailAtPath:(NSString *)path {
    NSImage *image = self.thumbnails[path];
    if (image) {
        [self.thumbnailOrder removeObject:path];
        [self.thumbnailOrder addObject:path];
        return image;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attributes || [attributes fileSize] > 256 * 1024) return nil;
    NSData *encoded = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!encoded) return nil;
    // Treat cached files as untrusted: inspect and downsample before allocating a bitmap.
    NSData *small = ImageThumbnail(encoded);
    if (!small) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)small, NULL);
    if (!source) return nil;
    CGImageRef bitmap = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES});
    CFRelease(source);
    if (!bitmap) return nil;
    NSUInteger cost = CGImageGetBytesPerRow(bitmap) * CGImageGetHeight(bitmap) + small.length;
    image = [[NSImage alloc] initWithCGImage:bitmap size:NSZeroSize];
    CGImageRelease(bitmap);
    if (!image || cost > ThumbnailCacheLimit) return nil;
    while (self.thumbnailBytes + cost > ThumbnailCacheLimit && self.thumbnailOrder.count) {
        NSString *oldest = self.thumbnailOrder.firstObject;
        self.thumbnailBytes -= self.thumbnailCosts[oldest].unsignedIntegerValue;
        [self.thumbnailOrder removeObjectAtIndex:0];
        [self.thumbnailCosts removeObjectForKey:oldest];
        [self.thumbnails removeObjectForKey:oldest];
    }
    self.thumbnails[path] = image;
    self.thumbnailCosts[path] = @(cost);
    [self.thumbnailOrder addObject:path];
    self.thumbnailBytes += cost;
    return image;
}
- (void)selectHistory:(id)sender { (void)sender; if (self.table.clickedRow >= 0) [self acceptSelected]; }
- (void)acceptSelected {
    if (self.smoke) return; // Smoke fixtures never write the system pasteboard.
    NSInteger row = self.table.selectedRow;
    if (self.pasteBusy || row < 0 || row >= (NSInteger)self.rows.count) return;
    int64_t identity = [self.rows[row][@"id"] longLongValue];
    self.pasteBusy = YES;
    unsigned char *bytes = NULL;
    size_t length = 0;
    char *uti = NULL;
    int loaded = pastty_load(identity, &bytes, &length, &uti);
    if (loaded != 0 || !bytes || !uti) {
        if (bytes) pastty_free_data(bytes, length);
        if (uti) pastty_free_string(uti);
        self.pasteBusy = NO;
        self.historyFooter.stringValue = @"无法读取这条历史，请重新选择。";
        return;
    }
    NSData *data = [NSData dataWithBytes:bytes length:length];
    NSString *type = [NSString stringWithUTF8String:uti];
    pastty_free_data(bytes, length);
    pastty_free_string(uti);
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    [board clearContents];
    BOOL written = [board setData:data forType:type];
    [board setString:@"1" forType:PasttyMarker];
    self.lastChangeCount = board.changeCount;
    NSInteger restoredChangeCount = self.lastChangeCount;
    [self dismissHistory];
    if (!written) { self.pasteBusy = NO; [self notify:@"写入剪贴板失败，请重试。" offerPermission:NO]; return; }
    NSRunningApplication *target = self.targetApp;
    if (!AXIsProcessTrusted() || !target || target.terminated || target.processIdentifier == NSProcessInfo.processInfo.processIdentifier) {
        self.pasteBusy = NO;
        [self notify:@"已复制。回到目标窗口后按 ⌘V；自动粘贴需要辅助功能权限。" offerPermission:!AXIsProcessTrusted()];
        return;
    }
    [target activateWithOptions:0];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
    __weak PasttyDelegate *weakSelf = self;
    self.pasteTimer = [NSTimer scheduledTimerWithTimeInterval:0.025 repeats:YES block:^(NSTimer *timer) {
        PasttyDelegate *owner = weakSelf;
        CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
        BOOL modifiersReleased = !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl | kCGEventFlagMaskShift));
        BOOL active = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == target.processIdentifier;
        if (NSPasteboard.generalPasteboard.changeCount != restoredChangeCount) {
            // A later user copy wins. Never inject or restore over the new clipboard.
            [timer invalidate]; owner.pasteTimer = nil; owner.pasteBusy = NO;
            return;
        }
        if (target.terminated || deadline.timeIntervalSinceNow < 0) {
            [timer invalidate]; owner.pasteTimer = nil; owner.pasteBusy = NO;
            [owner notify:@"已复制。请回到目标窗口按 ⌘V 粘贴。" offerPermission:NO];
        } else if (modifiersReleased && active) {
            [timer invalidate]; owner.pasteTimer = nil;
            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
            CGEventRef down = CGEventCreateKeyboardEvent(source, 9, true);
            CGEventRef up = CGEventCreateKeyboardEvent(source, 9, false);
            if (down && up) {
                CGEventSetFlags(down, kCGEventFlagMaskCommand);
                CGEventSetFlags(up, kCGEventFlagMaskCommand);
                CGEventPost(kCGSessionEventTap, down); CGEventPost(kCGSessionEventTap, up);
            }
            if (down) CFRelease(down); if (up) CFRelease(up); if (source) CFRelease(source);
            owner.pasteBusy = NO;
        }
    }];
}
- (void)notify:(NSString *)message offerPermission:(BOOL)offer {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Pastty";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    if (offer) [alert addButtonWithTitle:@"打开辅助功能设置"];
    NSModalResponse response = [alert runModal];
    if (offer && response == NSAlertSecondButtonReturn) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)buildSettings {
    if (self.settings) return;
    self.settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 270) styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    self.settings.title = @"Pastty 设置";
    self.settings.releasedWhenClosed = NO;
    self.settings.delegate = self;
    NSView *view = self.settings.contentView;
    self.iconToggle = [NSButton checkboxWithTitle:@"显示菜单栏图标" target:self action:@selector(changeIcon:)];
    self.iconToggle.frame = NSMakeRect(24, 211, 390, 26);
    [view addSubview:self.iconToggle];
    self.loginToggle = [NSButton checkboxWithTitle:@"登录后自动启动" target:self action:@selector(changeLogin:)];
    self.loginToggle.frame = NSMakeRect(24, 166, 390, 26);
    [view addSubview:self.loginToggle];
    [view addSubview:Label(@"历史快捷键", NSMakeRect(24, 122, 120, 24), 13)];
    self.hotkeyButton = [NSButton buttonWithTitle:HotkeyName(self.hotkeyCode, self.hotkeyModifiers) target:self action:@selector(recordHotkey:)];
    self.hotkeyButton.frame = NSMakeRect(230, 118, 182, 32);
    [view addSubview:self.hotkeyButton];
    self.settingsMessage = Label(@"自动粘贴需辅助功能权限；未授权时仍可手动 ⌘V。", NSMakeRect(24, 48, 392, 54), 11);
    self.settingsMessage.maximumNumberOfLines = 3;
    self.settingsMessage.textColor = NSColor.secondaryLabelColor;
    [view addSubview:self.settingsMessage];
    NSTextField *foot = Label(@"隐藏图标后，重新打开 Pastty 即可返回设置。", NSMakeRect(24, 17, 392, 20), 11);
    foot.textColor = NSColor.tertiaryLabelColor;
    [view addSubview:foot];
    [self.settings center];
}
- (void)showSettings:(id)sender {
    (void)sender;
    [self dismissHistory];
    [self buildSettings];
    self.iconToggle.state = pastty_get_bool("show_icon", 1) ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshLoginState];
    [NSApp activateIgnoringOtherApps:YES];
    [self.settings makeKeyAndOrderFront:nil];
}
- (void)changeIcon:(id)sender {
    (void)sender;
    if (pastty_set_bool("show_icon", self.iconToggle.state == NSControlStateValueOn) != 0) {
        self.settingsMessage.stringValue = @"设置未保存，请检查磁盘空间。";
        self.iconToggle.state = pastty_get_bool("show_icon", 1) ? NSControlStateValueOn : NSControlStateValueOff;
        return;
    }
    [self updateStatusItem];
}
- (void)refreshLoginState {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.loginToggle.state = status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginToggle.allowsMixedState = status == SMAppServiceStatusRequiresApproval;
    if (status == SMAppServiceStatusRequiresApproval) {
        self.loginToggle.state = NSControlStateValueMixed;
        self.settingsMessage.stringValue = @"请在系统设置 → 通用 → 登录项中允许 Pastty。";
    }
}
- (void)changeLogin:(id)sender {
    (void)sender;
    if (self.smoke) { [self refreshLoginState]; return; }
    NSError *error = nil;
    BOOL desired = self.loginToggle.state != NSControlStateValueOff;
    BOOL ok = desired ? [SMAppService.mainAppService registerAndReturnError:&error] : [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (!ok) self.settingsMessage.stringValue = @"自启动设置未生效，请在系统登录项中检查 Pastty。";
    else self.settingsMessage.stringValue = @"自启动设置已更新。";
    [self refreshLoginState];
    if (SMAppService.mainAppService.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
}
- (void)recordHotkey:(id)sender {
    (void)sender;
    self.recordingHotkey = YES;
    self.hotkeyButton.title = @"按下新组合键…";
    self.settingsMessage.stringValue = @"按 Esc 取消；⌘V 保留为系统粘贴。";
}
- (void)finishRecording {
    self.recordingHotkey = NO;
    self.hotkeyButton.title = HotkeyName(self.hotkeyCode, self.hotkeyModifiers);
}
- (void)windowWillClose:(NSNotification *)notification { if (notification.object == self.settings) [self finishRecording]; }
- (void)runSmokeChecks {
    BOOL isolated = NSProcessInfo.processInfo.environment[@"PASTTY_DATA_DIR"].length > 0;
    SmokeCheck(isolated, "isolated-data-directory");
    if (isolated) {
        NSArray<NSString *> *fixtures = @[@"Pastty — 简单复制，轻松粘贴", @"https://github.com/stormaker/Pastty", @"文字和图片，只保留需要的内容", @"这是一段较长的文字记录，在菜单中保持单行显示，更多内容会自动省略。", @"第一行\n第二行也能整齐预览"];
        BOOL capturedText = YES;
        for (NSString *fixture in fixtures) {
            NSData *text = [fixture dataUsingEncoding:NSUTF8StringEncoding];
            if (pastty_capture(text.bytes, text.length, NSPasteboardTypeString.UTF8String, NULL, 0) < 0) capturedText = NO;
        }
        SmokeCheck(capturedText, "text-fixture-persisted");
        uint8_t pixel[] = {38, 123, 244, 255};
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(colorSpace);
        CGImageRef bitmap = context ? CGBitmapContextCreateImage(context) : NULL;
        NSMutableData *png = [NSMutableData data];
        CGImageDestinationRef destination = bitmap ? CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL) : NULL;
        BOOL encoded = NO;
        if (destination) { CGImageDestinationAddImage(destination, bitmap, NULL); encoded = CGImageDestinationFinalize(destination); CFRelease(destination); }
        if (bitmap) CGImageRelease(bitmap); if (context) CGContextRelease(context);
        NSData *thumbnail = encoded ? ImageThumbnail(png) : nil;
        int imageCaptured = thumbnail ? pastty_capture(png.bytes, png.length, NSPasteboardTypePNG.UTF8String, thumbnail.bytes, thumbnail.length) : -1;
        SmokeCheck(imageCaptured >= 0, "image-fixture-persisted");
        [self openHistory:nil];
        NSUInteger texts = 0, images = 0;
        NSImageView *imageView = nil;
        for (NSUInteger row = 0; row < self.rows.count; row++) {
            NSDictionary *item = self.rows[row];
            if ([item[@"kind"] isEqual:@"text"]) texts++;
            if ([item[@"kind"] isEqual:@"image"]) {
                images++;
                NSTableCellView *cell = (NSTableCellView *)[self tableView:self.table viewForTableColumn:self.table.tableColumns.firstObject row:row];
                imageView = cell.imageView;
            }
        }
        SmokeCheck(self.panel.isVisible && self.rows.count >= fixtures.count + 1 && texts >= fixtures.count && images >= 1, "history-panel-text-and-image-rows");
        SmokeCheck([self.historyHeading.stringValue isEqualToString:@"Pastty"] && [self.panel.title isEqualToString:@"Pastty"], "history-menu-title-pastty");
        BOOL focused = [self.panel makeFirstResponder:self.table] && self.panel.firstResponder == self.table;
        SmokeCheck(focused, "history-table-is-first-responder");
        [self.table keyDown:SmokeKeyEvent(self.panel, 125, NSDownArrowFunctionKey)];
        SmokeCheck(self.table.selectedRow == 1, "history-down-key-selects-next-row");
        [self.table keyDown:SmokeKeyEvent(self.panel, 126, NSUpArrowFunctionKey)];
        SmokeCheck(self.table.selectedRow == 0, "history-up-key-selects-previous-row");
        SmokeCheck(imageView.image != nil && self.thumbnails.count == 1 && self.thumbnailBytes > 0 && self.thumbnailBytes <= ThumbnailCacheLimit, "thumbnail-loaded-within-byte-budget");
        [self.table keyDown:SmokeKeyEvent(self.panel, 53, 27)];
        SmokeCheck(!self.panel.isVisible, "history-escape-key-dismisses-panel");
        BOOL released = self.rows.count == 0 && self.thumbnails.count == 0 && self.thumbnailBytes == 0;
        for (NSImageView *view in self.thumbnailViews) if (view.image) released = NO;
        SmokeCheck(released && imageView.image == nil, "history-dismissal-releases-images-and-models");
        [self showSettings:nil];
        SmokeCheck(self.settings.isVisible && self.iconToggle && self.loginToggle && self.hotkeyButton, "three-settings-controls");
        SmokeCheck(self.clipboardTimer == nil && self.captureBusy == NO && self.pasteBusy == NO, "smoke-does-not-monitor-or-paste");
    }
    NSTimeInterval hold = MIN(120, MAX(0, [NSProcessInfo.processInfo.environment[@"PASTTY_SMOKE_HOLD_SECONDS"] doubleValue]));
    if (hold > 0 && isolated) {
        if ([NSProcessInfo.processInfo.environment[@"PASTTY_SMOKE_VIEW"] isEqualToString:@"history"]) {
            [self.settings orderOut:nil];
            [self openHistory:nil];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self stopSmoke]; });
    } else [self stopSmoke];
}
- (void)stopSmoke {
    [self applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
}
- (void)handleReopen {
    if (self.smoke && [NSProcessInfo.processInfo.environment[@"PASTTY_SMOKE_VIEW"] isEqualToString:@"history"]) {
        [self.settings orderOut:nil];
        if (!self.panel.isVisible) [self openHistory:nil];
        else {
            [self.panel makeKeyAndOrderFront:nil];
            [self.panel makeFirstResponder:self.table];
        }
    } else [self showSettings:nil];
}
- (void)reopenRequested:(NSNotification *)notification { (void)notification; dispatch_async(dispatch_get_main_queue(), ^{ [self handleReopen]; }); }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { (void)sender; (void)flag; [self handleReopen]; return YES; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return NO; }
- (void)applicationDidBecomeActive:(NSNotification *)notification { (void)notification; if (self.settings.isVisible) [self refreshLoginState]; }
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.clipboardTimer invalidate]; [self.pasteTimer invalidate];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    if (self.hotkeyRef) UnregisterEventHotKey(self.hotkeyRef);
    if (self.eventHandler) RemoveEventHandler(self.eventHandler);
    if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
    if (self.outsideMonitor) [NSEvent removeMonitor:self.outsideMonitor];
    if (self.localOutsideMonitor) [NSEvent removeMonitor:self.localOutsideMonitor];
    if (self.wakeObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self.wakeObserver];
    if (self.sleepObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self.sleepObserver];
}
@end

int pastty_run(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) PasttyDelegate *delegate = [PasttyDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return SmokeResult;
}

void pastty_reopen_existing(void) {
    @autoreleasepool {
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"org.stormaker.pastty.reopen" object:NSProcessInfo.processInfo.environment[@"PASTTY_DATA_DIR"] ?: @"main" userInfo:nil deliverImmediately:YES];
    }
}
