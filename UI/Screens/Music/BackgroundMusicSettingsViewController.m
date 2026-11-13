#import "BackgroundMusicSettingsViewController.h"

#import "AmethystBlurView.h"
#import "BackgroundMusicManager.h"
#import "ThemeManager.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, BGMSettingsSection) {
    BGMSettingsSectionToggle = 0,
    BGMSettingsSectionTrack,
    BGMSettingsSectionCount,
};

typedef NS_ENUM(NSInteger, BGMTrackRow) {
    BGMTrackRowChoose = 0,
    BGMTrackRowReset,
    BGMTrackRowCount,
};

@interface BackgroundMusicSettingsViewController () <UITableViewDelegate, UITableViewDataSource, UIDocumentPickerDelegate>
@property (nonatomic) UITableView *tableView;
@end

@implementation BackgroundMusicSettingsViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = localize(@"music.title", nil);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ThemeManager.shared.contentBackgroundColor;
    [AmethystBlurView installInView:self.view];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.backgroundColor = UIColor.clearColor;
    [self.view addSubview:_tableView];
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadRows) name:BackgroundMusicDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applyTheme) name:ThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRows];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)applyTheme {
    self.view.backgroundColor = ThemeManager.shared.contentBackgroundColor;
    [_tableView reloadData];
}

- (void)reloadRows {
    [_tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return BGMSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == BGMSettingsSectionToggle) return 1;
    // The reset row only means something once the user has imported a file.
    return BackgroundMusicManager.shared.usingCustomTrack ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == BGMSettingsSectionTrack) return localize(@"music.footer", nil);
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ThemeManager *theme = ThemeManager.shared;
    BackgroundMusicManager *music = BackgroundMusicManager.shared;

    if (indexPath.section == BGMSettingsSectionToggle) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = localize(@"music.enabled", nil);
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.textLabel.textColor = theme.primaryTextColor;
        cell.backgroundColor = theme.cardBackgroundColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = music.enabled;
        toggle.onTintColor = theme.accentColor;
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }

    if (indexPath.row == BGMTrackRowChoose) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.textLabel.text = localize(@"music.choose_track", nil);
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.textLabel.textColor = theme.primaryTextColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.textColor = theme.secondaryTextColor;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        if (music.usingVideoAudio) {
            cell.detailTextLabel.text = localize(@"music.track_video", nil);
        } else if (music.usingCustomTrack) {
            cell.detailTextLabel.text = music.trackName;
        } else if (music.hasTrack) {
            cell.detailTextLabel.text = localize(@"music.track_default", nil);
        } else {
            cell.detailTextLabel.text = localize(@"music.track_none", nil);
        }
        cell.backgroundColor = theme.cardBackgroundColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = localize(@"music.reset_track", nil);
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.textColor = theme.accentColor;
    cell.backgroundColor = theme.cardBackgroundColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != BGMSettingsSectionTrack) return;
    if (indexPath.row == BGMTrackRowChoose) {
        [self presentTrackPicker];
    } else if (indexPath.row == BGMTrackRowReset) {
        [BackgroundMusicManager.shared restoreDefaultTrack];
    }
}

#pragma mark - Actions

- (void)toggleChanged:(UISwitch *)sender {
    [BackgroundMusicManager.shared setEnabled:sender.on];
    if (sender.on && !BackgroundMusicManager.shared.hasTrack) {
        showDialog(localize(@"music.title", nil), localize(@"music.none_hint", nil));
    }
}

- (void)presentTrackPicker {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSError *error = nil;
    if (![BackgroundMusicManager.shared importTrackFromURL:url error:&error]) {
        showDialog(localize(@"music.title", nil), error.localizedDescription ?: localize(@"music.error.import", nil));
    }
}

@end
