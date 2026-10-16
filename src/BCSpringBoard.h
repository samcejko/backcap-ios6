// SpringBoard runtime hooks and background app manager for Backcap (iOS 6.0+).
#import "BCCommon.h"

@interface BCSpringBoardManager : NSObject

+ (instancetype)shared;
- (void)start;

- (void)noteApplication:(id)app nowPlayingWithAudio:(BOOL)playing;
- (void)noteApplicationDidExit:(id)app;
- (void)handleActivationStateChange:(NSNotification *)note;
- (void)handleDeviceLocked:(NSNotification *)note;

- (NSInteger)closeAllUnusedBackgroundAppsWithReason:(NSString *)reason includeFrontmost:(BOOL)includeFrontmost;
- (NSDictionary *)diagnosticDump;

@end

void BCInitSpringBoardHooks(void);
