#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Music for the wait while a version boots.
///
/// It starts when the launch begins and fades out when the game draws its first frame (the same moment the
/// startup splash leaves), so it never runs into the game's own audio. It does not need the splash screen to
/// be switched on. The tracks are the audio files in Documents/LaunchMusic: pick them in Settings ->
/// Appearance, or drop them in that folder from the Files app. With several tracks one is chosen at random
/// each launch. If the folder is empty, `launch_music.<ext>` inside the app bundle is used when present.
///
/// While a version boots the music uses the audio session the game has already set up, so it behaves like the
/// game's own sound. The preview in Settings borrows a mixing session instead and puts it back afterwards.
@interface WitchLaunchMusic : NSObject

/// The "play music on the startup splash" switch (appearance.launch_music).
+ (BOOL)enabled;

/// Documents/LaunchMusic (created on demand).
+ (NSString *)directoryPath;

/// Every playable track the user has added.
+ (NSArray<NSString *> *)userTrackPaths;

/// YES when the switch is on and there is a track to play.
+ (BOOL)canPlay;

/// Short description for Settings: "None", the file name, or "N tracks".
+ (NSString *)statusText;

/// Starts looping a track when the switch is on and a track exists. Does nothing if already playing.
+ (void)start;

/// Stops the music, fading it out over a fraction of a second when `fade` is YES.
+ (void)stopWithFade:(BOOL)fade;

/// Plays the music for a few seconds (or stops it if it is already playing) so it can be tested in Settings.
/// Returns NO when there is nothing to play.
+ (BOOL)togglePreview;

/// Lets the user pick audio files from the Files app and copies them into the music folder.
/// `completion` runs on the main queue with the number of tracks that were added.
+ (void)presentPickerFromViewController:(UIViewController *)presenter
                             completion:(void (^_Nullable)(NSUInteger added))completion;

/// Deletes every track the user added.
+ (void)removeAllTracks;

@end

NS_ASSUME_NONNULL_END
