#import "WitchLaunchMusic.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "LauncherPreferences.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

static NSArray<NSString *> *WitchLaunchMusicExtensions(void) {
    // What AVAudioPlayer can decode on every supported iOS version.
    return @[@"mp3", @"m4a", @"aac", @"wav", @"caf", @"aif", @"aiff", @"flac"];
}

static const NSTimeInterval kFadeIn = 0.8;
static const NSTimeInterval kFadeOut = 0.4;
static const float kVolume = 0.85f;
static const NSTimeInterval kPreviewLength = 10.0;
// A launch that never reaches its first frame must not leave the music looping for ever.
static const NSTimeInterval kMaxLaunchPlay = 300.0;

// All of this runs on the main thread.
static AVAudioPlayer *gPlayer;
static BOOL gStopping;
static NSUInteger gToken; // bumped on every start/stop so a late fade-out never cuts a newer playback

static BOOL gSessionChanged;
static NSString *gSavedCategory;
static NSString *gSavedMode;
static AVAudioSessionCategoryOptions gSavedOptions;

@interface WitchLaunchMusicPicker : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^completion)(NSUInteger added);
@end

static WitchLaunchMusicPicker *gPicker; // keeps the delegate alive while the picker is on screen

@implementation WitchLaunchMusic

#pragma mark - Tracks

+ (BOOL)enabled {
    return getPrefBool(@"appearance.launch_music");
}

+ (NSString *)directoryPath {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [documents stringByAppendingPathComponent:@"LaunchMusic"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

+ (NSArray<NSString *> *)userTrackPaths {
    NSString *directory = [self directoryPath];
    NSMutableArray<NSString *> *tracks = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        if (![WitchLaunchMusicExtensions() containsObject:name.pathExtension.lowercaseString]) continue;
        [tracks addObject:[directory stringByAppendingPathComponent:name]];
    }
    [tracks sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return tracks;
}

+ (NSString *)bundledTrackPath {
    for (NSString *ext in WitchLaunchMusicExtensions()) {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"launch_music" ofType:ext];
        if (path.length > 0) return path;
    }
    return nil;
}

+ (NSURL *)pickTrackURL {
    NSArray<NSString *> *tracks = [self userTrackPaths];
    NSString *path = tracks.count > 0 ? tracks[arc4random_uniform((uint32_t)tracks.count)] : [self bundledTrackPath];
    return path ? [NSURL fileURLWithPath:path] : nil;
}

+ (BOOL)canPlay {
    return [self enabled] && ([self userTrackPaths].count > 0 || [self bundledTrackPath] != nil);
}

+ (NSString *)statusText {
    NSArray<NSString *> *tracks = [self userTrackPaths];
    if (tracks.count == 1) return tracks.firstObject.lastPathComponent;
    if (tracks.count > 1) return [NSString stringWithFormat:localize(@"launch_music.status_many", nil), (unsigned long)tracks.count];
    return [self bundledTrackPath] ? localize(@"launch_music.status_builtin", nil) : localize(@"launch_music.status_none", nil);
}

+ (void)removeAllTracks {
    [self stopWithFade:NO];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in [self userTrackPaths]) [fm removeItemAtPath:path error:nil];
}

#pragma mark - Audio session

// Only the Settings preview borrows the session: the launcher menu has no game audio to disturb. While a version
// boots, the music plays on the session the game has already configured (SurfaceViewController
// -updateAudioSettings) and leaves it alone, because changing its category would drop the microphone routing
// that a voice-chat mod relies on.
+ (void)takeAudioSession {
    if (gSessionChanged) return;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    gSavedCategory = session.category;
    gSavedMode = session.mode;
    gSavedOptions = session.categoryOptions;
    NSError *error = nil;
    // Ambient + mix: respects the silent switch and never takes audio focus from another app.
    if ([session setCategory:AVAudioSessionCategoryAmbient withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error]) {
        [session setActive:YES error:nil];
        gSessionChanged = YES;
    } else {
        NSLog(@"[LaunchMusic] could not set the audio session: %@", error);
    }
}

+ (void)restoreAudioSession {
    if (!gSessionChanged) return;
    gSessionChanged = NO;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    // If the game (or anything else) reconfigured the session while the music was playing, it owns it now.
    if (![session.category isEqualToString:AVAudioSessionCategoryAmbient]) return;
    NSError *error = nil;
    if (![session setCategory:gSavedCategory mode:gSavedMode options:gSavedOptions error:&error]) {
        NSLog(@"[LaunchMusic] could not restore the audio session: %@", error);
    }
}

#pragma mark - Playback

+ (BOOL)beginPlaybackBorrowingSession:(BOOL)borrow {
    if (gPlayer) {
        // Already playing, or fading out: keep it going.
        gToken++;
        gStopping = NO;
        [gPlayer setVolume:kVolume fadeDuration:0.2];
        return YES;
    }
    NSURL *url = [self pickTrackURL];
    if (!url) return NO;
    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!player) {
        NSLog(@"[LaunchMusic] cannot open %@: %@", url.lastPathComponent, error);
        return NO;
    }
    if (borrow) [self takeAudioSession];
    player.numberOfLoops = -1;
    player.volume = 0;
    [player prepareToPlay];
    if (![player play]) {
        NSLog(@"[LaunchMusic] play failed for %@", url.lastPathComponent);
        [self restoreAudioSession];
        return NO;
    }
    [player setVolume:kVolume fadeDuration:kFadeIn];
    gPlayer = player;
    gStopping = NO;
    gToken++;
    return YES;
}

+ (void)stopAfter:(NSTimeInterval)seconds {
    NSUInteger token = gToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token == gToken && gPlayer) [self stopWithFade:YES];
    });
}

+ (void)start {
    if (![self enabled]) return;
    if ([self beginPlaybackBorrowingSession:NO]) [self stopAfter:kMaxLaunchPlay];
}

+ (void)finish:(AVAudioPlayer *)player {
    [player stop];
    if (gPlayer == player) {
        gPlayer = nil;
        gStopping = NO;
        [self restoreAudioSession];
    }
}

+ (void)stopWithFade:(BOOL)fade {
    AVAudioPlayer *player = gPlayer;
    if (!player) return;
    if (fade && gStopping) return; // a fade-out is already on its way
    NSUInteger token = ++gToken;
    gStopping = YES;
    if (!fade) {
        [self finish:player];
        return;
    }
    [player setVolume:0 fadeDuration:kFadeOut];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kFadeOut + 0.05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != gToken) return; // started again in the meantime
        [self finish:player];
    });
}

+ (BOOL)togglePreview {
    if (gPlayer && !gStopping) {
        [self stopWithFade:YES];
        return YES;
    }
    if (![self beginPlaybackBorrowingSession:YES]) return NO;
    [self stopAfter:kPreviewLength];
    return YES;
}

#pragma mark - Picking files

+ (void)presentPickerFromViewController:(UIViewController *)presenter completion:(void (^)(NSUInteger))completion {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    WitchLaunchMusicPicker *delegate = [WitchLaunchMusicPicker new];
    delegate.completion = completion;
    gPicker = delegate;
    picker.delegate = delegate;
    [presenter presentViewController:picker animated:YES completion:nil];
}

@end

@implementation WitchLaunchMusicPicker

- (void)finishWithAdded:(NSUInteger)added rejected:(NSArray<NSString *> *)rejected {
    gPicker = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (rejected.count > 0) {
            showDialog(localize(@"Error", nil),
                       [NSString stringWithFormat:localize(@"launch_music.bad_files", nil),
                        [rejected componentsJoinedByString:@", "]]);
        }
        if (self.completion) self.completion(added);
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *directory = [WitchLaunchMusic directoryPath];
    NSUInteger added = 0;
    NSMutableArray<NSString *> *rejected = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *name = url.lastPathComponent;
        if (![WitchLaunchMusicExtensions() containsObject:url.pathExtension.lowercaseString]) {
            [rejected addObject:name];
            continue;
        }
        NSString *destination = [directory stringByAppendingPathComponent:name];
        BOOL access = [url startAccessingSecurityScopedResource];
        [fm removeItemAtPath:destination error:nil];
        NSError *error = nil;
        BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error];
        if (access) [url stopAccessingSecurityScopedResource];
        // Keep only what the player can really open, so a broken file never ends up silent at launch.
        if (ok && [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:destination] error:&error] == nil) {
            [fm removeItemAtPath:destination error:nil];
            ok = NO;
        }
        if (ok) {
            added++;
        } else {
            NSLog(@"[LaunchMusic] could not use %@: %@", name, error);
            [rejected addObject:name];
        }
    }
    [self finishWithAdded:added rejected:rejected];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finishWithAdded:0 rejected:@[]];
}

@end
