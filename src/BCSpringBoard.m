#import "BCSpringBoard.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

// Private iOS 6 SpringBoard declarations verified against iOS 6.1.3 (10B329) SpringBoard binary.
@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
- (NSString *)displayIdentifier;
- (NSString *)displayName;
- (int)activationState;
- (BOOL)isRunning;
- (BOOL)isSystemApplication;
- (BOOL)isSystemProvisioningApplication;
- (BOOL)isMobilePhone;
- (BOOL)isWebApplication;
- (BOOL)isSameExecutableAsApplication:(SBApplication *)app;
- (BOOL)isRecordingAudio;
- (BOOL)isNowRecordingApplication;
- (BOOL)isAnyTerminationAssertionHeld;
- (BOOL)hasBeenFrontmost;
- (void)setHasBeenFrontmost:(BOOL)flag;
- (void)setDeactivationSetting:(unsigned int)setting flag:(BOOL)flag;
- (void)setNowPlayingWithAudio:(BOOL)playing;
- (void)didExitWithInfo:(id)info type:(int)type;
- (void)kill;
@end

@interface SBApplicationController : NSObject
+ (id)sharedInstance;
+ (id)sharedInstanceIfExists;
- (NSArray *)allApplications;
- (SBApplication *)applicationWithDisplayIdentifier:(NSString *)displayID;
- (SBApplication *)applicationCurrentlyRecordingAudio;
- (NSArray *)applicationsWithBundleIdentifier:(NSString *)bundleID;
@end

@interface SBAppSwitcherModel : NSObject
+ (id)sharedInstance;
- (NSArray *)snapshot;
- (void)remove:(NSString *)displayIdentifier;
@end

@interface SBAppSwitcherBarView : UIView
- (void)removeIconWithDisplayIdentifier:(NSString *)displayIdentifier;
@end

@interface SBAppSwitcherController : NSObject
+ (id)sharedInstance;
+ (id)sharedInstanceIfAvailable;
- (void)_removeApplicationFromRecents:(SBApplication *)app;
@end

@interface SBUIController : NSObject
+ (id)sharedInstance;
+ (id)sharedInstanceIfExists;
- (void)removeAppFromSwitchAppList:(SBApplication *)app;
@end

@interface SBMediaController : NSObject
+ (id)sharedInstance;
- (BOOL)isPlaying;
- (SBApplication *)nowPlayingApplication;
@end

@interface SBTelephonyManager : NSObject
+ (id)sharedTelephonyManagerCreatingIfNecessary:(BOOL)create;
- (BOOL)inCall;
- (BOOL)inCallUsingReceiverForcingRoutingToReceiver:(BOOL)force;
@end

@interface SBAwayController : NSObject
+ (id)sharedAwayController;
+ (id)sharedAwayControllerIfExists;
- (BOOL)isLocked;
@end

@interface SBWorkspaceEvent : NSObject
+ (id)eventWithLabel:(NSString *)label handler:(void (^)(void))handler;
@end

@interface SBWorkspaceEventQueue : NSObject
+ (id)sharedInstance;
- (void)executeOrAppendEvent:(id)event;
@end

@interface UIApplication (BCSpringBoardAdditions)
- (SBApplication *)_accessibilityFrontMostApplication;
- (SBApplication *)nowPlayingApp;
- (BOOL)isNowPlayingAppPlaying;
- (BOOL)isMusicPlayerPlaying;
@end

// Activation states in iOS 6.1.3 -[SBApplication _stringForActivationState:]:
// 0 = NOT RUNNING
// 1 = ACTIVATED
// 2 = ACTIVATING
// 3 = DEACTIVATING_EVENTS_ONLY
// 4 = DEACTIVATED_EVENTS_ONLY (e.g. alert/switcher over foreground app)
// 5 = DEACTIVATING
// 6 = DEACTIVATED (backgrounded / suspended)
typedef NS_ENUM(int, BCSBActivationState) {
    BCSBActivationStateNotRunning             = 0,
    BCSBActivationStateActivated              = 1,
    BCSBActivationStateActivating             = 2,
    BCSBActivationStateDeactivatingEventsOnly = 3,
    BCSBActivationStateDeactivatedEventsOnly  = 4,
    BCSBActivationStateDeactivating           = 5,
    BCSBActivationStateDeactivated            = 6,
};

typedef void (*BCBKSForceQuitFn)(NSString *bundleID, int reason, int report, NSString *description);

static BCBKSForceQuitFn BCGetBKSForceQuitFunction(void)
{
    static BCBKSForceQuitFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (BCBKSForceQuitFn)dlsym(RTLD_DEFAULT, "BKSTerminateApplicationForReasonAndReportWithDescription");
    });
    return fn;
}

static NSSet *BCSystemExcludedBundleIDs(void)
{
    static NSSet *excluded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        excluded = [NSSet setWithArray:@[
            @"com.apple.springboard",
            @"com.apple.AdSheet",
            @"com.apple.AdSheetPhone",
            @"com.apple.AdSheetPad",
            @"com.apple.DataActivation",
            @"com.apple.TrustMe",
            @"com.apple.WebSheet",
            @"com.apple.iosdiagnostics",
            @"com.apple.purplebuddy",
            @"com.apple.DemoApp",
            @"com.apple.fieldtest",
            @"com.apple.MailCompositionService",
            @"com.apple.MessagesViewService",
            @"com.apple.PassbookUIService",
            @"com.apple.gamecenter.GameCenterUIService",
            @"com.apple.social.remoteui.SocialUIService",
            @"com.saurik.Cydia",
        ]];
    });
    return excluded;
}

@implementation BCSpringBoardManager {
    BOOL _started;
    NSMutableArray *_recentActiveOrder; // displayIdentifiers, index 0 = most recently active
    NSMutableSet *_nowPlayingBundleIDs; // bundleIdentifiers with setNowPlayingWithAudio:YES
    NSString *_currentFrontmostID;
    NSString *_lastFrontmostBeforeLockID;
    BOOL _enforceScheduled;
    int _prefsNotifyToken;
    int _closeNowNotifyToken;
    int _dumpNotifyToken;
}

+ (instancetype)shared
{
    static BCSpringBoardManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[BCSpringBoardManager alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _recentActiveOrder   = [[NSMutableArray alloc] init];
        _nowPlayingBundleIDs = [[NSMutableSet alloc] init];
        _prefsNotifyToken    = -1;
        _closeNowNotifyToken = -1;
        _dumpNotifyToken     = -1;
    }
    return self;
}

- (void)start
{
    if (_started) return;
    _started = YES;

    [[BCSettings shared] reload];
    [self seedRecentAppsFromSwitcher];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(handleActivationStateChange:)
               name:@"SBApplicationActivationStateDidChange"
             object:nil];
    [nc addObserver:self
           selector:@selector(handleDeviceLocked:)
               name:@"SBAwayControllerFrontLockedNotification"
             object:nil];
    [nc addObserver:self
           selector:@selector(handleDeviceLocked:)
               name:@"SBAwayControllerRelockedNotification"
             object:nil];

    __weak BCSpringBoardManager *weakSelf = self;
    notify_register_dispatch(BCPrefsChangedNotification, &_prefsNotifyToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        [[BCSettings shared] reload];
        [weakSelf scheduleEnforceCapWithDelay:0.25 reason:@"PreferencesChanged"];
    });

    notify_register_dispatch(BCCloseNowNotification, &_closeNowNotifyToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        [[BCSettings shared] reload];
        [weakSelf closeAllUnusedBackgroundAppsWithReason:@"ManualCloseNow" includeFrontmost:NO];
    });

    notify_register_dispatch(BCDebugDumpNotification, &_dumpNotifyToken, dispatch_get_main_queue(), ^(int token) {
        (void)token;
        NSDictionary *dump = [weakSelf diagnosticDump];
        [dump writeToFile:BCDebugDumpPlistPath atomically:YES];
    });

    BCLog(@"Backcap %@ started (enabled=%d, maxApps=%ld, mode=%ld, killOnLock=%d, keepPlaying=%d)",
          BCVersion,
          (int)[BCSettings shared].enabled,
          (long)[BCSettings shared].maxApps,
          (long)[BCSettings shared].closeMode,
          (int)[BCSettings shared].killOnLock,
          (int)[BCSettings shared].keepPlaying);
}

- (void)seedRecentAppsFromSwitcher
{
    Class modelCls = NSClassFromString(@"SBAppSwitcherModel");
    if (!modelCls || ![modelCls respondsToSelector:@selector(sharedInstance)]) return;
    SBAppSwitcherModel *model = [modelCls sharedInstance];
    if (![model respondsToSelector:@selector(snapshot)]) return;
    NSArray *snap = [model snapshot];
    if (![snap isKindOfClass:[NSArray class]]) return;

    for (id item in snap) {
        if ([item isKindOfClass:[NSString class]] && [(NSString *)item length]) {
            if (![_recentActiveOrder containsObject:item]) {
                [_recentActiveOrder addObject:item];
            }
        }
    }

    SBApplication *front = [self currentFrontmostApplication];
    NSString *frontID = [self identifierForApplication:front];
    if (frontID.length) {
        _currentFrontmostID = [frontID copy];
        _lastFrontmostBeforeLockID = [frontID copy];
        [_recentActiveOrder removeObject:frontID];
        [_recentActiveOrder insertObject:frontID atIndex:0];
    }
}

#pragma mark - Helpers

- (NSString *)identifierForApplication:(SBApplication *)app
{
    if (!app) return nil;
    if ([app respondsToSelector:@selector(displayIdentifier)]) {
        NSString *disp = [app displayIdentifier];
        if (disp.length) return disp;
    }
    if ([app respondsToSelector:@selector(bundleIdentifier)]) {
        return [app bundleIdentifier];
    }
    return nil;
}

- (SBApplication *)applicationForIdentifier:(NSString *)ident
{
    if (!ident.length) return nil;
    Class ctrlCls = NSClassFromString(@"SBApplicationController");
    if (!ctrlCls) return nil;
    SBApplicationController *ctrl = [ctrlCls respondsToSelector:@selector(sharedInstanceIfExists)]
        ? [ctrlCls sharedInstanceIfExists]
        : ([ctrlCls respondsToSelector:@selector(sharedInstance)] ? [ctrlCls sharedInstance] : nil);
    if (!ctrl) return nil;

    if ([ctrl respondsToSelector:@selector(applicationWithDisplayIdentifier:)]) {
        SBApplication *app = [ctrl applicationWithDisplayIdentifier:ident];
        if (app) return app;
    }
    if ([ctrl respondsToSelector:@selector(applicationsWithBundleIdentifier:)]) {
        NSArray *apps = [ctrl applicationsWithBundleIdentifier:ident];
        if ([apps isKindOfClass:[NSArray class]] && apps.count > 0) {
            return apps[0];
        }
    }
    return nil;
}

- (SBApplication *)currentFrontmostApplication
{
    UIApplication *sb = [UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
        SBApplication *front = [sb _accessibilityFrontMostApplication];
        if (front) return front;
    }
    return nil;
}

- (BOOL)isDeviceCurrentlyLocked
{
    Class awayCls = NSClassFromString(@"SBAwayController");
    if (!awayCls) return NO;
    SBAwayController *away = [awayCls respondsToSelector:@selector(sharedAwayControllerIfExists)]
        ? [awayCls sharedAwayControllerIfExists]
        : ([awayCls respondsToSelector:@selector(sharedAwayController)] ? [awayCls sharedAwayController] : nil);
    if (away && [away respondsToSelector:@selector(isLocked)]) {
        return [away isLocked];
    }
    return NO;
}

- (BOOL)isApplicationForegroundOrTransitioning:(SBApplication *)app
{
    if (!app || ![app respondsToSelector:@selector(activationState)]) return NO;
    int state = [app activationState];
    return (state == BCSBActivationStateActivated ||
            state == BCSBActivationStateActivating ||
            state == BCSBActivationStateDeactivatingEventsOnly ||
            state == BCSBActivationStateDeactivatedEventsOnly);
}

#pragma mark - Audio & Protection Detection

- (void)noteApplication:(id)rawApp nowPlayingWithAudio:(BOOL)playing
{
    SBApplication *app = (SBApplication *)rawApp;
    NSString *bundleID = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : nil;
    if (!bundleID.length) return;

    if (playing) {
        [_nowPlayingBundleIDs addObject:bundleID];
        if (BCDebugEnabled()) {
            BCLog(@"App now playing audio: %@", bundleID);
        }
    } else {
        [_nowPlayingBundleIDs removeObject:bundleID];
        if (BCDebugEnabled()) {
            BCLog(@"App stopped playing audio: %@", bundleID);
        }
    }
}

- (void)noteApplicationDidExit:(id)rawApp
{
    SBApplication *app = (SBApplication *)rawApp;
    NSString *bundleID = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : nil;
    if (bundleID.length) {
        [_nowPlayingBundleIDs removeObject:bundleID];
    }
}

- (BOOL)isApplicationActivelyInUse:(SBApplication *)app reason:(NSString **)outReason
{
    if (!app) return NO;
    NSString *bundleID = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : nil;
    if (!bundleID.length) return NO;

    // 1. Check SpringBoard's per-app setNowPlayingWithAudio: state (Pandora, Spotify, Spot6, Muzika, etc.)
    if ([_nowPlayingBundleIDs containsObject:bundleID] && [app isRunning]) {
        if (outReason) *outReason = @"NowPlayingAudio";
        return YES;
    }

    // 2. Check SBMediaController's nowPlayingApplication
    Class mediaCls = NSClassFromString(@"SBMediaController");
    if (mediaCls && [mediaCls respondsToSelector:@selector(sharedInstance)]) {
        SBMediaController *media = [mediaCls sharedInstance];
        if (media && [media respondsToSelector:@selector(isPlaying)] && [media isPlaying]) {
            if ([media respondsToSelector:@selector(nowPlayingApplication)]) {
                SBApplication *npApp = [media nowPlayingApplication];
                if (npApp == app || (npApp && [[npApp bundleIdentifier] isEqualToString:bundleID])) {
                    if (outReason) *outReason = @"SBMediaControllerPlaying";
                    return YES;
                }
            }
        }
    }

    // 3. Check SpringBoard's nowPlayingApp / isMusicPlayerPlaying
    UIApplication *sb = [UIApplication sharedApplication];
    if ([sb respondsToSelector:@selector(isNowPlayingAppPlaying)] && [sb isNowPlayingAppPlaying]) {
        if ([sb respondsToSelector:@selector(nowPlayingApp)]) {
            SBApplication *npApp = [sb nowPlayingApp];
            if (npApp == app || (npApp && [[npApp bundleIdentifier] isEqualToString:bundleID])) {
                if (outReason) *outReason = @"SpringBoardNowPlayingApp";
                return YES;
            }
        }
    }
    if ([sb respondsToSelector:@selector(isMusicPlayerPlaying)] && [sb isMusicPlayerPlaying]) {
        if ([bundleID isEqualToString:@"com.apple.mobileipod"] || [bundleID isEqualToString:@"com.apple.Music"]) {
            if (outReason) *outReason = @"MusicPlayerPlaying";
            return YES;
        }
    }

    // 4. Check audio recording (Voice Memos, calls, VoIP)
    if ([app respondsToSelector:@selector(isRecordingAudio)] && [app isRecordingAudio]) {
        if (outReason) *outReason = @"RecordingAudio";
        return YES;
    }
    if ([app respondsToSelector:@selector(isNowRecordingApplication)] && [app isNowRecordingApplication]) {
        if (outReason) *outReason = @"NowRecordingApplication";
        return YES;
    }
    Class ctrlCls = NSClassFromString(@"SBApplicationController");
    if (ctrlCls && [ctrlCls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        SBApplicationController *ctrl = [ctrlCls sharedInstanceIfExists];
        if (ctrl && [ctrl respondsToSelector:@selector(applicationCurrentlyRecordingAudio)]) {
            SBApplication *recApp = [ctrl applicationCurrentlyRecordingAudio];
            if (recApp == app) {
                if (outReason) *outReason = @"ControllerRecordingAudio";
                return YES;
            }
        }
    }

    // 5. Check active phone / FaceTime call
    if ([app respondsToSelector:@selector(isMobilePhone)] && [app isMobilePhone]) {
        Class telCls = NSClassFromString(@"SBTelephonyManager");
        if (telCls && [telCls respondsToSelector:@selector(sharedTelephonyManagerCreatingIfNecessary:)]) {
            SBTelephonyManager *tel = [telCls sharedTelephonyManagerCreatingIfNecessary:NO];
            if (tel && [tel respondsToSelector:@selector(inCall)] && [tel inCall]) {
                if (outReason) *outReason = @"ActivePhoneCall";
                return YES;
            }
        }
    }

    // 6. Check system termination assertions
    if ([app respondsToSelector:@selector(isAnyTerminationAssertionHeld)] && [app isAnyTerminationAssertionHeld]) {
        if (outReason) *outReason = @"TerminationAssertionHeld";
        return YES;
    }

    return NO;
}

- (BOOL)shouldSkipApplication:(SBApplication *)app reason:(NSString **)outReason
{
    if (!app) return YES;
    NSString *bundleID = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : nil;
    NSString *displayID = [self identifierForApplication:app];
    if (!bundleID.length || !displayID.length) return YES;

    if ([BCSystemExcludedBundleIDs() containsObject:bundleID]) {
        if (outReason) *outReason = @"SystemExcluded";
        return YES;
    }
    if ([app respondsToSelector:@selector(isSystemProvisioningApplication)] && [app isSystemProvisioningApplication]) {
        if (outReason) *outReason = @"SystemProvisioning";
        return YES;
    }

    BCSettings *settings = [BCSettings shared];
    if ([settings isAppProtected:bundleID] || [settings isAppProtected:displayID]) {
        if (outReason) *outReason = @"UserProtected";
        return YES;
    }
    if (settings.keepPlaying && [self isApplicationActivelyInUse:app reason:outReason]) {
        return YES;
    }
    return NO;
}

#pragma mark - Exact iOS 6 App Termination & Switcher Removal

- (BOOL)sharesWebExecutableWithAnotherRunningApp:(SBApplication *)app
{
    if (![app respondsToSelector:@selector(isWebApplication)] || ![app isWebApplication]) {
        return NO;
    }
    Class ctrlCls = NSClassFromString(@"SBApplicationController");
    if (!ctrlCls || ![ctrlCls respondsToSelector:@selector(sharedInstance)]) return NO;
    SBApplicationController *ctrl = [ctrlCls sharedInstance];
    if (![ctrl respondsToSelector:@selector(allApplications)]) return NO;

    for (SBApplication *other in [ctrl allApplications]) {
        if (other == app) continue;
        if ([other respondsToSelector:@selector(isRunning)] && [other isRunning] &&
            [app respondsToSelector:@selector(isSameExecutableAsApplication:)] &&
            [app isSameExecutableAsApplication:other]) {
            return YES;
        }
    }
    return NO;
}

- (void)removeApplicationFromSwitcherUI:(SBApplication *)app
{
    NSString *displayID = [self identifierForApplication:app];
    if (!displayID.length) return;

    // 1. If SBAppSwitcherController exists, remove from _bottomBar and call _removeApplicationFromRecents:
    Class switcherCls = NSClassFromString(@"SBAppSwitcherController");
    if (switcherCls && [switcherCls respondsToSelector:@selector(sharedInstanceIfAvailable)]) {
        SBAppSwitcherController *switcher = [switcherCls sharedInstanceIfAvailable];
        if (switcher) {
            @try {
                SBAppSwitcherBarView *bottomBar = [switcher valueForKey:@"_bottomBar"];
                if (bottomBar && [bottomBar respondsToSelector:@selector(removeIconWithDisplayIdentifier:)]) {
                    [bottomBar removeIconWithDisplayIdentifier:displayID];
                }
            } @catch (NSException *e) {
                (void)e;
            }
            if ([switcher respondsToSelector:@selector(_removeApplicationFromRecents:)]) {
                [switcher _removeApplicationFromRecents:app];
                return;
            }
        }
    }

    // 2. Also remove directly from SBAppSwitcherModel & SBUIController in case switcher controller wasn't created yet
    Class modelCls = NSClassFromString(@"SBAppSwitcherModel");
    if (modelCls && [modelCls respondsToSelector:@selector(sharedInstance)]) {
        SBAppSwitcherModel *model = [modelCls sharedInstance];
        if (model && [model respondsToSelector:@selector(remove:)]) {
            [model remove:displayID];
        }
    }
    Class uiCls = NSClassFromString(@"SBUIController");
    if (uiCls && [uiCls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        SBUIController *ui = [uiCls sharedInstanceIfExists];
        if (ui && [ui respondsToSelector:@selector(removeAppFromSwitchAppList:)]) {
            [ui removeAppFromSwitchAppList:app];
        }
    }
}

- (BOOL)closeBackgroundApplication:(SBApplication *)app reason:(NSString *)reason
{
    if (!app) return NO;
    NSString *displayID = [self identifierForApplication:app];
    NSString *bundleID  = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : displayID;
    if (!displayID.length || !bundleID.length) return NO;

    BOOL wasRunning = [app respondsToSelector:@selector(isRunning)] && [app isRunning];
    BOOL removeFromSwitcher = [BCSettings shared].removeFromSwitcher;

    if (removeFromSwitcher) {
        [self removeApplicationFromSwitcherUI:app];
    }
    [_recentActiveOrder removeObject:displayID];
    [_nowPlayingBundleIDs removeObject:bundleID];

    if (wasRunning && ![self sharesWebExecutableWithAnotherRunningApp:app]) {
        // Mirror -[SBAppSwitcherController iconCloseBoxTapped:] and _SBWorkspaceTerminateApplication
        if ([app respondsToSelector:@selector(setDeactivationSetting:flag:)]) {
            [app setDeactivationSetting:2 flag:NO];   // animate = NO
            [app setDeactivationSetting:19 flag:YES]; // deactivateFromSwitcherSetting = YES
        }

        NSString *killDesc = [NSString stringWithFormat:@"Backcap (%@)", reason ?: @"Auto"];
        BCBKSForceQuitFn bksKill = BCGetBKSForceQuitFunction();
        Class eventCls = NSClassFromString(@"SBWorkspaceEvent");
        Class queueCls = NSClassFromString(@"SBWorkspaceEventQueue");

        if (bksKill && eventCls && queueCls &&
            [eventCls respondsToSelector:@selector(eventWithLabel:handler:)] &&
            [queueCls respondsToSelector:@selector(sharedInstance)]) {
            NSString *bundleCopy = [bundleID copy];
            SBWorkspaceEvent *event = [eventCls eventWithLabel:@"TerminateApp" handler:^{
                // reason = 1 (UserForceQuit) prevents auto-relaunch of apps with shouldAutoRelaunchAfterExit
                bksKill(bundleCopy, 1, 0, killDesc);
            }];
            SBWorkspaceEventQueue *queue = [queueCls sharedInstance];
            if (event && [queue respondsToSelector:@selector(executeOrAppendEvent:)]) {
                [queue executeOrAppendEvent:event];
            } else {
                bksKill(bundleCopy, 1, 0, killDesc);
            }
        } else if (bksKill) {
            bksKill(bundleID, 1, 0, killDesc);
        } else if ([app respondsToSelector:@selector(kill)]) {
            [app kill];
        }
    } else {
        if ([app respondsToSelector:@selector(setHasBeenFrontmost:)]) {
            [app setHasBeenFrontmost:NO];
        }
    }

    BCLog(@"Closed app %@ (running=%d, removedFromSwitcher=%d, reason=%@)",
          displayID, (int)wasRunning, (int)removeFromSwitcher, reason ?: @"Auto");
    return (wasRunning || removeFromSwitcher);
}

#pragma mark - Candidate List & Enforcement

- (NSArray *)orderedBackgroundCandidatesIncludingFrontmost:(BOOL)includeFrontmost
{
    SBApplication *frontApp = [self currentFrontmostApplication];
    NSString *frontID = [self identifierForApplication:frontApp];

    Class modelCls = NSClassFromString(@"SBAppSwitcherModel");
    NSArray *switcherSnap = nil;
    if (modelCls && [modelCls respondsToSelector:@selector(sharedInstance)]) {
        SBAppSwitcherModel *model = [modelCls sharedInstance];
        if ([model respondsToSelector:@selector(snapshot)]) {
            switcherSnap = [model snapshot];
        }
    }
    NSSet *switcherSet = [switcherSnap isKindOfClass:[NSArray class]]
        ? [NSSet setWithArray:switcherSnap]
        : [NSSet set];

    // Build ordered unique list of displayIdentifiers (most recently active first)
    NSMutableArray *orderedIDs = [NSMutableArray array];
    NSMutableSet *seenIDs = [NSMutableSet set];

    for (NSString *ident in _recentActiveOrder) {
        if ([ident isKindOfClass:[NSString class]] && ident.length && ![seenIDs containsObject:ident]) {
            [seenIDs addObject:ident];
            [orderedIDs addObject:ident];
        }
    }
    if ([switcherSnap isKindOfClass:[NSArray class]]) {
        for (id item in switcherSnap) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] && ![seenIDs containsObject:item]) {
                [seenIDs addObject:item];
                [orderedIDs addObject:item];
            }
        }
    }

    Class ctrlCls = NSClassFromString(@"SBApplicationController");
    if (ctrlCls && [ctrlCls respondsToSelector:@selector(sharedInstance)]) {
        SBApplicationController *ctrl = [ctrlCls sharedInstance];
        if ([ctrl respondsToSelector:@selector(allApplications)]) {
            for (SBApplication *app in [ctrl allApplications]) {
                if (![app respondsToSelector:@selector(isRunning)] || ![app isRunning]) continue;
                BOOL wasUserApp = ([app respondsToSelector:@selector(hasBeenFrontmost)] && [app hasBeenFrontmost]);
                NSString *ident = [self identifierForApplication:app];
                if (ident.length && (wasUserApp || [switcherSet containsObject:ident]) && ![seenIDs containsObject:ident]) {
                    [seenIDs addObject:ident];
                    [orderedIDs addObject:ident];
                }
            }
        }
    }

    BOOL removeFromSwitcher = [BCSettings shared].removeFromSwitcher;
    NSMutableArray *candidates = [NSMutableArray array];

    for (NSString *ident in orderedIDs) {
        SBApplication *app = [self applicationForIdentifier:ident];
        if (!app) continue;

        if (!includeFrontmost) {
            if ((frontID.length && [ident isEqualToString:frontID]) ||
                (_currentFrontmostID.length && [ident isEqualToString:_currentFrontmostID]) ||
                [self isApplicationForegroundOrTransitioning:app]) {
                continue;
            }
        }

        BOOL isRunning = [app respondsToSelector:@selector(isRunning)] && [app isRunning];
        BOOL inSwitcher = [switcherSet containsObject:ident];
        if (!isRunning && !(removeFromSwitcher && inSwitcher)) {
            continue;
        }

        NSString *skipReason = nil;
        if ([self shouldSkipApplication:app reason:&skipReason]) {
            if (BCDebugEnabled()) {
                BCLog(@"Skipping %@ (%@)", ident, skipReason ?: @"Protected");
            }
            continue;
        }

        [candidates addObject:app];
    }

    return candidates;
}

- (void)scheduleEnforceCapWithDelay:(NSTimeInterval)delay reason:(NSString *)reason
{
    if (_enforceScheduled) return;
    _enforceScheduled = YES;

    __weak BCSpringBoardManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BCSpringBoardManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_enforceScheduled = NO;
        [strongSelf enforceBackgroundCapWithReason:reason];
    });
}

- (void)enforceBackgroundCapWithReason:(NSString *)reason
{
    BCSettings *settings = [BCSettings shared];
    if (!settings.enabled) return;

    NSInteger maxApps = settings.maxApps;
    if (maxApps < 0) return; // Unlimited (-1)

    NSMutableArray *candidates = [[self orderedBackgroundCandidatesIncludingFrontmost:NO] mutableCopy];
    if ((NSInteger)candidates.count <= maxApps) return;

    NSMutableArray *closedIDs = [NSMutableArray array];
    while ((NSInteger)candidates.count > maxApps && candidates.count > 0) {
        SBApplication *victim = nil;
        if (maxApps == 0 || settings.closeMode == BCCloseModeOldest) {
            victim = [candidates lastObject];
            [candidates removeLastObject];
        } else {
            // BCCloseModeLastUsed: close the most recently left background app (index 0)
            victim = candidates[0];
            [candidates removeObjectAtIndex:0];
        }

        NSString *ident = [self identifierForApplication:victim];
        if ([self closeBackgroundApplication:victim reason:reason]) {
            if (ident.length) [closedIDs addObject:ident];
        }
    }

    if (closedIDs.count > 0) {
        [self writeLastActionReportWithReason:reason closedIDs:closedIDs];
    }
}

- (NSInteger)closeAllUnusedBackgroundAppsWithReason:(NSString *)reason includeFrontmost:(BOOL)includeFrontmost
{
    NSArray *candidates = [self orderedBackgroundCandidatesIncludingFrontmost:includeFrontmost];
    NSMutableArray *closedIDs = [NSMutableArray array];

    for (SBApplication *app in candidates) {
        NSString *ident = [self identifierForApplication:app];
        // When triggered from Settings ("Close Background Apps Now"), never kill Settings itself
        if ([ident isEqualToString:@"com.apple.Preferences"]) {
            continue;
        }
        // When locking with keepFrontmostOnLock enabled, preserve the app that was open right before locking
        if ([reason isEqualToString:@"DeviceLocked"] &&
            [BCSettings shared].keepFrontmostOnLock &&
            _lastFrontmostBeforeLockID.length &&
            [ident isEqualToString:_lastFrontmostBeforeLockID]) {
            continue;
        }
        if ([self closeBackgroundApplication:app reason:reason]) {
            if (ident.length) [closedIDs addObject:ident];
        }
    }

    [self writeLastActionReportWithReason:reason closedIDs:closedIDs];
    return (NSInteger)closedIDs.count;
}

- (void)writeLastActionReportWithReason:(NSString *)reason closedIDs:(NSArray *)closedIDs
{
    NSDictionary *report = @{
        @"reason": reason ?: @"Auto",
        @"closedCount": @(closedIDs.count),
        @"closedApps": closedIDs ?: @[],
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
    [report writeToFile:BCLastClosedPlistPath atomically:YES];
}

#pragma mark - Notification Handlers

- (void)handleActivationStateChange:(NSNotification *)note
{
    SBApplication *app = [note object];
    if (!app || ![app respondsToSelector:@selector(activationState)]) return;

    NSString *displayID = [self identifierForApplication:app];
    if (!displayID.length) return;
    if ([BCSystemExcludedBundleIDs() containsObject:displayID]) return;

    int state = [app activationState];
    if (BCDebugEnabled()) {
        BCLog(@"Activation state changed: %@ -> %d", displayID, state);
    }

    if (state == BCSBActivationStateActivated) {
        _currentFrontmostID = [displayID copy];
        if (![self isDeviceCurrentlyLocked]) {
            _lastFrontmostBeforeLockID = [displayID copy];
        }
        [_recentActiveOrder removeObject:displayID];
        [_recentActiveOrder insertObject:displayID atIndex:0];

        if ([BCSettings shared].enabled && [BCSettings shared].maxApps >= 1) {
            [self scheduleEnforceCapWithDelay:0.35 reason:@"AppActivated"];
        }
    } else if (state == BCSBActivationStateDeactivated) {
        SBApplication *front = [self currentFrontmostApplication];
        NSString *frontID = [self identifierForApplication:front];
        _currentFrontmostID = frontID.length ? [frontID copy] : nil;

        if (![_recentActiveOrder containsObject:displayID]) {
            if (_currentFrontmostID.length && _recentActiveOrder.count > 0 &&
                [_recentActiveOrder[0] isEqualToString:_currentFrontmostID]) {
                [_recentActiveOrder insertObject:displayID atIndex:1];
            } else {
                [_recentActiveOrder insertObject:displayID atIndex:0];
            }
        }

        if (![BCSettings shared].enabled) return;

        // If the device is currently locking, handleDeviceLocked: will handle cleanup according to killOnLock
        if ([self isDeviceCurrentlyLocked]) return;

        NSInteger maxApps = [BCSettings shared].maxApps;
        if (maxApps == 0) {
            // Close immediately on Home button / app exit
            __weak BCSpringBoardManager *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BCSpringBoardManager *strongSelf = weakSelf;
                if (!strongSelf || ![BCSettings shared].enabled || [BCSettings shared].maxApps != 0) return;
                if ([strongSelf isDeviceCurrentlyLocked]) return;
                if ([app activationState] != BCSBActivationStateDeactivated) return;

                NSString *skipReason = nil;
                if ([strongSelf shouldSkipApplication:app reason:&skipReason]) return;
                if ([strongSelf closeBackgroundApplication:app reason:@"CloseOnHome"]) {
                    [strongSelf writeLastActionReportWithReason:@"CloseOnHome" closedIDs:@[displayID]];
                }
            });
        } else if (maxApps >= 1) {
            [self scheduleEnforceCapWithDelay:0.25 reason:@"AppDeactivated"];
        }
    } else if (state == BCSBActivationStateNotRunning) {
        NSString *bundleID = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : displayID;
        if (bundleID.length) {
            [_nowPlayingBundleIDs removeObject:bundleID];
        }
    }
}

- (void)handleDeviceLocked:(NSNotification *)note
{
    (void)note;
    BCSettings *settings = [BCSettings shared];
    if (!settings.enabled || !settings.killOnLock) return;

    __weak BCSpringBoardManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BCSpringBoardManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (![BCSettings shared].enabled || ![BCSettings shared].killOnLock) return;
        if (![strongSelf isDeviceCurrentlyLocked]) return;

        BOOL includeFront = ![BCSettings shared].keepFrontmostOnLock;
        [strongSelf closeAllUnusedBackgroundAppsWithReason:@"DeviceLocked" includeFrontmost:includeFront];
    });
}

#pragma mark - Diagnostic Dump

- (NSDictionary *)diagnosticDump
{
    BCSettings *settings = [BCSettings shared];
    [settings reload];

    Class modelCls = NSClassFromString(@"SBAppSwitcherModel");
    NSArray *switcherSnap = (modelCls && [modelCls respondsToSelector:@selector(sharedInstance)])
        ? [[modelCls sharedInstance] snapshot]
        : @[];

    NSMutableArray *runningApps = [NSMutableArray array];
    Class ctrlCls = NSClassFromString(@"SBApplicationController");
    if (ctrlCls && [ctrlCls respondsToSelector:@selector(sharedInstance)]) {
        SBApplicationController *ctrl = [ctrlCls sharedInstance];
        for (SBApplication *app in [ctrl allApplications]) {
            if ([app respondsToSelector:@selector(isRunning)] && [app isRunning]) {
                NSString *ident = [self identifierForApplication:app] ?: @"?";
                NSString *skipReason = nil;
                BOOL skipped = [self shouldSkipApplication:app reason:&skipReason];
                [runningApps addObject:@{
                    @"id": ident,
                    @"state": @([app activationState]),
                    @"skipped": @(skipped),
                    @"skipReason": skipReason ?: @"",
                }];
            }
        }
    }

    return @{
        @"version": BCVersion,
        @"enabled": @(settings.enabled),
        @"maxApps": @(settings.maxApps),
        @"closeMode": @(settings.closeMode),
        @"removeFromSwitcher": @(settings.removeFromSwitcher),
        @"killOnLock": @(settings.killOnLock),
        @"keepFrontmostOnLock": @(settings.keepFrontmostOnLock),
        @"keepPlaying": @(settings.keepPlaying),
        @"protectedApps": [[settings.protectedApps allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"recentActiveOrder": [_recentActiveOrder copy],
        @"switcherSnapshot": switcherSnap ?: @[],
        @"nowPlayingBundleIDs": [[_nowPlayingBundleIDs allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"currentFrontmostID": _currentFrontmostID ?: @"",
        @"lastFrontmostBeforeLockID": _lastFrontmostBeforeLockID ?: @"",
        @"isLocked": @([self isDeviceCurrentlyLocked]),
        @"runningApps": runningApps,
    };
}

@end

#pragma mark - Objective-C Method Hooks

static void (*orig_SBApplication_setNowPlayingWithAudio)(id self, SEL _cmd, BOOL playing) = NULL;
static void (*orig_SBApplication_didExitWithInfo_type)(id self, SEL _cmd, id info, int type) = NULL;
static void (*orig_SpringBoard_applicationDidFinishLaunching)(id self, SEL _cmd, id application) = NULL;

static void hook_SBApplication_setNowPlayingWithAudio(id self, SEL _cmd, BOOL playing)
{
    if (orig_SBApplication_setNowPlayingWithAudio) {
        orig_SBApplication_setNowPlayingWithAudio(self, _cmd, playing);
    }
    [[BCSpringBoardManager shared] noteApplication:self nowPlayingWithAudio:playing];
}

static void hook_SBApplication_didExitWithInfo_type(id self, SEL _cmd, id info, int type)
{
    [[BCSpringBoardManager shared] noteApplicationDidExit:self];
    if (orig_SBApplication_didExitWithInfo_type) {
        orig_SBApplication_didExitWithInfo_type(self, _cmd, info, type);
    }
}

static void hook_SpringBoard_applicationDidFinishLaunching(id self, SEL _cmd, id application)
{
    if (orig_SpringBoard_applicationDidFinishLaunching) {
        orig_SpringBoard_applicationDidFinishLaunching(self, _cmd, application);
    }
    [[BCSpringBoardManager shared] start];
}

void BCInitSpringBoardHooks(void)
{
    Class sbAppCls = objc_getClass("SBApplication");
    if (sbAppCls) {
        Method mNowPlaying = class_getInstanceMethod(sbAppCls, @selector(setNowPlayingWithAudio:));
        if (mNowPlaying) {
            orig_SBApplication_setNowPlayingWithAudio = (void (*)(id, SEL, BOOL))method_getImplementation(mNowPlaying);
            method_setImplementation(mNowPlaying, (IMP)hook_SBApplication_setNowPlayingWithAudio);
        }

        Method mDidExit = class_getInstanceMethod(sbAppCls, @selector(didExitWithInfo:type:));
        if (mDidExit) {
            orig_SBApplication_didExitWithInfo_type = (void (*)(id, SEL, id, int))method_getImplementation(mDidExit);
            method_setImplementation(mDidExit, (IMP)hook_SBApplication_didExitWithInfo_type);
        }
    }

    Class sbCls = objc_getClass("SpringBoard");
    if (sbCls) {
        Method mLaunch = class_getInstanceMethod(sbCls, @selector(applicationDidFinishLaunching:));
        if (mLaunch) {
            orig_SpringBoard_applicationDidFinishLaunching = (void (*)(id, SEL, id))method_getImplementation(mLaunch);
            method_setImplementation(mLaunch, (IMP)hook_SpringBoard_applicationDidFinishLaunching);
        }
    }

    // Also handle the case where SpringBoard is already running when the dylib loads
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication]) {
            [[BCSpringBoardManager shared] start];
        }
    });
}
