// PE Buttons — built-in PE-style skin for the Witch touch controls.
// Ported from the community plugin com.witch.community.pe-buttons 1.1.0 (ABI 2).
//
// Re-skins the in-game touch controls (ControlButton / ControlDrawer / ControlJoystick)
// in the style of Minecraft: Pocket/Bedrock Edition, using the button textures of the
// TouchController mod (https://github.com/fifth-light/TouchController, LGPL-3.0-or-later).
//
//  * Action buttons (D-pad, jump, sneak, sprint, inventory, chat, pause, ...) use the
//    ready-made sprite for that action, with its pressed ("_active") variant.
//  * Every other button keeps its name, drawn over an empty PE-style nine-patch button.
//  * "classic" (old PE, stone) and "new" (current Bedrock, rounded) texture sets.
//  * Any texture can be replaced by dropping a PNG with the same relative path into
//    <POJAV_HOME>/PEButtons/  (e.g. PEButtons/classic/jump.png).
//
// Code: MIT.  Textures: LGPL-3.0-or-later (see NOTICE.md).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <string.h>
#import "LauncherPreferences.h"
#import "PEButtons.h"
#import "WitchPluginAPI.h"
#import "glfw_keycodes.h"

// Mirrors SPECIALBTN_* in Natives/utils.h
enum {
    PEKeyKeyboard       = -1,
    PEKeyToggleControls = -2,
    PEKeyMousePrimary   = -3,
    PEKeyMouseSecondary = -4,
    PEKeyVirtualMouse   = -5,
    PEKeyMouseMiddle    = -6,
    PEKeyScrollUp       = -7,
    PEKeyScrollDown     = -8,
    PEKeyMenu           = -9
};

#pragma mark - Settings

static NSString *gStyle        = @"classic";  // texture set: "classic" or "new"
static BOOL      gShowIcons    = YES;         // sprites for known actions
static BOOL      gStyleText    = YES;         // PE background for text-only buttons
static BOOL      gCustomTex    = YES;         // honour <POJAV_HOME>/PEButtons
static NSInteger gTextBg       = 0;           // empty_N background, 0 = by style
static CGFloat   gForcedPoints = 0;           // points per texel, 0 = fit the button

static NSString *PESetting(const WitchPluginHostAPI *host, const char *key) {
    const char *value = host->get_setting(host->userdata, key);
    return value ? @(value) : @"";
}

static BOOL PEBoolSetting(const WitchPluginHostAPI *host, const char *key, BOOL fallback) {
    NSString *text = [PESetting(host, key) lowercaseString];
    if (text.length == 0) return fallback;
    if ([text isEqualToString:@"1"] || [text isEqualToString:@"true"] || [text isEqualToString:@"yes"]) return YES;
    if ([text isEqualToString:@"0"] || [text isEqualToString:@"false"] || [text isEqualToString:@"no"]) return NO;
    return fallback;
}

#pragma mark - Texture loading

static NSString *PEBundledDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Shipped with the app as Witch.app/PEButtons/textures (from Natives/resources).
        directory = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"PEButtons"]
                     stringByAppendingPathComponent:@"textures"];
    });
    return directory;
}

static NSString *PEOverrideDirectory(void) {
    const char *home = getenv("POJAV_HOME");
    return home ? [@(home) stringByAppendingPathComponent:@"PEButtons"] : nil;
}

static NSArray<NSString *> *PESearchDirectories(void) {
    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    if (gCustomTex && PEOverrideDirectory()) [directories addObject:PEOverrideDirectory()];
    if (PEBundledDirectory()) [directories addObject:PEBundledDirectory()];
    return directories;
}

// name is a path relative to textures/ without extension, e.g. "classic/jump_active".
static UIImage *PETexture(NSString *name) {
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    id cached = cache[name];
    if (cached) return [cached isKindOfClass:[UIImage class]] ? cached : nil;

    for (NSString *directory in PESearchDirectories()) {
        NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image.CGImage) {
            cache[name] = image;
            return image;
        }
    }
    cache[name] = [NSNull null];
    return nil;
}

// Stretch borders (in texels) of the nine-patch buttons, from textures/nine.json.
static NSDictionary *PENineTable(void) {
    static NSMutableDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSMutableDictionary dictionary];
        NSArray<NSString *> *directories = PESearchDirectories();
        for (NSInteger i = (NSInteger)directories.count - 1; i >= 0; i--) {   // bundled first, overrides after
            NSData *data = [NSData dataWithContentsOfFile:[directories[i] stringByAppendingPathComponent:@"nine.json"]];
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([json isKindOfClass:[NSDictionary class]]) [table addEntriesFromDictionary:json];
        }
    });
    return table;
}

@interface PENine : NSObject
@property (nonatomic) CGFloat left, top, right, bottom;       // border sizes in texels
@property (nonatomic, strong) NSArray<UIImage *> *slices;     // row-major, 9 images
@end
@implementation PENine
@end

static PENine *PENineSlice(NSString *name) {
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    id cached = cache[name];
    if (cached) return [cached isKindOfClass:[PENine class]] ? cached : nil;

    UIImage *image = PETexture(name);
    CGImageRef source = image.CGImage;
    NSInteger w = source ? (NSInteger)CGImageGetWidth(source) : 0;
    NSInteger h = source ? (NSInteger)CGImageGetHeight(source) : 0;
    NSInteger l = MAX(1, MIN(w, h) / 3), t = l, r = l, b = l;       // default: thirds
    NSDictionary *caps = PENineTable()[name];
    if ([caps isKindOfClass:[NSDictionary class]]) {
        l = [caps[@"l"] integerValue]; t = [caps[@"t"] integerValue];
        r = [caps[@"r"] integerValue]; b = [caps[@"b"] integerValue];
    }
    if (!source || l < 0 || t < 0 || r < 0 || b < 0 || l + r >= w || t + b >= h) {
        cache[name] = [NSNull null];
        return nil;
    }
    NSInteger xs[4] = {0, l, w - r, w};
    NSInteger ys[4] = {0, t, h - b, h};
    NSMutableArray<UIImage *> *slices = [NSMutableArray arrayWithCapacity:9];
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            CGRect rect = CGRectMake(xs[i], ys[j], xs[i + 1] - xs[i], ys[j + 1] - ys[j]);
            CGImageRef part = CGImageCreateWithImageInRect(source, rect);
            UIImage *slice = part ? [UIImage imageWithCGImage:part scale:1.0 orientation:UIImageOrientationUp] : nil;
            if (part) CGImageRelease(part);
            if (!slice) {
                cache[name] = [NSNull null];
                return nil;
            }
            [slices addObject:slice];
        }
    }
    PENine *nine = [PENine new];
    nine.left = l; nine.top = t; nine.right = r; nine.bottom = b;
    nine.slices = slices;
    cache[name] = nine;
    return nine;
}

#pragma mark - Texture names

static NSString *PESpriteName(NSString *item, BOOL active) {
    return [NSString stringWithFormat:@"%@/%@%@", gStyle, item, active ? @"_active" : @""];
}

// An item's sprite for the current style; "attack" falls back to the pickaxe.
static NSString *PEResolveItem(NSString *item) {
    if (item.length == 0) return nil;
    if (PETexture(PESpriteName(item, NO))) return item;
    if ([item isEqualToString:@"attack"] && PETexture(PESpriteName(@"pickaxe", NO))) return @"pickaxe";
    return nil;
}

static NSString *PEEmptyName(BOOL active) {
    NSInteger index = gTextBg;
    if (index < 1 || index > 5) index = [gStyle isEqualToString:@"new"] ? 2 : 1;
    return [NSString stringWithFormat:@"empty/empty_%ld%@", (long)index, active ? @"_active" : @""];
}

#pragma mark - Drawing helpers

static CGFloat PEAlign(CGFloat value, CGFloat scale) {
    return round(value * scale) / scale;
}

static void PEDrawNine(PENine *nine, CGRect rect, CGFloat unit) {
    CGFloat xs[4] = {CGRectGetMinX(rect), CGRectGetMinX(rect) + nine.left * unit,
                     CGRectGetMaxX(rect) - nine.right * unit, CGRectGetMaxX(rect)};
    CGFloat ys[4] = {CGRectGetMinY(rect), CGRectGetMinY(rect) + nine.top * unit,
                     CGRectGetMaxY(rect) - nine.bottom * unit, CGRectGetMaxY(rect)};
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            CGRect destination = CGRectMake(xs[i], ys[j], xs[i + 1] - xs[i], ys[j + 1] - ys[j]);
            if (destination.size.width > 0 && destination.size.height > 0) {
                [nine.slices[j * 3 + i] drawInRect:destination];
            }
        }
    }
}

#pragma mark - Skin views

static const void *PESkinKey  = &PESkinKey;
static const void *PEBaseKey  = &PEBaseKey;
static const void *PEThumbKey = &PEThumbKey;

@interface PEButtonSkin : UIView
@property (nonatomic, copy) NSString *item;     // sprite item; nil = empty button (name is drawn by the UIButton)
@property (nonatomic) BOOL active;              // pressed or toggled on
@end

@implementation PEButtonSkin

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)setItem:(NSString *)item {
    if ((_item == item) || [_item isEqualToString:item]) return;
    _item = [item copy];
    [self setNeedsDisplay];
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)dirty {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);   // keep texels square

    CGFloat scale = self.contentScaleFactor > 0 ? self.contentScaleFactor : UIScreen.mainScreen.scale;
    CGRect bounds = self.bounds;
    CGFloat minSide = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (minSide < 4.0) return;
    CGRect rect = CGRectMake(PEAlign(CGRectGetMinX(bounds), scale), PEAlign(CGRectGetMinY(bounds), scale),
                             floor(CGRectGetWidth(bounds) * scale) / scale,
                             floor(CGRectGetHeight(bounds) * scale) / scale);

    if (self.item.length > 0) {
        UIImage *sprite = (self.active ? PETexture(PESpriteName(self.item, YES)) : nil) ?: PETexture(PESpriteName(self.item, NO));
        CGImageRef cg = sprite.CGImage;
        if (cg) {
            CGRect destination = rect;
            if (gForcedPoints > 0) {
                CGFloat texel = round(gForcedPoints * scale) / scale;
                CGFloat w = CGImageGetWidth(cg) * texel, h = CGImageGetHeight(cg) * texel;
                destination = CGRectMake(PEAlign((CGRectGetWidth(bounds) - w) / 2.0, scale),
                                         PEAlign((CGRectGetHeight(bounds) - h) / 2.0, scale), w, h);
            }
            [sprite drawInRect:destination];
            return;
        }
    }

    PENine *nine = (self.active ? PENineSlice(PEEmptyName(YES)) : nil) ?: PENineSlice(PEEmptyName(NO));
    if (!nine) {
        // Never leave a control invisible if the texture files are missing.
        [[UIColor colorWithWhite:0.55 alpha:0.9] setFill];
        UIRectFill(rect);
        return;
    }
    NSString *emptyName = PEEmptyName(NO);
    UIImage *emptyImage = PETexture(emptyName);
    CGFloat textureWidth = emptyImage.CGImage ? (CGFloat)CGImageGetWidth(emptyImage.CGImage) : 18.0;
    // Device pixels per texel: an integer, so every texel stays a crisp square.
    CGFloat devicePerTexel = gForcedPoints > 0 ? round(gForcedPoints * scale)
                                               : MAX(1.0, round(minSide * scale / textureWidth));
    CGFloat borders = MAX(nine.left + nine.right, nine.top + nine.bottom);
    CGFloat maxFit = floor(minSide * scale / MAX(1.0, borders));
    devicePerTexel = MAX(1.0, MIN(devicePerTexel, maxFit));
    PEDrawNine(nine, rect, devicePerTexel / scale);
}

@end

static UIImageView *PEPixelImageView(UIView *host, const void *key, NSString *textureName) {
    UIImage *image = PETexture(textureName);
    if (!image) return nil;
    UIImageView *view = objc_getAssociatedObject(host, key);
    if (!view) {
        view = [[UIImageView alloc] initWithImage:image];
        view.userInteractionEnabled = NO;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        view.layer.magnificationFilter = kCAFilterNearest;
        view.layer.minificationFilter = kCAFilterNearest;
        [host insertSubview:view atIndex:0];
        objc_setAssociatedObject(host, key, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.frame = host.bounds;
    return view;
}

#pragma mark - Button -> sprite mapping

static BOOL PEIsToggleOn(id button) {
    if (![button respondsToSelector:NSSelectorFromString(@"isToggleOn")]) return NO;
    id value = [button valueForKey:@"isToggleOn"];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

// Returns the sprite item for a button, or nil to show its name on an empty PE button.
static NSString *PEItemForButton(id button) {
    NSDictionary *properties = [button valueForKey:@"properties"];
    if (![properties isKindOfClass:[NSDictionary class]]) return nil;

    // Only map buttons that send exactly one key; combos keep their written name.
    NSInteger key = 0;
    NSInteger count = 0;
    id keys = properties[@"keycodes"];
    if ([keys isKindOfClass:[NSArray class]]) {
        for (id value in keys) {
            if ([value isKindOfClass:[NSNumber class]] && [value integerValue] != 0) {
                key = [value integerValue];
                count++;
            }
        }
    }
    if (count == 0 && [properties[@"keycode"] isKindOfClass:[NSNumber class]]) {
        key = [properties[@"keycode"] integerValue];
        count = key != 0 ? 1 : 0;
    }
    if (count != 1) return nil;

    switch (key) {
        case GLFW_KEY_SPACE:        return @"jump";
        case GLFW_KEY_LEFT_SHIFT:   return @"sneak";
        case GLFW_KEY_LEFT_CONTROL: return @"sprint";
        case GLFW_KEY_E:            return @"inventory";
        case GLFW_KEY_T:            return @"chat";
        case GLFW_KEY_ESCAPE:
        case PEKeyMenu:             return @"pause";
        case GLFW_KEY_F1:           return @"hide_hud";
        case GLFW_KEY_F2:           return @"screenshot";
        case GLFW_KEY_F3:           return @"debug_screen";
        case GLFW_KEY_F5:           return @"perspective";
        case GLFW_KEY_F:            return @"shield";
        case GLFW_KEY_TAB:          return @"player_list";
        case PEKeyMousePrimary:     return @"attack";
        case PEKeyMouseSecondary:   return @"use";
        case GLFW_KEY_W:
        case GLFW_KEY_DPAD_UP:
        case PEKeyScrollUp:         return @"up";
        case GLFW_KEY_S:
        case GLFW_KEY_DPAD_DOWN:
        case PEKeyScrollDown:       return @"down";
        case GLFW_KEY_A:
        case GLFW_KEY_DPAD_LEFT:    return @"left";
        case GLFW_KEY_D:
        case GLFW_KEY_DPAD_RIGHT:   return @"right";
        default:                    return nil;
    }
}

#pragma mark - Styling

static void PEStyleButton(id button) {
    UIButton *control = (UIButton *)button;
    NSDictionary *properties = [button valueForKey:@"properties"];
    NSString *name = [properties[@"name"] isKindOfClass:[NSString class]] ? properties[@"name"] : @"";

    // Sprites are square: use one only when the button is roughly square too.
    CGFloat width = CGRectGetWidth(control.bounds), height = CGRectGetHeight(control.bounds);
    CGFloat ratio = height > 0 ? width / height : 1.0;
    NSString *item = nil;
    if (gShowIcons && ratio >= 0.75 && ratio <= 1.33) item = PEResolveItem(PEItemForButton(button));

    PEButtonSkin *skin = objc_getAssociatedObject(button, PESkinKey);
    if (!skin) {
        if (!item && !gStyleText) return;     // leave text-only buttons untouched
        skin = [[PEButtonSkin alloc] initWithFrame:control.bounds];
        [control insertSubview:skin atIndex:0];
        objc_setAssociatedObject(button, PESkinKey, skin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    skin.frame = control.bounds;
    skin.item = item;
    skin.active = PEIsToggleOn(button) || control.highlighted;

    control.backgroundColor = UIColor.clearColor;   // also routed through PESetBackgroundColor
    control.layer.borderWidth = 0;
    control.layer.cornerRadius = 0;

    if (item.length > 0) {
        control.titleLabel.hidden = YES;
        control.accessibilityLabel = name.length > 0 ? name : item;
    } else {
        CGFloat side = MIN(width, height);
        CGFloat scale = UIScreen.mainScreen.scale;
        CGFloat shadow = MAX(1.0, round(side * scale / 18.0)) / scale;   // about one texel
        control.titleLabel.hidden = NO;
        control.titleLabel.font = [UIFont systemFontOfSize:MIN(MAX(10.0, side * 0.30), 18.0) weight:UIFontWeightBold];
        [control setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [control setTitleColor:UIColor.whiteColor forState:UIControlStateHighlighted];
        // Hard, un-blurred drop shadow in the game's dark gray.
        UIColor *shadowColor = [UIColor colorWithWhite:0.247 alpha:1.0];
        [control setTitleShadowColor:shadowColor forState:UIControlStateNormal];
        [control setTitleShadowColor:shadowColor forState:UIControlStateHighlighted];
        control.titleLabel.shadowOffset = CGSizeMake(shadow, shadow);
        control.accessibilityLabel = name;
    }
    [skin setNeedsDisplay];
}

static void PEStyleJoystick(id joystick) {
    UIView *control = (UIView *)joystick;
    control.backgroundColor = UIColor.clearColor;
    control.layer.borderWidth = 0;

    UIView *background = [joystick valueForKey:@"background"];
    UIView *thumb = [joystick valueForKey:@"thumb"];
    if (background) {
        background.backgroundColor = UIColor.clearColor;
        background.layer.borderWidth = 0;
        PEPixelImageView(background, PEBaseKey, [NSString stringWithFormat:@"%@/joystick_pad", gStyle]);
    }
    if (thumb) {
        thumb.backgroundColor = UIColor.clearColor;
        thumb.layer.borderWidth = 0;
        PEPixelImageView(thumb, PEThumbKey, [NSString stringWithFormat:@"%@/joystick_stick", gStyle]);
    }
}

#pragma mark - Hooks

static IMP gOriginalButtonUpdate;
static IMP gOriginalJoystickUpdate;
static IMP gOriginalSetBackgroundColor;
static IMP gOriginalSetHighlighted;
static BOOL gHooksInstalled;

static void PEButtonUpdate(id self, SEL _cmd) {
    ((void (*)(id, SEL))gOriginalButtonUpdate)(self, _cmd);
    if (![self isKindOfClass:NSClassFromString(@"ControlJoystick")]) PEStyleButton(self);
}

static void PEJoystickUpdate(id self, SEL _cmd) {
    ((void (*)(id, SEL))gOriginalJoystickUpdate)(self, _cmd);
    PEStyleJoystick(self);
}

// The game tints toggle buttons by assigning backgroundColor when they flip. Keep the
// sprite in charge: stay transparent and just refresh the active look.
static void PESetBackgroundColor(id self, SEL _cmd, UIColor *color) {
    PEButtonSkin *skin = objc_getAssociatedObject(self, PESkinKey);
    if (skin) {
        ((void (*)(id, SEL, UIColor *))gOriginalSetBackgroundColor)(self, _cmd, UIColor.clearColor);
        skin.active = PEIsToggleOn(self) || ((UIButton *)self).highlighted;
        return;
    }
    ((void (*)(id, SEL, UIColor *))gOriginalSetBackgroundColor)(self, _cmd, color);
}

static void PESetHighlighted(id self, SEL _cmd, BOOL highlighted) {
    ((void (*)(id, SEL, BOOL))gOriginalSetHighlighted)(self, _cmd, highlighted);
    PEButtonSkin *skin = objc_getAssociatedObject(self, PESkinKey);
    if (skin) skin.active = highlighted || PEIsToggleOn(self);
}

static BOOL PEHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return YES;
}

static BOOL PEInstallHooks(const WitchPluginHostAPI *host) {
    if (gHooksInstalled) return YES;
    Class buttonClass = NSClassFromString(@"ControlButton");
    Class joystickClass = NSClassFromString(@"ControlJoystick");
    if (!buttonClass) {
        host->log(host->userdata, "PE Buttons: ControlButton class is unavailable");
        return NO;
    }
    if (!PENineSlice(PEEmptyName(NO)) || !PETexture(PESpriteName(@"jump", NO))) {
        host->log(host->userdata, "PE Buttons: textures not found next to the plugin library");
        return NO;
    }
    if (!PEHook(buttonClass, NSSelectorFromString(@"update"), (IMP)PEButtonUpdate, &gOriginalButtonUpdate)) {
        host->log(host->userdata, "PE Buttons: -[ControlButton update] is unavailable");
        return NO;
    }
    PEHook(buttonClass, @selector(setBackgroundColor:), (IMP)PESetBackgroundColor, &gOriginalSetBackgroundColor);
    PEHook(buttonClass, @selector(setHighlighted:), (IMP)PESetHighlighted, &gOriginalSetHighlighted);
    if (joystickClass) {
        PEHook(joystickClass, NSSelectorFromString(@"update"), (IMP)PEJoystickUpdate, &gOriginalJoystickUpdate);
    }
    gHooksInstalled = YES;
    host->log(host->userdata, "PE Buttons: control hooks installed");
    return YES;
}

// Reads the skin options from the host, then installs the hooks.
static BOOL PEConfigureAndInstall(const WitchPluginHostAPI *host) {
    NSString *style = [PESetting(host, "style") lowercaseString];
    gStyle = [style isEqualToString:@"new"] ? @"new" : @"classic";
    gShowIcons    = PEBoolSetting(host, "show_icons", YES);
    gStyleText    = PEBoolSetting(host, "style_text_buttons", YES);
    gCustomTex    = PEBoolSetting(host, "custom_textures", YES);
    gTextBg       = PESetting(host, "text_background").integerValue;
    gForcedPoints = MAX(0.0, MIN(8.0, PESetting(host, "pixel_size").doubleValue));

    return PEInstallHooks(host);
}

#pragma mark - Built-in entry point

// Stands in for the plugin host. Options come from the launcher preferences; an option
// that is not set keeps the default above.
static void PEHostLog(void *userdata, const char *message) {
    (void)userdata;
    NSLog(@"[PEButtons] %s", message ? message : "");
}

static const char *PEHostGetSetting(void *userdata, const char *key) {
    (void)userdata;
    if (key && strcmp(key, "style") == 0) {
        return [getPrefObject(@"control.pe_buttons_style") isEqual:@"new"] ? "new" : "classic";
    }
    return NULL;
}

// A missing key means on. getPrefBool() reads a missing key as NO, so write the default once.
static BOOL PEButtonsWanted(void) {
    if (!getPrefObject(@"control.pe_buttons")) setPrefBool(@"control.pe_buttons", YES);
    return getPrefBool(@"control.pe_buttons");
}

// True when code outside this image, such as the community plugin's dylib, has already
// replaced the ControlButton update method. A second skin on top would stack sprites twice.
static BOOL PEControlsHookedElsewhere(void) {
    Method method = class_getInstanceMethod(NSClassFromString(@"ControlButton"), NSSelectorFromString(@"update"));
    if (!method) return NO;
    Dl_info ours, theirs;
    if (!dladdr((void *)PEButtonsInstallIfEnabled, &ours)) return NO;
    if (!dladdr((void *)method_getImplementation(method), &theirs)) return NO;
    return theirs.dli_fbase != ours.dli_fbase;
}

void PEButtonsInstallIfEnabled(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!PEButtonsWanted()) {
            NSLog(@"[PEButtons] off in settings");
            return;
        }
        if (PEControlsHookedElsewhere()) {
            NSLog(@"[PEButtons] controls already skinned by another plugin; built-in skin skipped");
            return;
        }
        WitchPluginHostAPI host = {0};
        host.abi_version = WITCH_PLUGIN_ABI_VERSION;
        host.log = PEHostLog;
        host.get_setting = PEHostGetSetting;
        PEConfigureAndInstall(&host);
    });
}
