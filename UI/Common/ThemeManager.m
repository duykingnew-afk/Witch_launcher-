#import "ThemeManager.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

NSString * const ThemeDidChangeNotification = @"ThemeDidChangeNotification";

@interface ThemeManager ()
@property (nonatomic) UITraitCollection *currentTraitCollection;
@property (nonatomic) NSMutableDictionary *colorOverrides;
@property (nonatomic) NSUInteger backgroundBlurGeneration;
@end


// A phone photo is 12+ megapixels: ~50 MB decoded, and the blurred copy doubles it. The launcher only ever
// shows the picture at screen size, and the game needs that memory, so keep at most this many pixels on the
// longest side.
static const CGFloat kBackgroundMaxPixel = 1920;

static UIImage *DownsampledImage(UIImage *image, CGFloat maxPixel) {
    if (!image) return nil;
    CGSize px = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
    CGFloat longest = MAX(px.width, px.height);
    if (longest <= maxPixel) return image;
    CGFloat ratio = maxPixel / longest;
    CGSize target = CGSizeMake(floor(px.width * ratio), floor(px.height * ratio));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

// Decode a file straight to a small bitmap, never holding the full-size image in memory.
static UIImage *DownsampledImageAtPath(NSString *path, CGFloat maxPixel) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixel),
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

@implementation ThemeManager

+ (ThemeManager *)shared {
    static ThemeManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _interfaceStyle = UIUserInterfaceStyleUnspecified;
        _colorOverrides = [NSMutableDictionary dictionary];
        _backgroundBlurIntensity = 0;
        _uiOpacity = 1.0;
        // Manual Dark/Light must stick on windows created later (sheets,
        // pickers, dialogs) — they default to Unspecified (follow system).
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowBecameKey:) name:UIWindowDidBecomeKeyNotification object:nil];
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            @"amethyst_ui_opacity": @1.0,
            @"amethyst_ui_border_enabled": @NO,
            @"amethyst_ui_border_width": @1.0,
            @"amethyst_ui_border_radius": @10.0,
            @"amethyst_shell_gap": @0,
            @"amethyst_shell_inner_gap": @0,
            @"amethyst_settings_blur": @55,
            @"amethyst_topbar_blur": @55,
            @"amethyst_sidebar_blur": @55,
            @"amethyst_rightpanel_blur": @55,
            @"amethyst_bar_border_width": @1.0
        }];
        [self loadSavedPreferences];
    }
    return self;
}

- (void)loadSavedPreferences {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger style = [defaults integerForKey:@"amethyst_interface_style"];
    if (style > 0) {
        _interfaceStyle = style;
    }

    NSArray *colorKeys = @[@"amethyst_accent_color", @"amethyst_bg_color", @"amethyst_card_bg_color",
                           @"amethyst_sidebar_bg_color", @"amethyst_topbar_bg_color", @"amethyst_rightpanel_bg_color",
                           @"amethyst_text_color", @"amethyst_secondary_text_color", @"amethyst_ui_border_color"];
    for (NSString *key in colorKeys) {
        [self loadModeColorsForKey:key legacyHex:[defaults stringForKey:key]];
    }

    _backgroundBlurIntensity = [defaults floatForKey:@"amethyst_bg_blur"];
    _uiOpacity = [defaults floatForKey:@"amethyst_ui_opacity"];
    _uiBorderEnabled = [defaults boolForKey:@"amethyst_ui_border_enabled"];
    _uiBorderWidth = [defaults floatForKey:@"amethyst_ui_border_width"];
    _uiBorderCornerRadius = [defaults floatForKey:@"amethyst_ui_border_radius"];

    NSString *imgPath = [defaults stringForKey:@"amethyst_bg_image"];
    if (imgPath) {
        _backgroundImage = DownsampledImageAtPath(imgPath, kBackgroundMaxPixel) ?: [UIImage imageWithContentsOfFile:imgPath];
        [self processBackgroundBlur];
    }

    NSString *videoPath = [defaults stringForKey:@"amethyst_bg_video"];
    if (videoPath) {
        // The app container's path changes when the app is reinstalled or updated, so look in Documents by name.
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:videoPath]) {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            videoPath = [docs stringByAppendingPathComponent:videoPath.lastPathComponent];
        }
        if ([fm fileExistsAtPath:videoPath]) {
            _backgroundVideoURL = [NSURL fileURLWithPath:videoPath];
        } else {
            [defaults removeObjectForKey:@"amethyst_bg_video"];
        }
    }
}

- (void)loadModeColorsForKey:(NSString *)key legacyHex:(NSString *)legacyHex {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *darkKey = [self modePrefKeyFor:key dark:YES];
    NSString *lightKey = [self modePrefKeyFor:key dark:NO];
    NSString *darkHex = [defaults stringForKey:darkKey];
    NSString *lightHex = [defaults stringForKey:lightKey];

    if (legacyHex && !darkHex && !lightHex) {
        [defaults setObject:legacyHex forKey:darkKey];
        [defaults setObject:legacyHex forKey:lightKey];
        [defaults removeObjectForKey:key];
        _colorOverrides[darkKey] = [self colorFromHex:legacyHex];
        _colorOverrides[lightKey] = [self colorFromHex:legacyHex];
        return;
    }
    if (darkHex) _colorOverrides[darkKey] = [self colorFromHex:darkHex];
    if (lightHex) _colorOverrides[lightKey] = [self colorFromHex:lightHex];
}

- (NSString *)modePrefKeyFor:(NSString *)key dark:(BOOL)dark {
    return [key stringByAppendingFormat:@".%@", dark ? @"dark" : @"light"];
}

- (UIColor *)colorOverrideForKey:(NSString *)key {
    return [self colorOverrideForKey:key darkMode:self.isDarkMode];
}

- (UIColor *)colorOverrideForKey:(NSString *)key darkMode:(BOOL)dark {
    UIColor *color = _colorOverrides[[self modePrefKeyFor:key dark:dark]];
    if (!color) color = _colorOverrides[key];
    return color;
}

- (void)setBackgroundImage:(UIImage *)backgroundImage {
    backgroundImage = DownsampledImage(backgroundImage, kBackgroundMaxPixel);
    _backgroundImage = backgroundImage;
    _blurredBackgroundImage = nil;
    _backgroundVideoURL = nil;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"amethyst_bg_video"];
    if (backgroundImage && _backgroundBlurIntensity > 0) {
        [self processBackgroundBlur];
    }
    [self broadcastThemeChange];
}

- (void)setBackgroundVideoURL:(NSURL *)backgroundVideoURL {
    _backgroundVideoURL = backgroundVideoURL;
    _backgroundImage = nil;
    _blurredBackgroundImage = nil;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"amethyst_bg_image"];
    if (backgroundVideoURL) {
        [[NSUserDefaults standardUserDefaults] setObject:backgroundVideoURL.path forKey:@"amethyst_bg_video"];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"amethyst_bg_video"];
    }
    [self broadcastThemeChange];
}

- (BOOL)hasCustomBackground {
    return _backgroundImage != nil || _backgroundVideoURL != nil;
}

- (UIColor *)contentBackgroundColor {
    return self.hasCustomBackground ? [UIColor clearColor] : self.backgroundColor;
}

- (void)setBackgroundBlurIntensity:(CGFloat)backgroundBlurIntensity {
    _backgroundBlurIntensity = backgroundBlurIntensity;
    [[NSUserDefaults standardUserDefaults] setFloat:backgroundBlurIntensity forKey:@"amethyst_bg_blur"];
    if (_backgroundImage) {
        [self processBackgroundBlur];
    }
    [self broadcastThemeChange];
}

- (BOOL)backgroundVideoSound {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"amethyst_bg_video_sound"];
    return value ? [value boolValue] : YES;
}

- (void)setBackgroundVideoSound:(BOOL)backgroundVideoSound {
    [[NSUserDefaults standardUserDefaults] setBool:backgroundVideoSound forKey:@"amethyst_bg_video_sound"];
}

- (void)setUiBorderEnabled:(BOOL)uiBorderEnabled {
    _uiBorderEnabled = uiBorderEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:uiBorderEnabled forKey:@"amethyst_ui_border_enabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self broadcastThemeChange];
}

- (UIColor *)uiBorderColor {
    return [self colorOverrideForKey:@"amethyst_ui_border_color"] ?: [self.accentColor colorWithAlphaComponent:0.72];
}

- (void)setUiBorderWidth:(CGFloat)uiBorderWidth {
    _uiBorderWidth = MAX(0.5, MIN(uiBorderWidth, 4.0));
    [[NSUserDefaults standardUserDefaults] setFloat:_uiBorderWidth forKey:@"amethyst_ui_border_width"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self broadcastThemeChange];
}

- (void)setUiBorderCornerRadius:(CGFloat)uiBorderCornerRadius {
    _uiBorderCornerRadius = MAX(0, MIN(uiBorderCornerRadius, 28.0));
    [[NSUserDefaults standardUserDefaults] setFloat:_uiBorderCornerRadius forKey:@"amethyst_ui_border_radius"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self broadcastThemeChange];
}

- (void)setUiOpacity:(CGFloat)uiOpacity {
    _uiOpacity = uiOpacity;
    [[NSUserDefaults standardUserDefaults] setFloat:uiOpacity forKey:@"amethyst_ui_opacity"];
    [self broadcastThemeChange];
}

- (void)updateBackgroundBlur {
    if (_backgroundImage && _backgroundBlurIntensity > 0) {
        [self processBackgroundBlur];
    } else {
        _blurredBackgroundImage = nil;
    }
    [self broadcastThemeChange];
}

- (void)processBackgroundBlur {
    if (!_backgroundImage || _backgroundBlurIntensity <= 0) {
        _blurredBackgroundImage = nil;
        return;
    }
    CGImageRef cgImage = _backgroundImage.CGImage;
    if (!cgImage) {
        _blurredBackgroundImage = nil;
        return;
    }
    NSUInteger generation = ++_backgroundBlurGeneration;
    CGFloat radius = _backgroundBlurIntensity;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CIImage *inputImage = [CIImage imageWithCGImage:cgImage];
        CGRect extent = inputImage.extent;

        // Clamp the edge pixels outward before blurring: CIGaussianBlur
        // samples outside the image as transparent black, which produced a
        // dark border around the blurred background. Clamping extends the
        // outermost pixels so the blur fades into real content instead.
        CIFilter *clampFilter = [CIFilter filterWithName:@"CIAffineClamp"];
        [clampFilter setValue:inputImage forKey:kCIInputImageKey];
        [clampFilter setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:@"inputTransform"];

        CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [filter setValue:clampFilter.outputImage forKey:kCIInputImageKey];
        [filter setValue:@(radius) forKey:kCIInputRadiusKey];

        // Crop back to the original extent so the (larger) blurred output
        // matches the source image dimensions exactly.
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:filter.outputImage fromRect:extent];
        UIImage *blurred = cgImage ? [UIImage imageWithCGImage:cgImage] : nil;
        if (cgImage) CGImageRelease(cgImage);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_backgroundBlurGeneration) return;
            self->_blurredBackgroundImage = blurred ?: self->_backgroundImage;
            [self broadcastThemeChange];
        });
    });
}

- (UIColor *)colorFromHex:(NSString *)hex {
    hex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length == 6) {
        unsigned int rgb = 0;
        [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
        return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:1.0];
    }
    return self.accentColor;
}

- (UIColor *)lighterColor:(UIColor *)color {
    CGFloat h, s, b, a;
    if ([color getHue:&h saturation:&s brightness:&b alpha:&a]) {
        return [UIColor colorWithHue:h saturation:MAX(s - 0.1, 0) brightness:MIN(b + 0.15, 1.0) alpha:a];
    }
    return color;
}

- (BOOL)isDarkMode {
    if (_interfaceStyle == UIUserInterfaceStyleUnspecified) {
        return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return _interfaceStyle == UIUserInterfaceStyleDark;
}

- (UIColor *)accentColor {
    // Default look is monochrome: black buttons in light mode, white in dark.
    // Any saved custom color still wins over this fallback.
    return [self colorOverrideForKey:@"amethyst_accent_color"]
        ?: ([self isDarkMode] ? [UIColor whiteColor] : [UIColor blackColor]);
}

- (UIColor *)accentHoverColor {
    return [self lighterColor:self.accentColor];
}

- (UIColor *)backgroundColor {
    UIColor *override = [self colorOverrideForKey:@"amethyst_bg_color"];
    UIColor *color = override;
    if (!color) color = [self isDarkMode] ? [UIColor colorWithRed:0.039 green:0.039 blue:0.047 alpha:1.0] : [UIColor colorWithRed:0.949 green:0.949 blue:0.957 alpha:1.0];
    return [color colorWithAlphaComponent:_uiOpacity];
}

- (UIColor *)cardBackgroundColor {
    UIColor *override = [self colorOverrideForKey:@"amethyst_card_bg_color"];
    UIColor *color = override;
    if (!color) color = [self isDarkMode] ? [UIColor colorWithRed:0.086 green:0.086 blue:0.094 alpha:1.0] : [UIColor whiteColor];
    return [color colorWithAlphaComponent:_uiOpacity];
}

- (UIColor *)sidebarBackgroundColor {
    UIColor *override = [self colorOverrideForKey:@"amethyst_sidebar_bg_color"];
    UIColor *color = override;
    if (!color) color = [self isDarkMode] ? [UIColor colorWithRed:0.051 green:0.051 blue:0.059 alpha:1.0] : [UIColor colorWithRed:0.969 green:0.969 blue:0.973 alpha:1.0];
    return [color colorWithAlphaComponent:_uiOpacity];
}

- (UIColor *)topBarBackgroundColor {
    UIColor *override = [self colorOverrideForKey:@"amethyst_topbar_bg_color"];
    UIColor *color = override;
    if (!color) color = [self isDarkMode] ? [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0] : [UIColor colorWithRed:0.973 green:0.973 blue:0.976 alpha:1.0];
    return [color colorWithAlphaComponent:_uiOpacity];
}

- (UIColor *)rightPanelBackgroundColor {
    UIColor *override = [self colorOverrideForKey:@"amethyst_rightpanel_bg_color"];
    UIColor *color = override;
    if (!color) color = self.cardBackgroundColor;
    return [color colorWithAlphaComponent:_uiOpacity];
}

- (UIColor *)primaryTextColor {
    return [self colorOverrideForKey:@"amethyst_text_color"]
        ?: ([self isDarkMode] ? [UIColor whiteColor] : [UIColor blackColor]);
}

- (UIColor *)secondaryTextColor {
    return [self colorOverrideForKey:@"amethyst_secondary_text_color"]
        ?: ([self isDarkMode] ? [UIColor colorWithRed:0.596 green:0.596 blue:0.620 alpha:1.0] : [UIColor colorWithRed:0.557 green:0.557 blue:0.576 alpha:1.0]);
}

- (UIColor *)separatorColor {
    return [self isDarkMode] ? [UIColor colorWithRed:0.220 green:0.220 blue:0.227 alpha:1.0] : [UIColor colorWithRed:0.780 green:0.780 blue:0.800 alpha:1.0];
}

- (UIColor *)successColor {
    return [UIColor colorWithRed:0.384 green:1.0 blue:0.541 alpha:1.0];
}

- (UIColor *)warningColor {
    return [UIColor colorWithRed:1.0 green:0.937 blue:0.459 alpha:1.0];
}

- (UIColor *)errorColor {
    return [UIColor colorWithRed:1.0 green:0.388 blue:0.357 alpha:1.0];
}

- (UIColor *)contrastTextColorForBackground:(UIColor *)background {
    // Contrast against the given background so text stays readable on
    // both black/white defaults and user-picked colors.
    CGFloat r, g, b, a;
    if ([background getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat luminance = 0.299 * r + 0.587 * g + 0.114 * b;
        return luminance > 0.55 ? [UIColor blackColor] : [UIColor whiteColor];
    }
    return [self isDarkMode] ? [UIColor blackColor] : [UIColor whiteColor];
}

- (UIColor *)buttonTextColor {
    return [self contrastTextColorForBackground:self.accentColor];
}

- (void)styleSegmentedControl:(UISegmentedControl *)seg {
    if (!seg) return;
    UIColor *selBg = self.accentColor;
    seg.selectedSegmentTintColor = selBg;
    UIColor *selText = [self contrastTextColorForBackground:selBg];
    NSDictionary *normal = [seg titleTextAttributesForState:UIControlStateNormal];
    NSDictionary *selected = [seg titleTextAttributesForState:UIControlStateSelected];
    UIFont *normalFont = normal[NSFontAttributeName];
    UIFont *selectedFont = selected[NSFontAttributeName];
    if (![normalFont isKindOfClass:[UIFont class]]) {
        normalFont = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    }
    if (![selectedFont isKindOfClass:[UIFont class]]) {
        selectedFont = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    }
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: self.primaryTextColor, NSFontAttributeName: normalFont} forState:UIControlStateNormal];
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: selText, NSFontAttributeName: selectedFont} forState:UIControlStateSelected];
}

- (void)applyAccentColor:(UIColor *)color {
    [self applyAccentColor:color darkMode:self.isDarkMode];
}

- (void)applyAccentColor:(UIColor *)color darkMode:(BOOL)dark {
    NSString *modeKey = [self modePrefKeyFor:@"amethyst_accent_color" dark:dark];
    _colorOverrides[modeKey] = color;
    NSString *hex = [self hexStringFromColor:color];
    [[NSUserDefaults standardUserDefaults] setObject:hex forKey:modeKey];
    [self broadcastThemeChange];
}

- (void)applyColor:(UIColor *)color forKey:(NSString *)key {
    [self applyColor:color forKey:key darkMode:self.isDarkMode];
}

- (void)applyColor:(UIColor *)color forKey:(NSString *)key darkMode:(BOOL)dark {
    NSString *modeKey = [self modePrefKeyFor:key dark:dark];
    _colorOverrides[modeKey] = color;
    NSString *hex = [self hexStringFromColor:color];
    [[NSUserDefaults standardUserDefaults] setObject:hex forKey:modeKey];
    [self broadcastThemeChange];
}

- (NSString *)hexStringFromColor:(UIColor *)color {
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)(r * 255), (int)(g * 255), (int)(b * 255)];
}

- (void)applyInterfaceStyle:(UIUserInterfaceStyle)style {
    _interfaceStyle = style;
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:@"amethyst_interface_style"];
    [self broadcastThemeChange];
}

- (void)applyThemeToAllWindows {
    // Iterate scenes: sharedApplication.windows can miss the key window,
    // which left manual Dark/Light switches with no visible effect.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            window.overrideUserInterfaceStyle = _interfaceStyle;
        }
    }
    // Fallback for any window not attached to a scene yet.
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        window.overrideUserInterfaceStyle = _interfaceStyle;
    }
    [self broadcastThemeChange];
}

- (void)windowBecameKey:(NSNotification *)note {
    if (_interfaceStyle == UIUserInterfaceStyleUnspecified) return;
    UIWindow *window = note.object;
    if ([window isKindOfClass:[UIWindow class]]) {
        window.overrideUserInterfaceStyle = _interfaceStyle;
    }
}

- (void)broadcastThemeChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:ThemeDidChangeNotification object:nil];
}

- (BOOL)shouldApplyBorderToView:(UIView *)view {
    return NO;
}

- (BOOL)shouldSkipCornerRadiusForView:(UIView *)view {
    return YES;
}

- (void)applyBorderStyleToViewTree:(UIView *)view {
}

- (void)applyBorderStyleToAllWindows {
}

- (void)resetAppearance {
    [_colorOverrides removeAllObjects];

    NSArray *colorKeys = @[@"amethyst_accent_color", @"amethyst_bg_color", @"amethyst_card_bg_color",
                           @"amethyst_sidebar_bg_color", @"amethyst_topbar_bg_color", @"amethyst_rightpanel_bg_color",
                           @"amethyst_text_color", @"amethyst_secondary_text_color"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in colorKeys) {
        [defaults removeObjectForKey:[self modePrefKeyFor:key dark:YES]];
        [defaults removeObjectForKey:[self modePrefKeyFor:key dark:NO]];
        [defaults removeObjectForKey:key];
    }
    [defaults removeObjectForKey:@"amethyst_bg_image"];
    [defaults removeObjectForKey:@"amethyst_bg_video"];
    [defaults removeObjectForKey:@"amethyst_bg_blur"];
    [defaults removeObjectForKey:@"amethyst_ui_opacity"];
    [defaults removeObjectForKey:@"amethyst_settings_blur"];

    _backgroundImage = nil;
    _blurredBackgroundImage = nil;
    _backgroundVideoURL = nil;
    _backgroundBlurIntensity = 0;
    _uiOpacity = 1.0;

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *imgPath = [paths.firstObject stringByAppendingPathComponent:@"amethyst_bg.png"];
    [[NSFileManager defaultManager] removeItemAtPath:imgPath error:nil];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:paths.firstObject error:nil]) {
        if ([name hasPrefix:@"amethyst_bg"] && [name.pathExtension isEqualToString:@"mp4"]) {
            [[NSFileManager defaultManager] removeItemAtPath:[paths.firstObject stringByAppendingPathComponent:name] error:nil];
        }
    }

    [self broadcastThemeChange];
}

- (void)applyZalithPreset {
    // Theme mặc định Embermire của Zalith 2, lấy đúng từ ui/theme/Color.kt
    // và Theme.kt của Zalith (palette Material 3, cả chế độ sáng và tối).
    NSDictionary<NSString *, NSString *> *dark = @{
        @"amethyst_accent_color":         @"#FFB59F",
        @"amethyst_bg_color":             @"#1C110E",
        @"amethyst_card_bg_color":        @"#291D19",
        @"amethyst_sidebar_bg_color":     @"#241916",
        @"amethyst_topbar_bg_color":      @"#241916",
        @"amethyst_rightpanel_bg_color":  @"#291D19",
        @"amethyst_text_color":           @"#F4DED8",
        @"amethyst_secondary_text_color": @"#DFC0B7",
    };
    NSDictionary<NSString *, NSString *> *light = @{
        @"amethyst_accent_color":         @"#A63A17",
        @"amethyst_bg_color":             @"#FFF8F6",
        @"amethyst_card_bg_color":        @"#FFE9E4",
        @"amethyst_sidebar_bg_color":     @"#FFF1ED",
        @"amethyst_topbar_bg_color":      @"#FFF1ED",
        @"amethyst_rightpanel_bg_color":  @"#FFE9E4",
        @"amethyst_text_color":           @"#241916",
        @"amethyst_secondary_text_color": @"#58423B",
    };

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in dark) {
        NSString *darkKey = [self modePrefKeyFor:key dark:YES];
        NSString *lightKey = [self modePrefKeyFor:key dark:NO];
        [defaults setObject:dark[key] forKey:darkKey];
        [defaults setObject:light[key] forKey:lightKey];
        _colorOverrides[darkKey] = [self colorFromHex:dark[key]];
        _colorOverrides[lightKey] = [self colorFromHex:light[key]];
    }

    // Card ngoài của Zalith bo 28 pt (đúng bằng giới hạn tối đa của Witch).
    // Zalith không có viền; opacity giữ 100%.
    _uiBorderEnabled = NO;
    _uiBorderCornerRadius = 28.0;
    _uiOpacity = 1.0;
    [defaults setBool:NO forKey:@"amethyst_ui_border_enabled"];
    [defaults setFloat:28.0 forKey:@"amethyst_ui_border_radius"];
    [defaults setFloat:1.0 forKey:@"amethyst_ui_opacity"];

    [self broadcastThemeChange];
}

@end
