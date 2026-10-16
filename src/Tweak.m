// Backcap — Cydia Substrate entrypoint for SpringBoard and Preferences (iOS 6.0+).
#import "BCCommon.h"
#import "BCSpringBoard.h"
#import "BCPreferences.h"

__attribute__((constructor))
static void BackcapInit(void)
{
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            BCInitSpringBoardHooks();
        } else if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
            BCInitPreferencesHooks();
        }
    }
}
