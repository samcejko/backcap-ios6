#import "BCCommon.h"
#import <notify.h>

NSString * const BCPrefsDomain        = @"com.samcejko.backcap";
NSString * const BCPrefsPlistPath     = @"/var/mobile/Library/Preferences/com.samcejko.backcap.plist";
NSString * const BCLastClosedPlistPath = @"/tmp/backcap-last-closed.plist";
NSString * const BCDebugDumpPlistPath = @"/tmp/backcap-dump.plist";

const char * const BCPrefsChangedNotification = "com.samcejko.backcap/prefsChanged";
const char * const BCCloseNowNotification     = "com.samcejko.backcap/closeNow";
const char * const BCDebugDumpNotification    = "com.samcejko.backcap/dump";

static NSString * const BCSupportDir = @"/Library/Application Support/Backcap";

NSString *BCSupportPath(NSString *name)
{
    return [BCSupportDir stringByAppendingPathComponent:name];
}

BOOL BCDebugEnabled(void)
{
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        enabled = [[NSFileManager defaultManager] fileExistsAtPath:BCSupportPath(@"debug")];
    });
    return enabled;
}

static NSDictionary *BCLoadStringsForFolder(NSString *folder)
{
    NSString *path = [[BCSupportDir stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"Backcap.strings"];
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!contents.length) return @{};
    id plist = [contents propertyListFromStringsFileFormat];
    return [plist isKindOfClass:[NSDictionary class]] ? plist : @{};
}

NSString *BCText(NSString *key)
{
    if (!key.length) return @"";
    static NSDictionary *primaryTexts;
    static NSDictionary *fallbackTexts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *preferred = [NSLocale preferredLanguages];
        NSString *language = preferred.count ? preferred[0] : @"en";
        BOOL isCzech = [language hasPrefix:@"cs"];
        primaryTexts = BCLoadStringsForFolder(isCzech ? @"cs.lproj" : @"en.lproj");
        fallbackTexts = isCzech ? BCLoadStringsForFolder(@"en.lproj") : primaryTexts;
    });
    id val = primaryTexts[key] ?: fallbackTexts[key];
    return ([val isKindOfClass:[NSString class]] && [(NSString *)val length]) ? val : key;
}

static BOOL BCBoolValue(id obj, BOOL defaultVal)
{
    if ([obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSString class]]) {
        return [obj boolValue];
    }
    return defaultVal;
}

static NSInteger BCIntValue(id obj, NSInteger defaultVal)
{
    if ([obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSString class]]) {
        return [obj integerValue];
    }
    return defaultVal;
}

@implementation BCSettings {
    BOOL _enabled;
    NSInteger _maxApps;
    BCCloseMode _closeMode;
    BOOL _removeFromSwitcher;
    BOOL _killOnLock;
    BOOL _keepFrontmostOnLock;
    BOOL _keepPlaying;
    NSSet *_protectedApps;
}

@synthesize enabled = _enabled;
@synthesize maxApps = _maxApps;
@synthesize closeMode = _closeMode;
@synthesize removeFromSwitcher = _removeFromSwitcher;
@synthesize killOnLock = _killOnLock;
@synthesize keepFrontmostOnLock = _keepFrontmostOnLock;
@synthesize keepPlaying = _keepPlaying;
@synthesize protectedApps = _protectedApps;

+ (instancetype)shared
{
    static BCSettings *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[BCSettings alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self reload];
    }
    return self;
}

- (void)reload
{
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:BCPrefsPlistPath];
    if (![dict isKindOfClass:[NSDictionary class]]) dict = @{};

    _enabled             = BCBoolValue(dict[@"enabled"], YES);
    _maxApps             = BCIntValue(dict[@"maxApps"], 3);
    if (_maxApps < -1) _maxApps = -1;
    if (_maxApps > 6)  _maxApps = 6;
    _closeMode           = (BCCloseMode)BCIntValue(dict[@"closeMode"], BCCloseModeOldest);
    _removeFromSwitcher  = BCBoolValue(dict[@"removeFromSwitcher"], YES);
    _killOnLock          = BCBoolValue(dict[@"killOnLock"], YES);
    _keepFrontmostOnLock = BCBoolValue(dict[@"keepFrontmostOnLock"], NO);
    _keepPlaying         = BCBoolValue(dict[@"keepPlaying"], YES);

    NSMutableSet *prot = [NSMutableSet set];
    id rawProt = dict[@"protectedApps"];
    if ([rawProt isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)rawProt) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length]) {
                [prot addObject:item];
            }
        }
    }
    _protectedApps = [prot copy];
}

- (BOOL)isAppProtected:(NSString *)bundleID
{
    if (!bundleID.length) return NO;
    return [_protectedApps containsObject:bundleID];
}

- (void)setAppProtected:(BOOL)isProtected forBundleID:(NSString *)bundleID
{
    if (!bundleID.length) return;
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:BCPrefsPlistPath];
    if (![dict isKindOfClass:[NSMutableDictionary class]]) {
        dict = [NSMutableDictionary dictionary];
    }
    NSMutableSet *prot = [NSMutableSet setWithSet:_protectedApps ?: [NSSet set]];
    if (isProtected) {
        [prot addObject:bundleID];
    } else {
        [prot removeObject:bundleID];
    }
    _protectedApps = [prot copy];
    dict[@"protectedApps"] = [[prot allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [dict writeToFile:BCPrefsPlistPath atomically:YES];
    notify_post(BCPrefsChangedNotification);
}

@end
