#import "BackgroundMusicManager.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NSNotificationName const BackgroundMusicDidChangeNotification = @"BackgroundMusicDidChangeNotification";

static NSString *const kBGMEnabledPref = @"music.enabled";
static NSString *const kBGMCustomFilePref = @"music.custom_file";
static NSString *const kBGMBundledBaseName = @"WitchBGM";
static const float kBGMVolume = 0.6f;

static NSArray<NSString *> *BGMSupportedExtensions(void) {
    return @[@"m4a", @"mp3", @"aac", @"wav", @"caf", @"aiff"];
}

// Imported tracks live in their own folder so replacing or resetting the
// track only ever touches files this feature created.
static NSURL *BGMCustomDirectory(void) {
    NSURL *support = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                           inDomains:NSUserDomainMask] firstObject];
    return [support URLByAppendingPathComponent:@"WitchBGM" isDirectory:YES];
}

@interface BackgroundMusicManager ()
@property (nonatomic) AVAudioPlayer *player;
@property (nonatomic, nullable) NSURL *playerURL;
// Owned by the root view controller; weak so a replaced video is never kept alive here.
@property (nonatomic, weak, nullable) AVPlayer *videoPlayer;
@property (nonatomic) BOOL gameRunning;
@property (nonatomic) BOOL appInForeground;
@end

@implementation BackgroundMusicManager

+ (instancetype)shared {
    static BackgroundMusicManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[BackgroundMusicManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _appInForeground = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(audioSessionInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
        // Start playback at launch when the toggle was left on.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reconcile];
        });
    }
    return self;
}

#pragma mark - State

- (BOOL)enabled {
    return getPrefBool(kBGMEnabledPref);
}

- (void)setEnabled:(BOOL)enabled {
    setPrefBool(kBGMEnabledPref, enabled);
    [self reconcile];
}

- (BOOL)isPlaying {
    if (self.usingVideoAudio) return !self.videoPlayer.muted && self.videoPlayer.rate > 0;
    return self.player.isPlaying;
}

- (BOOL)hasTrack {
    return self.usingVideoAudio || [self currentTrackURL] != nil;
}

- (BOOL)usingVideoAudio {
    return self.videoPlayer != nil;
}

- (void)setVideoPlayer:(AVPlayer *)player {
    if (self.videoPlayer == player) return;
    // The outgoing player must not keep sounding after it leaves the launcher.
    self.videoPlayer.muted = YES;
    self.videoPlayer = player;
    [self reconcile];
}

- (BOOL)usingCustomTrack {
    return [self customTrackURL] != nil;
}

- (NSString *)trackName {
    return [self currentTrackURL].lastPathComponent;
}

- (void)setGameRunning:(BOOL)running {
    if (self.gameRunning == running) return;
    self.gameRunning = running;
    [self reconcile];
}

#pragma mark - Lifecycle

- (void)appDidEnterBackground {
    self.appInForeground = NO;
    [self reconcile];
}

- (void)appDidBecomeActive {
    self.appInForeground = YES;
    [self reconcile];
}

- (void)audioSessionInterrupted:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type != AVAudioSessionInterruptionTypeEnded) return;
    NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
    if (options & AVAudioSessionInterruptionOptionShouldResume) {
        [self reconcile];
    }
}

#pragma mark - Playback

- (void)reconcile {
    if (self.videoPlayer) {
        // The background video's soundtrack is the music; the track player stays idle.
        BOOL audible = self.enabled && self.appInForeground && !self.gameRunning;
        [self dropLoadedPlayer];
        self.videoPlayer.muted = !audible;
        if (audible) [self activateAudioSession];
    } else {
        [self reconcileTrack];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:BackgroundMusicDidChangeNotification object:self];
}

- (void)reconcileTrack {
    NSURL *trackURL = [self currentTrackURL];
    if (!self.enabled || trackURL == nil) {
        [self.player stop];
        self.player = nil;
        self.playerURL = nil;
    } else if (!self.appInForeground || self.gameRunning) {
        [self.player pause];
    } else {
        if (self.player == nil || ![self.playerURL isEqual:trackURL]) {
            [self loadTrack:trackURL];
        }
        if (self.player && !self.player.isPlaying) {
            [self activateAudioSession];
            [self.player play];
        }
    }
}

- (void)loadTrack:(NSURL *)url {
    [self.player stop];
    self.player = nil;
    self.playerURL = nil;

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!player) {
        NSLog(@"[BackgroundMusic] could not load %@: %@", url.lastPathComponent, error);
        return;
    }
    player.numberOfLoops = -1;
    player.volume = kBGMVolume;
    [player prepareToPlay];
    self.player = player;
    self.playerURL = url;
}

- (void)activateAudioSession {
    // Ambient respects the silent switch and mixes with audio from other apps.
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryAmbient
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (error) NSLog(@"[BackgroundMusic] category error: %@", error);
    error = nil;
    [session setActive:YES error:&error];
    if (error) NSLog(@"[BackgroundMusic] activate error: %@", error);
}

#pragma mark - Tracks

- (NSURL *)customTrackURL {
    id stored = getPrefObject(kBGMCustomFilePref);
    NSString *name = [stored isKindOfClass:NSString.class] ? stored : nil;
    if (name.length == 0) return nil;
    NSURL *url = [BGMCustomDirectory() URLByAppendingPathComponent:name];
    return [NSFileManager.defaultManager fileExistsAtPath:url.path] ? url : nil;
}

- (NSURL *)bundledTrackURL {
    for (NSString *ext in BGMSupportedExtensions()) {
        NSString *path = [NSBundle.mainBundle pathForResource:kBGMBundledBaseName ofType:ext];
        if (path) return [NSURL fileURLWithPath:path];
    }
    return nil;
}

- (NSURL *)currentTrackURL {
    return [self customTrackURL] ?: [self bundledTrackURL];
}

- (BOOL)importTrackFromURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error {
    NSString *ext = url.pathExtension.lowercaseString;
    if (![BGMSupportedExtensions() containsObject:ext]) {
        if (error) {
            *error = [NSError errorWithDomain:@"BackgroundMusic" code:1 userInfo:@{
                NSLocalizedDescriptionKey: localize(@"music.error.unsupported", nil)
            }];
        }
        return NO;
    }

    // Files from the document picker are security-scoped; reading needs an open scope.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = BGMCustomDirectory();
    NSURL *dest = [dir URLByAppendingPathComponent:url.lastPathComponent];
    NSError *copyError = nil;

    [fm removeItemAtURL:dir error:nil];
    BOOL ok = [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&copyError]
           && [fm copyItemAtURL:url toURL:dest error:&copyError];

    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!ok) {
        if (error) *error = copyError;
        return NO;
    }
    setPrefObject(kBGMCustomFilePref, url.lastPathComponent);
    [self dropLoadedPlayer];
    [self reconcile];
    return YES;
}

- (void)restoreDefaultTrack {
    [NSFileManager.defaultManager removeItemAtURL:BGMCustomDirectory() error:nil];
    setPrefObject(kBGMCustomFilePref, @"");
    [self dropLoadedPlayer];
    [self reconcile];
}

// A replaced file can keep the same name, so the URL check in reconcile
// would not notice the change. Force a fresh load on the next reconcile.
- (void)dropLoadedPlayer {
    [self.player stop];
    self.player = nil;
    self.playerURL = nil;
}

@end
