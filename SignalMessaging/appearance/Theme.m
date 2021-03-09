//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "Theme.h"
#import "UIUtil.h"
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalServiceKit/NSNotificationCenter+OWS.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const ThemeDidChangeNotification = @"ThemeDidChangeNotification";

NSString *const ThemeKeyLegacyThemeEnabled = @"ThemeKeyThemeEnabled";
NSString *const ThemeKeyCurrentMode = @"ThemeKeyCurrentMode";

@interface Theme ()

@property (nonatomic) NSNumber *isDarkThemeEnabledNumber;
@property (nonatomic) NSNumber *cachedCurrentThemeNumber;

#if TESTABLE_BUILD
@property (nonatomic, nullable) NSNumber *isDarkThemeEnabledForTests;
#endif

@end

@implementation Theme

#pragma mark - Dependencies

- (SDSDatabaseStorage *)databaseStorage
{
    return SDSDatabaseStorage.shared;
}

#pragma mark -

+ (SDSKeyValueStore *)keyValueStore
{
    return [[SDSKeyValueStore alloc] initWithCollection:@"ThemeCollection"];
}

#pragma mark -

+ (Theme *)shared
{
    static dispatch_once_t onceToken;
    static Theme *instance;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initDefault];
    });

    return instance;
}

- (instancetype)initDefault
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();

    AppReadinessRunNowOrWhenAppDidBecomeReadySync(^{
        // IOS-782: +[Theme shared] re-enterant initialization
        // AppReadiness will invoke the block synchronously if the app is already ready.
        // This doesn't work here, because we'll end up reenterantly calling +shared
        // if the app is in dark mode and the first call to +[Theme shared] happens
        // after the app is ready.
        //
        // It looks like that pattern is only hit in the share extension, but we're better off
        // asyncing always to ensure the dependency chain is broken. We're okay waiting, since
        // there's no guarantee that this block in synchronously executed anyway.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self notifyIfThemeModeIsNotDefault];
        });
    });

    return self;
}

- (void)notifyIfThemeModeIsNotDefault
{
    if (self.isDarkThemeEnabled || self.defaultTheme != self.getOrFetchCurrentTheme) {
        [self themeDidChange];
    }
}

#pragma mark -

+ (BOOL)isDarkThemeEnabled
{
    return [self.shared isDarkThemeEnabled];
}

- (BOOL)isDarkThemeEnabled
{
    //    OWSAssertIsOnMainThread();

#if TESTABLE_BUILD
    if (self.isDarkThemeEnabledForTests != nil) {
        return self.isDarkThemeEnabledForTests.boolValue;
    }
#endif

    if (!AppReadiness.isAppReady) {
        // Don't cache this value until it reflects the data store.
        return self.isSystemDarkThemeEnabled;
    }

    if (self.isDarkThemeEnabledNumber == nil) {
        BOOL isDarkThemeEnabled;

        if (!CurrentAppContext().isMainApp) {
            // Always respect the system theme in extensions
            isDarkThemeEnabled = self.isSystemDarkThemeEnabled;
        } else {
            switch ([self getOrFetchCurrentTheme]) {
                case ThemeMode_System:
                    isDarkThemeEnabled = self.isSystemDarkThemeEnabled;
                    break;
                case ThemeMode_Dark:
                    isDarkThemeEnabled = YES;
                    break;
                case ThemeMode_Light:
                    isDarkThemeEnabled = NO;
                    break;
            }
        }

        self.isDarkThemeEnabledNumber = @(isDarkThemeEnabled);
    }

    return self.isDarkThemeEnabledNumber.boolValue;
}

#if TESTABLE_BUILD
+ (void)setIsDarkThemeEnabledForTests:(BOOL)value
{
    self.shared.isDarkThemeEnabledForTests = @(value);
}
#endif

+ (ThemeMode)getOrFetchCurrentTheme
{
    return [self.shared getOrFetchCurrentTheme];
}

- (ThemeMode)getOrFetchCurrentTheme
{
    if (self.cachedCurrentThemeNumber) {
        return self.cachedCurrentThemeNumber.unsignedIntegerValue;
    }

    if (!AppReadiness.isAppReady) {
        return self.defaultTheme;
    }

    __block ThemeMode currentMode;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        BOOL hasDefinedMode = [Theme.keyValueStore hasValueForKey:ThemeKeyCurrentMode transaction:transaction];
        if (!hasDefinedMode) {
            // If the theme has not yet been defined, check if the user ever manually changed
            // themes in a legacy app version. If so, preserve their selection. Otherwise,
            // default to matching the system theme.
            if (![Theme.keyValueStore hasValueForKey:ThemeKeyLegacyThemeEnabled transaction:transaction]) {
                currentMode = ThemeMode_System;
            } else {
                BOOL isLegacyModeDark = [Theme.keyValueStore getBool:ThemeKeyLegacyThemeEnabled
                                                        defaultValue:NO
                                                         transaction:transaction];
                currentMode = isLegacyModeDark ? ThemeMode_Dark : ThemeMode_Light;
            }
        } else {
            currentMode = [Theme.keyValueStore getUInt:ThemeKeyCurrentMode
                                          defaultValue:ThemeMode_System
                                           transaction:transaction];
        }
    }];

    self.cachedCurrentThemeNumber = @(currentMode);
    return currentMode;
}

+ (void)setCurrentTheme:(ThemeMode)mode
{
    [self.shared setCurrentTheme:mode];
}

- (void)setCurrentTheme:(ThemeMode)mode
{
    OWSAssertIsOnMainThread();

    DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        [Theme.keyValueStore setUInt:mode key:ThemeKeyCurrentMode transaction:transaction];
    });

    NSNumber *previousMode = self.isDarkThemeEnabledNumber;

    switch (mode) {
        case ThemeMode_Light:
            self.isDarkThemeEnabledNumber = @(NO);
            break;
        case ThemeMode_Dark:
            self.isDarkThemeEnabledNumber = @(YES);
            break;
        case ThemeMode_System:
            self.isDarkThemeEnabledNumber = @(self.isSystemDarkThemeEnabled);
            break;
    }

    self.cachedCurrentThemeNumber = @(mode);

    if (![previousMode isEqual:self.isDarkThemeEnabledNumber]) {
        [self themeDidChange];
    }
}

- (BOOL)isSystemDarkThemeEnabled
{
    if (@available(iOS 13, *)) {
        return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    } else {
        return NO;
    }
}

- (ThemeMode)defaultTheme
{
    if (@available(iOS 13, *)) {
        return ThemeMode_System;
    }

    return ThemeMode_Light;
}

#pragma mark -

+ (void)systemThemeChanged
{
    [self.shared systemThemeChanged];
}

- (void)systemThemeChanged
{
    // Do nothing, since we haven't setup the theme yet.
    if (self.isDarkThemeEnabledNumber == nil) {
        return;
    }

    // Theme can only be changed externally when in system mode.
    if ([self getOrFetchCurrentTheme] != ThemeMode_System) {
        return;
    }

    // The system theme has changed since the user was last in the app.
    self.isDarkThemeEnabledNumber = @(self.isSystemDarkThemeEnabled);
    [self themeDidChange];
}

- (void)themeDidChange
{
    [UIUtil setupSignalAppearence];

    [UIView performWithoutAnimation:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ThemeDidChangeNotification object:nil userInfo:nil];
    }];
}

#pragma mark -

+ (UIColor *)backgroundColor
{
    return (Theme.isDarkThemeEnabled ? Theme.darkThemeBackgroundColor : UIColor.ows_whiteColor);
}

+ (UIColor *)secondaryBackgroundColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_gray80Color : UIColor.ows_gray02Color);
}

+ (UIColor *)washColor
{
    return (Theme.isDarkThemeEnabled ? self.darkThemeWashColor : UIColor.ows_gray05Color);
}

+ (UIColor *)darkThemeWashColor
{
    return UIColor.ows_gray75Color;
}

+ (UIColor *)primaryTextColor
{
    return (Theme.isDarkThemeEnabled ? [UIColor whiteColor] : [UIColor blackColor]);
}

+ (UIColor *)primaryIconColor
{
    return [UIColor whiteColor];
}

+ (UIColor *)secondaryTextAndIconColor
{
    return  [UIColor colorWithRed: 0.63 green: 0.61 blue: 0.66 alpha: 1.00];
    //return (Theme.isDarkThemeEnabled ? Theme.darkThemeSecondaryTextAndIconColor : UIColor.ows_gray60Color);
}

+ (UIColor *)darkThemeSecondaryTextAndIconColor
{
    return UIColor.ows_gray25Color;
}

+ (UIColor *)ternaryTextColor
{
    return UIColor.ows_gray45Color;
}

+ (UIColor *)boldColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_whiteColor : UIColor.blackColor);
}

+ (UIColor *)middleGrayColor
{
    return [UIColor colorWithWhite:0.5f alpha:1.f];
}

+ (UIColor *)placeholderColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_gray45Color : UIColor.ows_gray45Color);
}

+ (UIColor *)hairlineColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_gray75Color : UIColor.ows_gray15Color);
}

+ (UIColor *)outlineColor
{
    return Theme.isDarkThemeEnabled ? UIColor.ows_gray75Color : UIColor.ows_gray15Color;
}

+ (UIColor *)backdropColor
{
    return UIColor.ows_blackAlpha40Color;
}

#pragma mark - Global App Colors

+ (UIColor *)navbarBackgroundColor
{
    return (Theme.isDarkThemeEnabled ? self.darkThemeNavbarBackgroundColor : [UIColor whiteColor]);
}

+ (UIColor *)navbarOrangeBackgroundColor
{
    return [UIColor colorWithRed: 0.94 green: 0.51 blue: 0.24 alpha: 1.00];
}

+ (UIColor *)darkThemeNavbarBackgroundColor
{
    return UIColor.ows_blackColor;
}

+ (UIColor *)darkThemeNavbarIconColor
{
    return UIColor.ows_gray15Color;
}

+ (UIColor *)navbarTitleColor
{
    return Theme.primaryTextColor;
}

+ (UIColor *)toolbarBackgroundColor
{
    return self.navbarBackgroundColor;
}

+ (UIColor *)conversationInputBackgroundColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_gray75Color : UIColor.ows_gray05Color);
}

+ (UIColor *)attachmentKeyboardItemBackgroundColor
{
    return self.conversationInputBackgroundColor;
}

+ (UIColor *)attachmentKeyboardItemImageColor
{
    return (Theme.isDarkThemeEnabled ? [UIColor colorWithRGBHex:0xd8d8d9] : [UIColor colorWithRGBHex:0x636467]);
}

+ (UIColor *)cellSelectedColor
{
    return (Theme.isDarkThemeEnabled ? [UIColor colorWithWhite:0.2 alpha:1] : [UIColor colorWithWhite:0.92 alpha:1]);
}

+ (UIColor *)cellSeparatorColor
{
    return Theme.hairlineColor;
}

+ (UIColor *)cursorColor
{
    return Theme.isDarkThemeEnabled ? UIColor.ows_whiteColor : UIColor.ows_accentBlueColor;
}

+ (UIColor *)accentBlueColor
{
    return Theme.isDarkThemeEnabled ? UIColor.ows_accentBlueDarkColor : UIColor.ows_accentBlueColor;
}

+ (UIColor *)tableCellBackgroundColor
{
    return Theme.isDarkThemeEnabled ? UIColor.ows_gray95Color : Theme.backgroundColor;
}

+ (UIColor *)tableViewBackgroundColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_blackColor : UIColor.ows_gray02Color);
}

+ (UIColor *)tableCell2BackgroundColor
{
    return Theme.isDarkThemeEnabled ? UIColor.ows_gray80Color : UIColor.ows_whiteColor;
}

+ (UIColor *)tableView2BackgroundColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_gray95Color : UIColor.ows_gray02Color);
}

+ (UIColor *)darkThemeBackgroundColor
{
    return UIColor.ows_blackColor;
}

+ (UIColor *)darkThemePrimaryColor
{
    return UIColor.ows_gray05Color;
}

+ (UIColor *)lightThemePrimaryColor
{
    return UIColor.ows_gray90Color;
}

+ (UIColor *)galleryHighlightColor
{
    return [UIColor colorWithRGBHex:0x1f8fe8];
}

+ (UIColor *)conversationButtonBackgroundColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_gray80Color : UIColor.ows_gray02Color);
}

+ (UIColor *)conversationButtonTextColor
{
    return  Theme.orangeTintColor;
    //return (Theme.isDarkThemeEnabled ? UIColor.ows_gray05Color : Theme.orangeTintColor);
}


+ (UIBlurEffect *)barBlurEffect
{
    return Theme.isDarkThemeEnabled ? self.darkThemeBarBlurEffect
                                    : [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
}

+ (UIBlurEffect *)darkThemeBarBlurEffect
{
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

+ (UIKeyboardAppearance)keyboardAppearance
{
    return Theme.isDarkThemeEnabled ? self.darkThemeKeyboardAppearance : UIKeyboardAppearanceDefault;
}

+ (UIColor *)keyboardBackgroundColor
{
    return Theme.isDarkThemeEnabled ? UIColor.ows_gray90Color : UIColor.ows_gray02Color;
}

+ (UIKeyboardAppearance)darkThemeKeyboardAppearance
{
    return UIKeyboardAppearanceDark;
}

#pragma mark - Search Bar

+ (UIBarStyle)barStyle
{
    return Theme.isDarkThemeEnabled ? UIBarStyleBlack : UIBarStyleDefault;
}

+ (UIColor *)searchFieldBackgroundColor
{
    return Theme.washColor;
}

#pragma mark -

+ (UIColor *)toastForegroundColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_whiteColor : UIColor.ows_whiteColor);
}

+ (UIColor *)toastBackgroundColor
{
    return (Theme.isDarkThemeEnabled ? UIColor.ows_gray75Color : UIColor.ows_gray60Color);
}

+ (UIColor *)scrollButtonBackgroundColor
{
    return Theme.isDarkThemeEnabled ? [UIColor colorWithWhite:0.25f alpha:1.f]
                                    : [UIColor colorWithWhite:0.95f alpha:1.f];
}

+ (UIColor *)orangeBackground
{
    return [UIColor colorWithRed: 0.94 green: 0.51 blue: 0.24 alpha: 1.00];
}

+ (UIColor *)white
{
    return [UIColor whiteColor];
}

+ (UIColor *)buttonTintColor
{
    return [UIColor colorWithRed: 0.19 green: 0.13 blue: 0.32 alpha: 1.00];
}

+ (UIColor *)orangeOnTintColor
{
    return [UIColor colorWithRed: 0.94 green: 0.51 blue: 0.24 alpha: 1.00];
}

+ (UIColor *)orangeTintColor
{
    return [UIColor colorWithRed: 0.94 green: 0.51 blue: 0.24 alpha: 1.00];
}

+ (UIColor *)whiteBlackColor
{
    return (Theme.isDarkThemeEnabled ?  [UIColor blackColor] : [UIColor whiteColor]);
}

@end

NS_ASSUME_NONNULL_END
