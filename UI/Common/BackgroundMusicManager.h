#import <Foundation/Foundation.h>

@class AVPlayer;

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread whenever playback state, the toggle or the track changes.
extern NSNotificationName const BackgroundMusicDidChangeNotification;

/// Looping background music for the launcher UI.
///
/// Source, in priority order:
///   1. The soundtrack of the launcher's background video, when one is set.
///   2. The file the user imported in Settings → Background music.
///   3. The bundled `WitchBGM.<ext>`, if the build ships one.
/// Playback pauses while a game is running and while the app is in the
/// background, and resumes afterwards. The toggle is off by default.
@interface BackgroundMusicManager : NSObject

+ (instancetype)shared;

/// User toggle, persisted in preferences.
@property (nonatomic, readonly) BOOL enabled;
/// True while audio is actually playing.
@property (nonatomic, readonly) BOOL isPlaying;
/// True when there is a source to play (background video, imported or bundled track).
@property (nonatomic, readonly) BOOL hasTrack;
/// True when the background video's soundtrack is the source.
@property (nonatomic, readonly) BOOL usingVideoAudio;
/// True when the active track is the user's imported file.
@property (nonatomic, readonly) BOOL usingCustomTrack;
/// File name of the active track, or nil when there is none.
@property (nonatomic, readonly, nullable) NSString *trackName;

- (void)setEnabled:(BOOL)enabled;

/// Hands over the background video's player so its sound can be used as the
/// music. Pass nil when the video is removed. The manager mutes and unmutes it.
- (void)setVideoPlayer:(nullable AVPlayer *)player;

/// Called by the game surface. Music stays paused while a game runs.
- (void)setGameRunning:(BOOL)running;

/// Copies a user-picked audio file into the app and makes it the active track.
- (BOOL)importTrackFromURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

/// Drops the imported track and returns to the bundled one (or none).
- (void)restoreDefaultTrack;

@end

NS_ASSUME_NONNULL_END
