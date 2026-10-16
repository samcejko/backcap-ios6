#import "BCPreferences.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

@interface PSSpecifier : NSObject
- (NSString *)name;
- (void)setName:(NSString *)name;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (NSDictionary *)titleDictionary;
- (void)setTitleDictionary:(NSDictionary *)dict;
- (NSDictionary *)shortTitleDictionary;
- (void)setShortTitleDictionary:(NSDictionary *)dict;
@end

@interface UIImage (BCPrivateIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

static NSSet *BCHiddenSystemAppBundleIDs(void)
{
    static NSSet *hidden;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hidden = [NSSet setWithArray:@[
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
            @"com.apple.CompassCalibrationViewService",
            @"com.apple.AccountAuthenticationDialog",
            @"com.apple.Copilot",
            @"com.apple.datadetectors.DDActionsService",
            @"com.saurik.Cydia",
        ]];
    });
    return hidden;
}

static NSDictionary *BCAppEntryFromAppBundlePath(NSString *appPath, BOOL isSystemApp)
{
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    if (![info isKindOfClass:[NSDictionary class]]) return nil;

    NSString *bundleID = info[@"CFBundleIdentifier"];
    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) return nil;
    if ([BCHiddenSystemAppBundleIDs() containsObject:bundleID]) return nil;

    NSArray *tags = info[@"SBAppTags"];
    if ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) {
        return nil;
    }

    NSBundle *bundle = [NSBundle bundleWithPath:appPath];
    NSString *name = nil;
    if (bundle) {
        name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
            ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    }
    if (![name isKindOfClass:[NSString class]] || !name.length) {
        name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bundleID;
    }

    return @{
        @"bundleID": bundleID,
        @"name": name,
        @"path": appPath,
        @"system": @(isSystemApp),
    };
}

@implementation BCProtectedAppsController {
    NSArray *_userApps;
    NSArray *_systemApps;
    NSMutableDictionary *_iconCache;
}

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = L(@"ProtectedApps");
    _iconCache = [[NSMutableDictionary alloc] init];
    [[BCSettings shared] reload];
    [self reloadApplications];
}

- (void)reloadApplications
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *userList = [NSMutableArray array];
    NSMutableArray *sysList  = [NSMutableArray array];

    // 1. User applications in /var/mobile/Applications/<UUID>/<App>.app
    NSString *userRoot = @"/var/mobile/Applications";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:userRoot error:NULL];
    for (NSString *uuid in uuids) {
        NSString *container = [userRoot stringByAppendingPathComponent:uuid];
        NSArray *items = [fm contentsOfDirectoryAtPath:container error:NULL];
        for (NSString *item in items) {
            if ([item hasSuffix:@".app"]) {
                NSDictionary *entry = BCAppEntryFromAppBundlePath([container stringByAppendingPathComponent:item], NO);
                if (entry) [userList addObject:entry];
            }
        }
    }

    // 2. Installed applications in /Applications/<App>.app
    NSString *sysRoot = @"/Applications";
    NSArray *sysItems = [fm contentsOfDirectoryAtPath:sysRoot error:NULL];
    for (NSString *item in sysItems) {
        if ([item hasSuffix:@".app"]) {
            NSDictionary *entry = BCAppEntryFromAppBundlePath([sysRoot stringByAppendingPathComponent:item], YES);
            if (entry) [sysList addObject:entry];
        }
    }

    NSComparator sortByName = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    };
    _userApps   = [userList sortedArrayUsingComparator:sortByName];
    _systemApps = [sysList sortedArrayUsingComparator:sortByName];
}

- (UIImage *)iconForAppEntry:(NSDictionary *)entry
{
    NSString *bundleID = entry[@"bundleID"];
    if (!bundleID.length) return nil;
    UIImage *cached = _iconCache[bundleID];
    if (cached) return cached;

    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        CGFloat scale = [UIScreen mainScreen].scale;
        UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:scale];
        if (img) {
            _iconCache[bundleID] = img;
            return img;
        }
    }
    return nil;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) {
        return _userApps.count ? L(@"UserApps") : nil;
    }
    return _systemApps.count ? L(@"SystemApps") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) {
        return L(@"FooterProtection");
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) {
        return _userApps.count ? (NSInteger)_userApps.count : 1;
    }
    return (NSInteger)_systemApps.count;
}

- (NSDictionary *)appEntryForIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        if ((NSUInteger)indexPath.row < _userApps.count) {
            return _userApps[(NSUInteger)indexPath.row];
        }
        return nil;
    }
    if ((NSUInteger)indexPath.row < _systemApps.count) {
        return _systemApps[(NSUInteger)indexPath.row];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *entry = [self appEntryForIndexPath:indexPath];
    if (!entry) {
        static NSString * const kEmptyCell = @"BCEmptyCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kEmptyCell];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kEmptyCell];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.textColor = [UIColor grayColor];
            cell.textLabel.font = [UIFont systemFontOfSize:15.0f];
        }
        cell.textLabel.text = L(@"NoAppsFound");
        return cell;
    }

    static NSString * const kAppCell = @"BCAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kAppCell];
    UISwitch *toggle = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kAppCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0f];
        toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        [toggle addTarget:self action:@selector(appSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else {
        toggle = (UISwitch *)cell.accessoryView;
    }

    NSString *bundleID = entry[@"bundleID"];
    cell.textLabel.text = entry[@"name"];
    cell.detailTextLabel.text = bundleID;
    cell.imageView.image = [self iconForAppEntry:entry];

    toggle.tag = (indexPath.section == 0 ? 10000 : 20000) + indexPath.row;
    toggle.on = [[BCSettings shared] isAppProtected:bundleID];
    return cell;
}

- (void)appSwitchChanged:(UISwitch *)sender
{
    NSInteger section = (sender.tag >= 20000) ? 1 : 0;
    NSInteger row = sender.tag - (section == 1 ? 20000 : 10000);
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
    NSDictionary *entry = [self appEntryForIndexPath:indexPath];
    NSString *bundleID = entry[@"bundleID"];
    if (bundleID.length) {
        [[BCSettings shared] setAppProtected:sender.isOn forBundleID:bundleID];
    }
}

@end

#pragma mark - PreferenceLoader Localization & Button Actions

static NSDictionary *BCLocalizeDictionaryValues(NSDictionary *dict)
{
    if (![dict isKindOfClass:[NSDictionary class]] || !dict.count) return dict;
    NSMutableDictionary *outDict = [NSMutableDictionary dictionaryWithCapacity:dict.count];
    BOOL changed = NO;
    for (id key in dict) {
        id val = dict[key];
        if ([val isKindOfClass:[NSString class]]) {
            NSString *loc = BCText(val);
            outDict[key] = loc;
            if (![loc isEqualToString:val]) changed = YES;
        } else {
            outDict[key] = val;
        }
    }
    return changed ? outDict : dict;
}

static BOOL BCLocalizeSpecifiersIfNeeded(NSArray *specifiers)
{
    if (![specifiers isKindOfClass:[NSArray class]]) return NO;

    BOOL isBackcap = NO;
    for (PSSpecifier *spec in specifiers) {
        if (![spec respondsToSelector:@selector(propertyForKey:)]) continue;
        id defaults = [spec propertyForKey:@"defaults"];
        if ([defaults isKindOfClass:[NSString class]] && [defaults isEqualToString:BCPrefsDomain]) {
            isBackcap = YES;
            break;
        }
    }
    if (!isBackcap) return NO;

    for (PSSpecifier *spec in specifiers) {
        if ([spec respondsToSelector:@selector(name)] && [spec respondsToSelector:@selector(setName:)]) {
            NSString *name = [spec name];
            if ([name isKindOfClass:[NSString class]] && name.length) {
                [spec setName:BCText(name)];
            }
        }
        if ([spec respondsToSelector:@selector(propertyForKey:)] && [spec respondsToSelector:@selector(setProperty:forKey:)]) {
            id footer = [spec propertyForKey:@"footerText"];
            if ([footer isKindOfClass:[NSString class]] && [(NSString *)footer length]) {
                [spec setProperty:BCText(footer) forKey:@"footerText"];
            }
        }
        if ([spec respondsToSelector:@selector(titleDictionary)] && [spec respondsToSelector:@selector(setTitleDictionary:)]) {
            NSDictionary *titles = [spec titleDictionary];
            if (titles) {
                [spec setTitleDictionary:BCLocalizeDictionaryValues(titles)];
            }
        }
        if ([spec respondsToSelector:@selector(shortTitleDictionary)] && [spec respondsToSelector:@selector(setShortTitleDictionary:)]) {
            NSDictionary *shortTitles = [spec shortTitleDictionary];
            if (shortTitles) {
                [spec setShortTitleDictionary:BCLocalizeDictionaryValues(shortTitles)];
            }
        }
    }
    return YES;
}

static id (*orig_PLCustomListController_specifiers)(id self, SEL _cmd) = NULL;
static id (*orig_PLLocalizedListController_specifiers)(id self, SEL _cmd) = NULL;

static id hook_PLCustomListController_specifiers(UIViewController *self, SEL _cmd)
{
    id specs = orig_PLCustomListController_specifiers ? orig_PLCustomListController_specifiers(self, _cmd) : nil;
    if (BCLocalizeSpecifiersIfNeeded(specs)) {
        self.title = @"Backcap";
        self.navigationItem.title = @"Backcap";
    }
    return specs;
}

static id hook_PLLocalizedListController_specifiers(UIViewController *self, SEL _cmd)
{
    id specs = orig_PLLocalizedListController_specifiers ? orig_PLLocalizedListController_specifiers(self, _cmd) : nil;
    if (BCLocalizeSpecifiersIfNeeded(specs)) {
        self.title = @"Backcap";
        self.navigationItem.title = @"Backcap";
    }
    return specs;
}

static void imp_PSListController_bcOpenProtectedApps(UIViewController *self, SEL _cmd, id specifier)
{
    (void)_cmd;
    (void)specifier;
    BCProtectedAppsController *vc = [[BCProtectedAppsController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

static void imp_PSListController_bcCloseNow(UIViewController *self, SEL _cmd, id specifier)
{
    (void)self;
    (void)_cmd;
    (void)specifier;

    [[NSFileManager defaultManager] removeItemAtPath:BCLastClosedPlistPath error:NULL];
    notify_post(BCCloseNowNotification);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:BCLastClosedPlistPath];
        int count = [report[@"closedCount"] intValue];
        NSString *msg = nil;
        if (count <= 0) {
            msg = L(@"CloseNowNone");
        } else if (count == 1) {
            msg = L(@"CloseNowOne");
        } else {
            msg = [NSString stringWithFormat:L(@"CloseNowMany"), count];
        }
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"CloseNowTitle")
                                                        message:msg
                                                       delegate:nil
                                              cancelButtonTitle:L(@"OK")
                                              otherButtonTitles:nil];
        [alert show];
    });
}

void BCInitPreferencesHooks(void)
{
    dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_LAZY);
    dlopen("/usr/lib/libprefs.dylib", RTLD_LAZY);
    dlopen("/Library/MobileSubstrate/DynamicLibraries/PreferenceLoader.dylib", RTLD_LAZY);

    Class psListCls = objc_getClass("PSListController");
    if (psListCls) {
        class_addMethod(psListCls, @selector(bcOpenProtectedApps:), (IMP)imp_PSListController_bcOpenProtectedApps, "v@:@");
        class_addMethod(psListCls, @selector(bcCloseNow:), (IMP)imp_PSListController_bcCloseNow, "v@:@");
    }

    Class plCustomCls = objc_getClass("PLCustomListController");
    if (plCustomCls) {
        Method mSpec = class_getInstanceMethod(plCustomCls, @selector(specifiers));
        if (mSpec) {
            orig_PLCustomListController_specifiers = (id (*)(id, SEL))method_getImplementation(mSpec);
            method_setImplementation(mSpec, (IMP)hook_PLCustomListController_specifiers);
        }
    }

    Class plLocCls = objc_getClass("PLLocalizedListController");
    if (plLocCls) {
        Method mSpec = class_getInstanceMethod(plLocCls, @selector(specifiers));
        if (mSpec && (!plCustomCls || mSpec != class_getInstanceMethod(plCustomCls, @selector(specifiers)))) {
            orig_PLLocalizedListController_specifiers = (id (*)(id, SEL))method_getImplementation(mSpec);
            method_setImplementation(mSpec, (IMP)hook_PLLocalizedListController_specifiers);
        }
    }
}
