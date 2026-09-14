#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

@interface JoyHarnessAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSURL *runtimeURL;
@property(nonatomic, strong) NSURL *ipcURL;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) BOOL paused;
@property(nonatomic, strong) NSDictionary *status;
@end

@implementation JoyHarnessAppDelegate

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    NSString *runtimePath = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"JoyHarnessRuntimePath"];
    if (runtimePath.length == 0) {
        runtimePath = [@"~/Applications/JoyHarness" stringByExpandingTildeInPath];
    } else {
        runtimePath = [runtimePath stringByExpandingTildeInPath];
    }
    _runtimeURL = [NSURL fileURLWithPath:runtimePath isDirectory:YES];
    _ipcURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"joyharness-runtime"] isDirectory:YES];
    _status = @{};
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self configureStatusItem];
    [self startService];
    [self refreshStatus];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
}

- (void)configureStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.toolTip = @"JoyHarness";
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:@"gamecontroller" accessibilityDescription:@"JoyHarness"];
        image.template = YES;
        button.image = image;
    }
    button.title = @" --";
    self.statusItem.menu = [self buildMenu];
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItem:[self disabledItem:@"JoyHarness"]];
    [menu addItem:[self disabledItem:@"左手柄：--"]];
    [menu addItem:[self disabledItem:@"右手柄：--"]];
    [menu addItem:[self disabledItem:@"当前方案：当前配置"]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self actionItem:@"暂停映射" action:@selector(togglePaused)]];
    [menu addItem:[self actionItem:@"打开快捷键配置..." action:@selector(openSettings)]];
    [menu addItem:[self actionItem:@"打开辅助功能授权..." action:@selector(openAccessibilitySettings)]];
    [menu addItem:[self actionItem:@"定位按键权限程序..." action:@selector(revealKeyboardPermissionTarget)]];
    [menu addItem:[self actionItem:@"刷新状态" action:@selector(refreshStatusAction)]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self actionItem:@"重新启动服务" action:@selector(restartService)]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self actionItem:@"退出 JoyHarness" action:@selector(quit)]];
    return menu;
}

- (NSMenuItem *)disabledItem:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}

- (NSMenuItem *)actionItem:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)startService {
    [self runScript:@"scripts/start-joyharness.sh"];
}

- (void)restartService {
    [self runScript:@"scripts/stop-joyharness.sh"];
    [self startService];
    [self refreshStatus];
}

- (void)togglePaused {
    self.paused = !self.paused;
    [self ensureIpcDirectory];
    NSURL *pauseURL = [self.ipcURL URLByAppendingPathComponent:@"paused"];
    if (self.paused) {
        [[NSData data] writeToURL:pauseURL atomically:YES];
    } else {
        [[NSFileManager defaultManager] removeItemAtURL:pauseURL error:nil];
    }
    [self refreshStatus];
}

- (void)openSettings {
    [self ensureIpcDirectory];
    NSURL *settingsURL = [self.ipcURL URLByAppendingPathComponent:@"show-settings"];
    [[NSData data] writeToURL:settingsURL atomically:YES];
}

- (void)openAccessibilitySettings {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

    NSURL *privacyURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:privacyURL];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSBundle mainBundle].bundleURL]];
}

- (void)revealKeyboardPermissionTarget {
    NSURL *privacyURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:privacyURL];

    NSArray<NSString *> *candidatePaths = @[
        [[self.runtimeURL URLByAppendingPathComponent:@".venv/bin/python3.12"] path],
        [[self.runtimeURL URLByAppendingPathComponent:@".venv/bin/python"] path],
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/python3.12"]
    ];

    NSMutableArray<NSURL *> *existingURLs = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in candidatePaths) {
        if ([fileManager fileExistsAtPath:path]) {
            [existingURLs addObject:[NSURL fileURLWithPath:path]];
        }
    }
    if (existingURLs.count > 0) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:existingURLs];
    }
}

- (void)refreshStatusAction {
    [self refreshStatus];
}

- (void)quit {
    [self runScript:@"scripts/stop-joyharness.sh"];
    [NSApp terminate:nil];
}

- (void)refreshStatus {
    self.status = [self readStatus];
    self.paused = [self isStatusPaused] || [[NSFileManager defaultManager] fileExistsAtPath:[[self.ipcURL URLByAppendingPathComponent:@"paused"] path]];
    [self updateStatusItem];
    [self updateMenu];
}

- (NSDictionary *)readStatus {
    NSURL *statusURL = [self.ipcURL URLByAppendingPathComponent:@"status.json"];
    NSData *data = [NSData dataWithContentsOfURL:statusURL];
    if (!data) {
        return @{};
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : @{};
}

- (void)updateStatusItem {
    NSStatusBarButton *button = self.statusItem.button;
    button.title = [@" " stringByAppendingString:[self titleText]];
    button.toolTip = [self summaryText];
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:[self symbolName] accessibilityDescription:[self summaryText]];
        image.template = YES;
        button.image = image;
    }
}

- (void)updateMenu {
    NSArray<NSMenuItem *> *items = self.statusItem.menu.itemArray;
    if (items.count < 8) {
        return;
    }
    items[0].title = [self summaryText];
    items[1].title = [self sideText:@"左手柄" side:@"L"];
    items[2].title = [self sideText:@"右手柄" side:@"R"];
    items[3].title = @"当前方案：当前配置";
    items[5].title = self.paused ? @"继续映射" : @"暂停映射";
    items[5].state = self.paused ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)ensureIpcDirectory {
    [[NSFileManager defaultManager] createDirectoryAtURL:self.ipcURL withIntermediateDirectories:YES attributes:nil error:nil];
}

- (int)runScript:(NSString *)relativePath {
    NSURL *scriptURL = [self.runtimeURL URLByAppendingPathComponent:relativePath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:scriptURL.path]) {
        NSLog(@"JoyHarness script is not executable: %@", scriptURL.path);
        return 127;
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[scriptURL.path];
    task.currentDirectoryURL = self.runtimeURL;
    @try {
        [task launch];
        [task waitUntilExit];
        return task.terminationStatus;
    } @catch (NSException *exception) {
        NSLog(@"JoyHarness failed to run %@: %@", scriptURL.path, exception.reason);
        return 126;
    }
}

- (BOOL)isRunning {
    id value = self.status[@"running"];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

- (BOOL)isStatusPaused {
    id value = self.status[@"paused"];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

- (NSString *)connectionMode {
    id value = self.status[@"connection_mode"];
    return [value isKindOfClass:[NSString class]] ? value : @"none";
}

- (NSDictionary *)batteryMap {
    id value = self.status[@"battery"];
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

- (NSArray *)batteryForSide:(NSString *)side {
    id value = [self batteryMap][side];
    return [value isKindOfClass:[NSArray class]] ? value : @[@"unknown", @(-1)];
}

- (NSString *)batteryStatusForSide:(NSString *)side {
    NSArray *battery = [self batteryForSide:side];
    return battery.count > 0 && [battery[0] isKindOfClass:[NSString class]] ? battery[0] : @"unknown";
}

- (NSInteger)batteryPercentForSide:(NSString *)side {
    NSArray *battery = [self batteryForSide:side];
    return battery.count > 1 && [battery[1] respondsToSelector:@selector(integerValue)] ? [battery[1] integerValue] : -1;
}

- (BOOL)modeIncludesSide:(NSString *)side {
    NSString *mode = [self connectionMode];
    return [mode isEqualToString:@"dual"] ||
        ([side isEqualToString:@"L"] && [mode isEqualToString:@"single_left"]) ||
        ([side isEqualToString:@"R"] && [mode isEqualToString:@"single_right"]);
}

- (BOOL)isConnectedSide:(NSString *)side {
    NSString *status = [self batteryStatusForSide:side];
    return [@[@"connected", @"charging", @"discharging"] containsObject:status] || [self modeIncludesSide:side];
}

- (NSString *)summaryText {
    NSString *state = nil;
    BOOL left = [self isConnectedSide:@"L"];
    BOOL right = [self isConnectedSide:@"R"];
    if (left && right) {
        state = @"双手柄已连接";
    } else if (left) {
        state = @"左手柄已连接";
    } else if (right) {
        state = @"右手柄已连接";
    } else if ([self isRunning]) {
        state = @"未连接";
    } else {
        state = @"服务未运行";
    }
    return self.paused ? [NSString stringWithFormat:@"JoyHarness - %@（已暂停）", state] : [NSString stringWithFormat:@"JoyHarness - %@", state];
}

- (NSString *)titleText {
    NSInteger left = [self batteryPercentForSide:@"L"];
    NSInteger right = [self batteryPercentForSide:@"R"];
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    if ([self isConnectedSide:@"L"] && left >= 0) {
        [values addObject:@(left)];
    }
    if ([self isConnectedSide:@"R"] && right >= 0) {
        [values addObject:@(right)];
    }
    if (values.count > 0) {
        NSInteger minValue = values.firstObject.integerValue;
        for (NSNumber *value in values) {
            minValue = MIN(minValue, value.integerValue);
        }
        return [NSString stringWithFormat:@"%ld%%", (long)minValue];
    }
    if ([self isConnectedSide:@"L"] && [self isConnectedSide:@"R"]) {
        return @"双连";
    }
    if ([self isConnectedSide:@"L"]) {
        return @"左连";
    }
    if ([self isConnectedSide:@"R"]) {
        return @"右连";
    }
    return [self isRunning] ? @"未连" : @"离线";
}

- (NSString *)symbolName {
    if (![self isRunning]) {
        return @"exclamationmark.circle";
    }
    if (self.paused) {
        return @"pause.circle";
    }
    if ([self isConnectedSide:@"L"] || [self isConnectedSide:@"R"]) {
        return @"gamecontroller.fill";
    }
    return @"gamecontroller";
}

- (NSString *)sideText:(NSString *)label side:(NSString *)side {
    if (![self isConnectedSide:side]) {
        return [NSString stringWithFormat:@"%@：未连接", label];
    }
    NSInteger percent = [self batteryPercentForSide:side];
    if (percent < 0) {
        return [NSString stringWithFormat:@"%@：已连接，电量读取中", label];
    }
    NSString *status = [self batteryStatusForSide:side];
    if ([status isEqualToString:@"charging"]) {
        return [NSString stringWithFormat:@"%@：%ld%% 充电中", label, (long)percent];
    }
    return [NSString stringWithFormat:@"%@：%ld%% 电量", label, (long)percent];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        JoyHarnessAppDelegate *delegate = [[JoyHarnessAppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
