// Shared constants, localization and preferences of the Backcap tweak (iOS 6.0+).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define BCVersion @"0.1.0"
#define BCLog(fmt, ...) NSLog((@"[Backcap] " fmt), ##__VA_ARGS__)
#define L(key) BCText(key)

extern NSString * const BCPrefsDomain;
extern NSString * const BCPrefsPlistPath;
extern NSString * const BCLastClosedPlistPath;
extern NSString * const BCDebugDumpPlistPath;

extern const char * const BCPrefsChangedNotification;
extern const char * const BCCloseNowNotification;
extern const char * const BCDebugDumpNotification;

// Close mode when maxApps (1..6) is exceeded
typedef NS_ENUM(NSInteger, BCCloseMode) {
    BCCloseModeOldest   = 0, // Close the oldest (least recently used) app in the switcher
    BCCloseModeLastUsed = 1, // Close the previous (most recently left) background app
};

NSString *BCSupportPath(NSString *name);
NSString *BCText(NSString *key);
BOOL BCDebugEnabled(void);

@interface BCSettings : NSObject

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSInteger maxApps;          // 0 = close on Home, 1..6 = cap, -1 = unlimited
@property (nonatomic, readonly) BCCloseMode closeMode;
@property (nonatomic, readonly) BOOL removeFromSwitcher;
@property (nonatomic, readonly) BOOL killOnLock;
@property (nonatomic, readonly) BOOL keepFrontmostOnLock;
@property (nonatomic, readonly) BOOL keepPlaying;
@property (nonatomic, readonly) NSSet *protectedApps;

+ (instancetype)shared;
- (void)reload;
- (BOOL)isAppProtected:(NSString *)bundleID;
- (void)setAppProtected:(BOOL)isProtected forBundleID:(NSString *)bundleID;

@end
