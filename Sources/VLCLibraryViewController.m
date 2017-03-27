/*****************************************************************************
 * VLCLibraryViewController.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013-2016 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *          Gleb Pinigin <gpinigin # gmail.com>
 *          Tamas Timar <ttimar.vlc # gmail.com>
 *          Carola Nitz <nitz.carola # gmail.com>
 *          Tobias Conradi <videolan # tobias-conradi.de>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCLibraryViewController.h"
#import "VLCMovieViewController.h"
#import "VLCPlaylistTableViewCell.h"
#import "VLCPlaylistCollectionViewCell.h"
#import "NSString+SupportedMedia.h"
#import "VLCBugreporter.h"
#import "VLCAppDelegate.h"
#import "VLCFirstStepsViewController.h"
#import "VLCFolderCollectionViewFlowLayout.h"
#import "LXReorderableCollectionViewFlowLayout.h"
#import "VLCOpenInActivity.h"
#import "VLCNavigationController.h"
#import "VLCPlaybackController+MediaLibrary.h"
#import "VLCKeychainCoordinator.h"

#import <AssetsLibrary/AssetsLibrary.h>
#import <CoreSpotlight/CoreSpotlight.h>

/* prefs keys */
static NSString *kDisplayedFirstSteps = @"Did we display the first steps tutorial?";
static NSString *kUsingTableViewToShowData = @"UsingTableViewToShowData";
@implementation EmptyLibraryView

- (IBAction)learnMore:(id)sender
{
    UIViewController *firstStepsVC = [[VLCFirstStepsViewController alloc] initWithNibName:nil bundle:nil];
    UINavigationController *navCon = [[VLCNavigationController alloc] initWithRootViewController:firstStepsVC];
    navCon.modalPresentationStyle = UIModalPresentationFormSheet;
    [self.window.rootViewController presentViewController:navCon animated:YES completion:nil];
}

@end

@interface VLCLibraryViewController () <VLCFolderCollectionViewDelegateFlowLayout, LXReorderableCollectionViewDataSource, LXReorderableCollectionViewDelegateFlowLayout, UITableViewDataSource, UITableViewDelegate, MLMediaLibrary, VLCMediaListDelegate, UISearchBarDelegate, UISearchDisplayDelegate> {
    NSMutableArray *_foundMedia;
    VLCLibraryMode _libraryMode;
    VLCLibraryMode _previousLibraryMode;
    UIBarButtonItem *_menuButton;
    NSMutableArray *_indexPaths;
    id _folderObject;
    VLCFolderCollectionViewFlowLayout *_folderLayout;
    LXReorderableCollectionViewFlowLayout *_reorderLayout;
    BOOL _inFolder;
    BOOL _isSelected;
    BOOL _deleteFromTableView;
    UILongPressGestureRecognizer *_longPressGestureRecognizer;

    NSMutableArray *_searchData;
    UISearchBar *_searchBar;
    UISearchDisplayController *_searchDisplayController;

    UIBarButtonItem *_selectAllBarButtonItem;
    UIBarButtonItem *_createFolderBarButtonItem;
    UIBarButtonItem *_openInActivityBarButtonItem;
    UIBarButtonItem *_removeFromFolderBarButtonItem;
    UIBarButtonItem *_deleteSelectedBarButtonItem;
    VLCOpenInActivity *_openInActivity;
}

@property (nonatomic, strong) UIBarButtonItem *displayModeBarButtonItem;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) EmptyLibraryView *emptyLibraryView;
@property (nonatomic) BOOL usingTableViewToShowData;

@end

@implementation VLCLibraryViewController

- (void)dealloc
{
}

+ (void)initialize
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:@{kDisplayedFirstSteps : [NSNumber numberWithBool:NO]}];
    [defaults registerDefaults:@{kUsingTableViewToShowData : [NSNumber numberWithBool:UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone]}];
}

- (void)loadView
{
    [self setupContentViewWithContentInset:NO];
    [self setViewFromDeviceOrientation];
    [self updateViewsForCurrentDisplayMode];
    _libraryMode = VLCLibraryModeAllFiles;

    self.emptyLibraryView = [[[NSBundle mainBundle] loadNibNamed:@"VLCEmptyLibraryView" owner:self options:nil] lastObject];
    _emptyLibraryView.emptyLibraryLongDescriptionLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _emptyLibraryView.emptyLibraryLongDescriptionLabel.numberOfLines = 0;
}

- (void)setupContentViewWithContentInset:(BOOL)setInset
{
    CGRect viewDimensions = [UIApplication sharedApplication].keyWindow.bounds;
    UIView *contentView = [[UIView alloc] initWithFrame:viewDimensions];
    contentView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    contentView.backgroundColor = [UIColor VLCDarkBackgroundColor];

    if (self.usingTableViewToShowData) {
        if(!_tableView) {
            _tableView = [[UITableView alloc] initWithFrame:viewDimensions style:UITableViewStylePlain];
            _tableView.backgroundColor = [UIColor VLCDarkBackgroundColor];
            CGRect frame = _tableView.bounds;
            frame.origin.y = -frame.size.height;
            UIView *topView = [[UIView alloc] initWithFrame:frame];
            topView.backgroundColor = [UIColor VLCDarkBackgroundColor];
            [_tableView addSubview:topView];
            _tableView.rowHeight = [VLCPlaylistTableViewCell heightOfCell];
            _tableView.separatorColor = [UIColor VLCDarkBackgroundColor];
            _tableView.delegate = self;
            _tableView.dataSource = self;
            _tableView.opaque = YES;
            _tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
            _tableView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
            _tableView.tableHeaderView = _searchBar;
            _tableView.tableFooterView = [UIView new];
        }
        _tableView.frame = contentView.bounds;
        [contentView addSubview:_tableView];
        [_tableView reloadData];
    } else {
        if (!_collectionView) {
            _folderLayout = [[VLCFolderCollectionViewFlowLayout alloc] init];
            _collectionView = [[UICollectionView alloc] initWithFrame:viewDimensions collectionViewLayout:_folderLayout];
            _collectionView.alwaysBounceVertical = YES;
            _collectionView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
            _collectionView.delegate = self;
            _collectionView.dataSource = self;
            _collectionView.opaque = YES;
            _collectionView.backgroundColor = [UIColor VLCDarkBackgroundColor];
            _collectionView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
            _longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_collectionViewHandleLongPressGesture:)];
            [_collectionView addGestureRecognizer:_longPressGestureRecognizer];
            [_collectionView registerNib:[UINib nibWithNibName:@"VLCPlaylistCollectionViewCell" bundle:nil] forCellWithReuseIdentifier:@"PlaylistCell"];
        }
        _collectionView.frame = contentView.bounds;
        [contentView addSubview:_collectionView];
        [_collectionView reloadData];
    }
    self.view = contentView;
}

#pragma mark -

- (void)viewWillLayoutSubviews {
    UIScrollView *dataView = self.usingTableViewToShowData ? _tableView : _collectionView;

    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationNone];
    [dataView setContentInset:UIEdgeInsetsZero];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = NSLocalizedString(@"LIBRARY_ALL_FILES", nil);
    _menuButton = [UIBarButtonItem themedRevealMenuButtonWithTarget:self andSelector:@selector(leftButtonAction:)];
    self.navigationItem.leftBarButtonItem = _menuButton;

    self.editButtonItem.title = NSLocalizedString(@"BUTTON_EDIT", nil);
    self.editButtonItem.tintColor = [UIColor whiteColor];

    _selectAllBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"BUTTON_ALL", nil) style:UIBarButtonItemStylePlain target:self action:@selector(handleSelection)];
    _selectAllBarButtonItem.tintColor = [UIColor whiteColor];
    UIFont *font = [UIFont boldSystemFontOfSize:17];
    NSDictionary *attributes = @{NSFontAttributeName: font};
    [_selectAllBarButtonItem setTitleTextAttributes:attributes forState:UIControlStateNormal];

    _emptyLibraryView.emptyLibraryLabel.text = NSLocalizedString(@"EMPTY_LIBRARY", nil);
    _emptyLibraryView.emptyLibraryLongDescriptionLabel.text = NSLocalizedString(@"EMPTY_LIBRARY_LONG", nil);
    [_emptyLibraryView.emptyLibraryLongDescriptionLabel sizeToFit];
    [_emptyLibraryView.learnMoreButton setTitle:NSLocalizedString(@"BUTTON_LEARN_MORE", nil) forState:UIControlStateNormal];
    _createFolderBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemOrganize target:self action:@selector(createFolder)];

    // Better visual alignment with the action button
    _createFolderBarButtonItem.imageInsets = UIEdgeInsetsMake(4, 0, -4, 0);
    _createFolderBarButtonItem.landscapeImagePhoneInsets = UIEdgeInsetsMake(3, 0, -3, 0);

    _removeFromFolderBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemReply target:self action:@selector(removeFromFolder)];
    _removeFromFolderBarButtonItem.imageInsets = UIEdgeInsetsMake(4, 0, -4, 0);
    _removeFromFolderBarButtonItem.landscapeImagePhoneInsets = UIEdgeInsetsMake(3, 0, -3, 0);
    _removeFromFolderBarButtonItem.enabled = NO;

    _openInActivityBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(actOnSelection:)];
    _openInActivityBarButtonItem.enabled = NO;

    _deleteSelectedBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(deleteSelection:)];
    _deleteFromTableView = NO;

    UIBarButtonItem *fixedSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixedSpace.width = 20;
    UIBarButtonItem *secondFixedSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixedSpace.width = 20;

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        fixedSpace.width *= 2;
    }

    [self setToolbarItems:@[_openInActivityBarButtonItem,
                            fixedSpace,
                            _createFolderBarButtonItem,
                            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
                            [UIBarButtonItem themedDarkToolbarButtonWithTitle:NSLocalizedString(@"BUTTON_RENAME", nil) target:self andSelector:@selector(renameSelection)],
                            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
                            _removeFromFolderBarButtonItem,
                            secondFixedSpace,
                            _deleteSelectedBarButtonItem]];
    self.navigationController.toolbar.barStyle = UIBarStyleBlack;
    self.navigationController.toolbar.tintColor = [UIColor whiteColor];
    [UIApplication sharedApplication].statusBarStyle = UIStatusBarStyleLightContent;

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UINavigationBar *navBar = self.navigationController.navigationBar;
    _searchBar.barTintColor = navBar.barTintColor;
    // cancel button tint color of UISearchBar with white color
    [[UIBarButtonItem appearanceWhenContainedIn:[UISearchBar class], nil] setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[UIColor whiteColor], NSForegroundColorAttributeName, nil] forState:UIControlStateNormal];
    _searchBar.tintColor = navBar.tintColor;
    _searchBar.translucent = navBar.translucent;
    _searchBar.opaque = navBar.opaque;
    _searchDisplayController = [[UISearchDisplayController alloc] initWithSearchBar:_searchBar contentsController:self];
    _searchDisplayController.delegate = self;
    _searchDisplayController.searchResultsDataSource = self;
    _searchDisplayController.searchResultsDelegate = self;
    _searchDisplayController.searchResultsTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _searchDisplayController.searchResultsTableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _searchBar.delegate = self;

    [self setSearchBar:YES resetContent:YES];
    self.edgesForExtendedLayout = UIRectEdgeNone;

    @synchronized (self) {
        _searchData = [[NSMutableArray alloc] init];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self _displayEmptyLibraryViewIfNeeded];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![[defaults objectForKey:kDisplayedFirstSteps] boolValue]) {
        [self.emptyLibraryView performSelector:@selector(learnMore:) withObject:nil afterDelay:1.];
        [defaults setObject:[NSNumber numberWithBool:YES] forKey:kDisplayedFirstSteps];
        [defaults synchronize];
    }

    if (_foundMedia.count < 1)
        [self updateViewContents];
    [[MLMediaLibrary sharedMediaLibrary] performSelector:@selector(libraryDidAppear) withObject:nil afterDelay:1.];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [[MLMediaLibrary sharedMediaLibrary] libraryDidDisappear];
}

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake)
        [[VLCBugreporter sharedInstance] handleBugreportRequest];
}

- (void)openMediaObject:(NSManagedObject *)mediaObject
{
    if ([mediaObject isKindOfClass:[MLAlbum class]] || [mediaObject isKindOfClass:[MLShow class]]) {

        BOOL isAlbum = [mediaObject isKindOfClass:[MLAlbum class]];
        NSArray* array =  isAlbum ? [(MLAlbum *)mediaObject sortedTracks] : [(MLShow *)mediaObject sortedEpisodes];
        @synchronized(_foundMedia) {
            _foundMedia = [NSMutableArray arrayWithArray:array];
        }
        self.navigationItem.leftBarButtonItem = [UIBarButtonItem themedBackButtonWithTarget:self andSelector:@selector(backToAllItems:)];
        if (_libraryMode == VLCLibraryModeAllFiles)
            self.navigationItem.leftBarButtonItem.title = NSLocalizedString(@"BUTTON_BACK", nil);
        else
            [self.navigationItem.leftBarButtonItem setTitle: isAlbum ? NSLocalizedString(@"LIBRARY_MUSIC", nil) : NSLocalizedString(@"LIBRARY_SERIES", nil)];
        self.title = [(MLAlbum*)mediaObject name];
        [self reloadViews];
    } else if ([mediaObject isKindOfClass:[MLLabel class]]) {
        MLLabel *folder = (MLLabel*) mediaObject;
        _inFolder = YES;
        if (!self.usingTableViewToShowData) {
            if (![self.collectionView.collectionViewLayout isEqual:_reorderLayout]) {
                for (UIGestureRecognizer *recognizer in _collectionView.gestureRecognizers) {
                    if (recognizer == _folderLayout.panGestureRecognizer || recognizer == _folderLayout.longPressGestureRecognizer || recognizer == _longPressGestureRecognizer)
                        [self.collectionView removeGestureRecognizer:recognizer];
                }
                _reorderLayout = [[LXReorderableCollectionViewFlowLayout alloc] init];
                [self.collectionView setCollectionViewLayout:_reorderLayout animated:NO];
            }
        }
        _libraryMode = VLCLibraryModeFolder;
        @synchronized(_foundMedia) {
            _foundMedia = [NSMutableArray arrayWithArray:[folder sortedFolderItems]];
        }
        self.navigationItem.leftBarButtonItem = [UIBarButtonItem themedBackButtonWithTarget:self andSelector:@selector(backToAllItems:)];
        self.navigationItem.leftBarButtonItem.title = NSLocalizedString(@"BUTTON_BACK", nil);
        self.title = [folder name];

        _removeFromFolderBarButtonItem.enabled = YES;
        _createFolderBarButtonItem.enabled = NO;

        [self reloadViews];
        return;
    } else {
        VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
        [vpc playMediaLibraryObject:mediaObject];

        [self createSpotlightItem:mediaObject];
    }
}

- (void)createSpotlightItem:(nonnull NSManagedObject *)mediaObject
{
    if ([CSSearchableItemAttributeSet class] != nil && ![[VLCKeychainCoordinator defaultCoordinator] passcodeLockEnabled]) {
        self.userActivity = [[NSUserActivity alloc] initWithActivityType:kVLCUserActivityPlaying];

        MLFile *file = nil;
        if ([mediaObject isKindOfClass:[MLAlbumTrack class]]) {
            file = [(MLAlbumTrack *)mediaObject anyFileFromTrack];
        } else if ([mediaObject isKindOfClass:[MLShowEpisode class]]) {
            file = [(MLShowEpisode *)mediaObject anyFileFromEpisode];
        } else if ([mediaObject isKindOfClass:[MLFile class]]){
            file = (MLFile *)mediaObject;
        }
        self.userActivity.title = file.title;
        self.userActivity.contentAttributeSet = file.coreSpotlightAttributeSet;
        self.userActivity.userInfo = @{@"playingmedia":mediaObject.objectID.URIRepresentation};

        self.userActivity.eligibleForSearch = YES;
        self.userActivity.eligibleForHandoff = YES;
        //self.userActivity.contentUserAction = NSUserActivityContentUserActionPlay;
        [self.userActivity becomeCurrent];
    }
}

- (void)removeMediaObject:(id)managedObject updateDatabase:(BOOL)updateDB
{
        // delete all tracks from an album
    if ([managedObject isKindOfClass:[MLAlbum class]]) {
        MLAlbum *album = managedObject;
        NSSet *iterAlbumTrack = [NSSet setWithSet:album.tracks];

        for (MLAlbumTrack *track in iterAlbumTrack) {
            NSSet *iterFiles = [NSSet setWithSet:track.files];

            for (MLFile *file in iterFiles)
                [self _deleteMediaObject:file];
        }
        [[MLMediaLibrary sharedMediaLibrary] removeObject: album];
        // delete all episodes from a show
    } else if ([managedObject isKindOfClass:[MLShow class]]) {
        MLShow *show = managedObject;
        NSSet *iterShowEpisodes = [NSSet setWithSet:show.episodes];

        for (MLShowEpisode *episode in iterShowEpisodes) {
            NSSet *iterFiles = [NSSet setWithSet:episode.files];

            for (MLFile *file in iterFiles)
                [self _deleteMediaObject:file];
        }
        [[MLMediaLibrary sharedMediaLibrary] removeObject: show];
        // delete all files from an episode
    } else if ([managedObject isKindOfClass:[MLShowEpisode class]]) {
        MLShowEpisode *episode = managedObject;
        NSSet *iterFiles = [NSSet setWithSet:episode.files];

        for (MLFile *file in iterFiles)
            [self _deleteMediaObject:file];
        // delete all files from a track
        [[MLMediaLibrary sharedMediaLibrary] removeObject: episode];
    } else if ([managedObject isKindOfClass:[MLAlbumTrack class]]) {
        MLAlbumTrack *track = managedObject;
        NSSet *iterFiles = [NSSet setWithSet:track.files];

        for (MLFile *file in iterFiles)
            [self _deleteMediaObject:file];
    } else if ([managedObject isKindOfClass:[MLLabel class]]) {
        MLLabel *folder = managedObject;
        NSSet *iterFiles = [NSSet setWithSet:folder.files];
        [folder removeFiles:folder.files];
        for (MLFile *file in iterFiles)
            [self _deleteMediaObject:file];
        [[MLMediaLibrary sharedMediaLibrary] removeObject:folder];
    }
    else
        [self _deleteMediaObject:managedObject];

    if (updateDB) {
        [[MLMediaLibrary sharedMediaLibrary] updateMediaDatabase];
        [self updateViewContents];
    }
}

- (void)_deleteMediaObject:(MLFile *)mediaObject
{
    if (_inFolder)
        [self rearrangeFolderTrackNumbersForRemovedItem:mediaObject];

    /* stop playback if needed */
    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    if (vpc.isPlaying) {
        MLFile *currentlyPlayingFile = [[MLFile fileForURL:vpc.mediaPlayer.media.url] firstObject];
        if (currentlyPlayingFile) {
            if (currentlyPlayingFile == mediaObject)
                [vpc stopPlayback];
        }
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *folderLocation = [[mediaObject.url path] stringByDeletingLastPathComponent];
    NSArray *allfiles = [fileManager contentsOfDirectoryAtPath:folderLocation error:nil];
    NSString *fileName = [mediaObject.path.lastPathComponent stringByDeletingPathExtension];
    if (!fileName)
        return;
    NSIndexSet *indexSet = [allfiles indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
       return ([obj rangeOfString:fileName].location != NSNotFound);
    }];
    NSUInteger count = indexSet.count;
    NSString *additionalFilePath;
    NSUInteger currentIndex = [indexSet firstIndex];
    for (unsigned int x = 0; x < count; x++) {
        additionalFilePath = allfiles[currentIndex];
        if ([additionalFilePath isSupportedSubtitleFormat])
            [fileManager removeItemAtPath:[folderLocation stringByAppendingPathComponent:additionalFilePath] error:nil];
        currentIndex = [indexSet indexGreaterThanIndex:currentIndex];
    }
    [fileManager removeItemAtURL:mediaObject.url error:nil];
}

- (void)_displayEmptyLibraryViewIfNeeded
{
    if (self.emptyLibraryView.superview)
        [self.emptyLibraryView removeFromSuperview];

    if (_foundMedia.count == 0) {
        _inFolder = (_libraryMode == VLCLibraryModeFolder || _libraryMode == VLCLibraryModeCreateFolder);
        self.emptyLibraryView.emptyLibraryLabel.text = _inFolder ? NSLocalizedString(@"FOLDER_EMPTY", nil) : NSLocalizedString(@"EMPTY_LIBRARY", nil);
        self.emptyLibraryView.emptyLibraryLongDescriptionLabel.text = _inFolder ? NSLocalizedString(@"FOLDER_EMPTY_LONG", nil) : NSLocalizedString(@"EMPTY_LIBRARY_LONG", nil);
        self.emptyLibraryView.learnMoreButton.hidden = _inFolder;
        self.emptyLibraryView.frame = self.view.bounds;
        [self.view addSubview:self.emptyLibraryView];
        self.navigationItem.rightBarButtonItems = nil;
    } else {
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            UIBarButtonItem *toggleDisplayedView = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"tableViewIcon"] style:UIBarButtonItemStylePlain target:self action:@selector(toggleDisplayedView:)];
            self.navigationItem.rightBarButtonItems = @[toggleDisplayedView, self.editButtonItem];
            self.displayModeBarButtonItem = toggleDisplayedView;
        } else {
            self.navigationItem.rightBarButtonItem = self.editButtonItem;
        }
    }
    if (self.usingTableViewToShowData)
        _tableView.separatorStyle = (_foundMedia.count > 0)? UITableViewCellSeparatorStyleSingleLine:
                                                             UITableViewCellSeparatorStyleNone;
    else
        [self.collectionView.collectionViewLayout invalidateLayout];

    [self updateViewsForCurrentDisplayMode];
}

- (void)setViewFromDeviceOrientation
{
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        UIDevice *currentDevice = [UIDevice currentDevice];
        BOOL isPortrait = UIDeviceOrientationIsPortrait(currentDevice.orientation);

        [self setUsingTableViewToShowData:isPortrait];
    }
}

- (void)setSearchBar:(BOOL)enable resetContent:(BOOL)resetContent
{
    if (enable)
        self.tableView.tableHeaderView = _searchBar;
    else
        self.tableView.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, self.tableView.bounds.size.width, CGFLOAT_MIN)];
    if (resetContent) {
        CGPoint contentOffset = self.tableView.contentOffset;
        contentOffset.y += CGRectGetHeight(self.tableView.tableHeaderView.frame);
        self.tableView.contentOffset = contentOffset;
    }
}

- (void)libraryUpgradeComplete
{
    self.title = NSLocalizedString(@"LIBRARY_ALL_FILES", nil);
    self.navigationItem.leftBarButtonItem = _menuButton;
    self.emptyLibraryView.emptyLibraryLongDescriptionLabel.hidden = NO;
    self.emptyLibraryView.emptyLibraryLabel.text = NSLocalizedString(@"EMPTY_LIBRARY", nil);
    [self.emptyLibraryView.activityIndicator stopAnimating];
    [self.emptyLibraryView removeFromSuperview];

    [self updateViewContents];
}

- (void)updateViewContents
{
    @synchronized(self) {
        _foundMedia = [[NSMutableArray alloc] init];
    }

    if (![(VLCAppDelegate *)[UIApplication sharedApplication].delegate passcodeValidated]) {
        APLog(@"library is locked, won't show contents");
        return;
    }

    self.navigationItem.leftBarButtonItem = _menuButton;

    if (_libraryMode == VLCLibraryModeAllAlbums)
        self.title = NSLocalizedString(@"LIBRARY_MUSIC", nil);
    else if( _libraryMode == VLCLibraryModeAllSeries)
        self.title = NSLocalizedString(@"LIBRARY_SERIES", nil);
    else
        self.title = NSLocalizedString(@"LIBRARY_ALL_FILES", nil);

    _createFolderBarButtonItem.enabled = (_libraryMode == VLCLibraryModeAllAlbums || _libraryMode == VLCLibraryModeAllSeries) ? NO : YES;
    _removeFromFolderBarButtonItem.enabled = NO;

    /* add all albums */
    if (_libraryMode != VLCLibraryModeAllSeries) {
        NSArray *rawAlbums = [MLAlbum allAlbums];
        for (MLAlbum *album in rawAlbums) {
            if (_libraryMode != VLCLibraryModeAllAlbums) {
                if (album.name.length > 0 && album.tracks.count > 1) {
                    @synchronized(_foundMedia) {
                        [_foundMedia addObject:album];
                    }
                }
            } else {
                if (album.name.length > 0) {
                    @synchronized(_foundMedia) {
                        [_foundMedia addObject:album];
                    }
                }
            }
        }
    }
    if (_libraryMode == VLCLibraryModeAllAlbums) {
        [self reloadViews];
        return;
    }

    /* add all shows */
    NSArray *rawShows = [MLShow allShows];
    for (MLShow *show in rawShows) {
        if (show.name.length > 0 && show.episodes.count > 1) {
            @synchronized(_foundMedia) {
                [_foundMedia addObject:show];
            }
        }
    }
    if (_libraryMode == VLCLibraryModeAllSeries) {
        [self reloadViews];
        return;
    }

    /* add all folders*/
    NSArray *allFolders = [MLLabel allLabels];
    for (MLLabel *folder in allFolders) {
        @synchronized(_foundMedia) {
            [_foundMedia addObject:folder];
        }
    }

    /* add all remaining files */
    NSArray *allFiles = [MLFile allFiles];
    for (MLFile *file in allFiles) {
        if (file.labels != nil) {
            @synchronized(file.labels) {
                if (file.labels.count > 0)
                    continue;
            }
        }

        if (!file.isShowEpisode && !file.isAlbumTrack) {
            @synchronized(_foundMedia) {
                [_foundMedia addObject:file];
            }
        }
        else if (file.isShowEpisode) {
            if (file.showEpisode.show.episodes.count < 2) {
                @synchronized(_foundMedia) {
                    [_foundMedia addObject:file];
                }
            }

            /* older MediaLibraryKit versions don't send a show name in a popular
             * corner case. hence, we need to work-around here and force a reload
             * afterwards as this could lead to the 'all my shows are gone' 
             * syndrome (see #10435, #10464, #10432 et al) */
            if (file.showEpisode.show.name.length == 0) {
                file.showEpisode.show.name = NSLocalizedString(@"UNTITLED_SHOW", nil);
                [self performSelector:@selector(updateViewContents) withObject:nil afterDelay:0.1];
            }
        } else if (file.isAlbumTrack) {
            if (file.albumTrack.album.tracks.count < 2) {
                @synchronized(_foundMedia) {
                    [_foundMedia addObject:file];
                }
            }
        }
    }

    [self reloadViews];
}

- (void)reloadViews
{
    // Since this gets can get called at any point and wipe away the selections, we update the actionBarButtonItem here because this can happen if you tap "Save Video" in the UIActivityController and a media access alert view takes away focus (the corresponding 'became active' notification of UIApplication will call this). Or simply try bringing down the notification center to trigger this. Any existing UIActivityViewController session should be safe as it would have copies of the selected file references.
    if (self.usingTableViewToShowData) {
        [self.tableView reloadData];
        [self updateActionBarButtonItemStateWithSelectedIndexPaths:[self.tableView indexPathsForSelectedRows]];
        _isSelected = NO;
    } else {
        [self.collectionView reloadData];
        [self updateActionBarButtonItemStateWithSelectedIndexPaths:[self.collectionView indexPathsForSelectedItems]];
        if (_libraryMode == VLCLibraryModeAllFiles) {
            if (self.collectionView.collectionViewLayout != _folderLayout) {
                for (UIGestureRecognizer *recognizer in _collectionView.gestureRecognizers) {
                    if (recognizer != _folderLayout.panGestureRecognizer ||
                        recognizer != _folderLayout.longPressGestureRecognizer ||
                        recognizer != _longPressGestureRecognizer)
                        [self.collectionView removeGestureRecognizer:recognizer];
                }

                [self.collectionView setCollectionViewLayout:_folderLayout animated:NO];
                [self.collectionView addGestureRecognizer:_longPressGestureRecognizer];
            }
        }
    }

    [self _displayEmptyLibraryViewIfNeeded];
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (tableView == self.searchDisplayController.searchResultsTableView)
        return _searchData.count;

    return _foundMedia.count;
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"PlaylistCell";

    VLCPlaylistTableViewCell *cell = (VLCPlaylistTableViewCell *)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil)
        cell = [VLCPlaylistTableViewCell cellWithReuseIdentifier:CellIdentifier];
    else
        [cell collapsWithAnimation:NO];

    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeRightOnTableViewCellGestureAction:)];
    [swipeRight setDirection:(UISwipeGestureRecognizerDirectionRight)];
    [cell addGestureRecognizer:swipeRight];

    NSInteger row = indexPath.row;

    if (tableView == self.searchDisplayController.searchResultsTableView) {
        @synchronized (_searchData) {
            if (row < _searchData.count)
                cell.mediaObject = _searchData[row];
        }
    } else {
        @synchronized (_foundMedia) {
            if (row < _foundMedia.count)
                cell.mediaObject = _foundMedia[row];
        }
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath
{
    @synchronized(_foundMedia) {
        MLFile* object = _foundMedia[fromIndexPath.item];
        [_foundMedia removeObjectAtIndex:fromIndexPath.item];
        [_foundMedia insertObject:object atIndex:toIndexPath.item];
        if (![object isKindOfClass:[MLFile class]])
            return;
        object.folderTrackNumber = @(toIndexPath.item - 1);
        object = [_foundMedia objectAtIndex:fromIndexPath.item];
        if (![object isKindOfClass:[MLFile class]])
            return;
        object.folderTrackNumber = @(fromIndexPath.item - 1);
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return _inFolder;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    cell.backgroundColor = (indexPath.row % 2 == 0)? [UIColor blackColor]: [UIColor VLCDarkBackgroundColor];
    cell.multipleSelectionBackgroundView.backgroundColor = cell.backgroundColor;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSInteger row = indexPath.row;
        _deleteFromTableView = YES;
        if (row < _foundMedia.count)
            [self deleteSelection:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (tableView.isEditing) {
        [self updateActionBarButtonItemStateWithSelectedIndexPaths:[tableView indexPathsForSelectedRows]];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([(VLCPlaylistTableViewCell *)[tableView cellForRowAtIndexPath:indexPath] isExpanded]) {
        [(VLCPlaylistTableViewCell *)[tableView cellForRowAtIndexPath:indexPath] collapsWithAnimation:YES];
        return;
    }

    NSArray *visibleCells = [tableView visibleCells];
    NSUInteger cellCount = visibleCells.count;
    for (NSUInteger x = 0; x < cellCount; x++) {
        if ([visibleCells[x] isExpanded])
            [visibleCells[x] collapsWithAnimation:NO];
    }

    if (tableView.isEditing) {
        if (_libraryMode == VLCLibraryModeCreateFolder) {
            _folderObject = _foundMedia[indexPath.row];
            _libraryMode = _previousLibraryMode;
            [self updateViewContents];
            [self createFolderWithName:nil];
        } else {
            [self updateActionBarButtonItemStateWithSelectedIndexPaths:[tableView indexPathsForSelectedRows]];
        }
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSManagedObject *selectedObject;

    NSUInteger row = indexPath.row;
    if (tableView == self.searchDisplayController.searchResultsTableView) {
        @synchronized (_searchData) {
            if (row < _searchData.count)
                selectedObject = _searchData[row];
        }
    } else {
        @synchronized (_foundMedia) {
            if (row < _foundMedia.count)
                selectedObject = _foundMedia[row];
        }
    }

    if (_searchDisplayController.active)
        [_searchDisplayController setActive:NO animated:NO];

    if (selectedObject != nil)
        [self openMediaObject:selectedObject];
}

#pragma mark - Gesture Action
- (void)swipeRightOnTableViewCellGestureAction:(UIGestureRecognizer *)recognizer
{
    if ([[self.editButtonItem title] isEqualToString:NSLocalizedString(@"BUTTON_CANCEL", nil)])
        [self setEditing:NO animated:YES];
    else {
        [self setEditing:YES animated:YES];

        NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[recognizer locationInView:self.tableView]];
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:path.row inSection:path.section]
                                animated:YES
                          scrollPosition:UITableViewScrollPositionNone];
        [self updateActionBarButtonItemStateWithSelectedIndexPaths:[self.tableView indexPathsForSelectedRows]];
    }
}

- (void)swipeRightOnCollectionViewCellGestureAction:(UIGestureRecognizer *)recognizer
{
    NSIndexPath *path = [self.collectionView indexPathForItemAtPoint:[recognizer locationInView:self.collectionView]];
    VLCPlaylistCollectionViewCell *cell = (VLCPlaylistCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:path];
    [cell showMetadata:!cell.showsMetaData];
}

#pragma mark - Collection View
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return _foundMedia.count;
}

- (UICollectionViewCell*)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    VLCPlaylistCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"PlaylistCell" forIndexPath:indexPath];
    @synchronized (_foundMedia) {
        NSUInteger row = indexPath.row;
        if (row < _foundMedia.count)
            cell.mediaObject = _foundMedia[row];
    }

    cell.collectionView = _collectionView;

    [cell setEditing:self.editing animated:NO];

    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeRightOnCollectionViewCellGestureAction:)];
    [swipeRight setDirection:(UISwipeGestureRecognizerDirectionRight)];
    [cell addGestureRecognizer:swipeRight];

    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    const CGFloat maxCellWidth = [UIScreen mainScreen].bounds.size.width / 3;
    const CGFloat aspectRatio = 9.0/16.0;

    CGRect windowFrame = [UIApplication sharedApplication].keyWindow.frame;
    CGFloat windowWidth = windowFrame.size.width;

    int numberOfCellsPerRow = ceil(windowWidth/maxCellWidth);
    CGFloat cellWidth = windowWidth/numberOfCellsPerRow;
    cellWidth -= 5;

    return CGSizeMake(cellWidth, cellWidth * aspectRatio);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout insetForSectionAtIndex:(NSInteger)section
{
    return UIEdgeInsetsMake(5, 5, 5, 5);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section
{
    return 2.5;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section
{
    return 0.;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.editing) {
        if (_libraryMode == VLCLibraryModeCreateFolder) {
            _folderObject = _foundMedia[indexPath.item];
            [self createFolderWithName:nil];
             _libraryMode = _previousLibraryMode;
        } else {
            [self updateActionBarButtonItemStateWithSelectedIndexPaths:[collectionView indexPathsForSelectedItems]];
        }
        [(VLCPlaylistCollectionViewCell *)[collectionView cellForItemAtIndexPath:indexPath] selectionUpdate];
        return;
    }

    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    NSArray *visibleCells = [[collectionView visibleCells] copy];
    NSUInteger cellCount = visibleCells.count;

    for (NSUInteger x = 0; x < cellCount; x++) {
        VLCPlaylistCollectionViewCell *cell = visibleCells[x];
        if ([cell showsMetaData])
            [cell showMetadata:NO];
    }

    NSManagedObject *selectedObject;
    NSInteger row = indexPath.row;
    @synchronized(_foundMedia) {
        if (row < _foundMedia.count)
            selectedObject = _foundMedia[row];
    }
    if (selectedObject != nil)
        [self openMediaObject:selectedObject];
}

- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.editing) {
        [self updateActionBarButtonItemStateWithSelectedIndexPaths:[collectionView indexPathsForSelectedItems]];
    }

    [(VLCPlaylistCollectionViewCell *)[collectionView cellForItemAtIndexPath:indexPath] selectionUpdate];
}

- (void)collectionView:(UICollectionView *)collectionView removeItemFromFolderAtIndexPathIfNeeded:(NSIndexPath *)indexPath
{
    id mediaObject;
    @synchronized(_foundMedia) {
        mediaObject = _foundMedia[indexPath.item];
    }
    if (![mediaObject isKindOfClass:[MLFile class]])
        return;

    MLFile *mediaFile = (MLFile *)mediaObject;
    [self rearrangeFolderTrackNumbersForRemovedItem:mediaFile];
    mediaFile.labels = nil;
    mediaFile.folderTrackNumber = nil;

    [self backToAllItems:nil];
}

- (void)collectionView:(UICollectionView *)collectionView itemAtIndexPath:(NSIndexPath *)fromIndexPath willMoveToIndexPath:(NSIndexPath *)toIndexPath
{
    @synchronized(_foundMedia) {
        id object = _foundMedia[fromIndexPath.item];
        if (![object isKindOfClass:[MLFile class]])
            return;
        [_foundMedia removeObjectAtIndex:fromIndexPath.item];
        [_foundMedia insertObject:object atIndex:toIndexPath.item];
        [(MLFile *)object setFolderTrackNumber: @(toIndexPath.item - 1)];
        object = _foundMedia[fromIndexPath.item];
        if (![object isKindOfClass:[MLFile class]])
            return;
        [(MLFile *)object setFolderTrackNumber: @(fromIndexPath.item - 1)];
    }
}

- (void)collectionView:(UICollectionView *)collectionView requestToMoveItemAtIndexPath:(NSIndexPath *)itemPath intoFolderAtIndexPath:(NSIndexPath *)folderPath
{
    id folderPathItem;
    id itemPathItem;
    @synchronized(_foundMedia) {
        folderPathItem = _foundMedia[folderPath.item];
        itemPathItem = _foundMedia[itemPath.item];
    }

    BOOL validFileTypeAtFolderPath = ([folderPathItem isKindOfClass:[MLFile class]] || [folderPathItem isKindOfClass:[MLLabel class]]) && [itemPathItem isKindOfClass:[MLFile class]];

    if (!validFileTypeAtFolderPath) {
        VLCAlertView *alert = [[VLCAlertView alloc] initWithTitle:NSLocalizedString(@"FOLDER_INVALID_TYPE_TITLE", nil) message:NSLocalizedString(@"FOLDER_INVALID_TYPE_MESSAGE", nil) cancelButtonTitle:nil otherButtonTitles:@[NSLocalizedString(@"BUTTON_OK", nil)]];

        alert.completion = ^(BOOL cancelled, NSInteger buttonIndex) {
            [self updateViewContents];
        };
        [alert show];
        return;
    }

    BOOL isFolder = [folderPathItem isKindOfClass:[MLLabel class]];

    if (isFolder){
        MLLabel *folder = folderPathItem;
        MLFile *file = itemPathItem;
        [file setLabels:[[NSSet alloc] initWithObjects:folder, nil]];
        file.folderTrackNumber = @([folder.files count] - 1);
        @synchronized(_foundMedia) {
            [_foundMedia removeObjectAtIndex:itemPath.item];
        }
        [self updateViewContents];
    } else {
        _folderObject = folderPathItem;
        _indexPaths = [NSMutableArray arrayWithArray:@[itemPath]];
        [self showCreateFolderAlert];
    }
}

#pragma mark - collection/tableView helper
- (NSArray *)selectedIndexPaths
{
    NSArray *indexPaths;
    if (self.usingTableViewToShowData)
        indexPaths = [self.tableView indexPathsForSelectedRows];
    else
        indexPaths = [self.collectionView indexPathsForSelectedItems];

    return indexPaths ?: [NSArray array];
}
#pragma mark - Folder implementation

- (void)rearrangeFolderTrackNumbersForRemovedItem:(MLFile *) mediaObject
{
    MLLabel *label = [mediaObject.labels anyObject];
    NSSet *allFiles = label.files;
    for (MLFile *file in allFiles) {
        if (file.folderTrackNumber > mediaObject.folderTrackNumber) {
            int value = [file.folderTrackNumber intValue];
            file.folderTrackNumber = [NSNumber numberWithInt:value - 1];
        }
    }
}

- (void)showCreateFolderAlert
{
    VLCAlertView *alert = [[VLCAlertView alloc] initWithTitle:NSLocalizedString(@"FOLDER_CHOOSE_NAME_TITLE", nil) message:NSLocalizedString(@"FOLDER_CHOOSE_NAME_MESSAGE", nil) cancelButtonTitle:NSLocalizedString(@"BUTTON_CANCEL", nil) otherButtonTitles:@[NSLocalizedString(@"BUTTON_SAVE", nil)]];
    [alert setAlertViewStyle:UIAlertViewStylePlainTextInput];
    UITextField *zeroTextField = [alert textFieldAtIndex:0];
    [zeroTextField setText:NSLocalizedString(@"FOLDER_NAME_PLACEHOLDER", nil)];
    [zeroTextField setClearButtonMode:UITextFieldViewModeAlways];

    __weak VLCAlertView *weakAlert = alert;
    alert.completion = ^(BOOL cancelled, NSInteger buttonIndex) {
        if (cancelled)
            [self updateViewContents];
        else
            [self createFolderWithName:[weakAlert textFieldAtIndex:0].text];
    };
    [alert show];
}

- (void)createFolder
{
    if (_libraryMode == VLCLibraryModeCreateFolder) {
        _libraryMode = _previousLibraryMode;
        [self updateViewContents];
        [self showCreateFolderAlert];
        return;
    }

    _indexPaths = [NSMutableArray arrayWithArray:[self selectedIndexPaths]];

    for (NSInteger i = _indexPaths.count - 1; i >=0; i--) {
        NSIndexPath *path = _indexPaths[i];
        id mediaObject;
        @synchronized(_foundMedia) {
            mediaObject = _foundMedia[path.row];
        }
        if ([mediaObject isKindOfClass:[MLLabel class]])
            [_indexPaths removeObject:path];
    }

    if ([_indexPaths count] != 0) {
        NSArray *folder = [MLLabel allLabels];
        //if we already have folders display them
        if ([folder count] > 0) {
            @synchronized(self) {
                _foundMedia = [NSMutableArray arrayWithArray:folder];
            }
            self.title = NSLocalizedString(@"SELECT_FOLDER", nil);
            _previousLibraryMode = _libraryMode;
            _libraryMode = VLCLibraryModeCreateFolder;
            [self reloadViews];
            return;
        }
    }
    //no selected items or no existing folder ask for foldername
    [self showCreateFolderAlert];
}

- (void)removeFromFolder
{
    _indexPaths = [NSMutableArray arrayWithArray:[self selectedIndexPaths]];

    [_indexPaths sortUsingSelector:@selector(compare:)];

    for (NSInteger i = [_indexPaths count] - 1; i >= 0; i--) {
        NSIndexPath *path = _indexPaths[i];
        id item;
        @synchronized(_foundMedia) {
            item = _foundMedia[path.row];
        }

        if ([item isKindOfClass:[MLFile class]]) {
            MLFile *file = (MLFile *)item;
            [self rearrangeFolderTrackNumbersForRemovedItem:file];
            file.labels = nil;
            file.folderTrackNumber = nil;
        }
        @synchronized(_foundMedia) {
            [_foundMedia removeObject:item];
        }
    }
    [self reloadViews];
}

- (void)createFolderWithName:(NSString *)folderName
{
    NSArray *labels = [MLLabel allLabels];
    for (MLLabel *label in labels){
        if ([label.name isEqualToString:folderName]) {
            _folderObject = nil;
            _indexPaths = nil;
            VLCAlertView *alert = [[VLCAlertView alloc] initWithTitle:NSLocalizedString(@"FOLDER_NAME_DUPLICATE_TITLE", nil) message:NSLocalizedString(@"FOLDER_NAME_DUPLICATE_MESSAGE", nil) cancelButtonTitle:nil otherButtonTitles:@[NSLocalizedString(@"BUTTON_OK", nil)]];

            alert.completion = ^(BOOL cancelled, NSInteger buttonIndex) {
                [self updateViewContents];
            };
            [alert show];
            return;
        }
    }

    if (_folderObject != nil) {
        id mediaObject;
        NSUInteger folderIndex;
        @synchronized(_foundMedia) {
            folderIndex = [_foundMedia indexOfObject:_folderObject];
            mediaObject = _foundMedia[folderIndex];
        }

        //item got dragged onto item
        if ([mediaObject isKindOfClass:[MLFile class]]) {
            MLFile *file = (MLFile *)mediaObject;
            MLLabel *label = [[MLMediaLibrary sharedMediaLibrary] createObjectForEntity:@"Label"];
            label.name = folderName;

            file.labels = [NSSet setWithObjects:label,nil];
            NSNumber *folderTrackNumber = [NSNumber numberWithInt:(int)[label files].count - 1];
            file.folderTrackNumber = folderTrackNumber;

            id item;
            @synchronized(_foundMedia) {
                [_foundMedia removeObjectAtIndex:folderIndex];
                [_foundMedia insertObject:label atIndex:folderIndex];

                item = _foundMedia[((NSIndexPath *)_indexPaths[0]).item];
            }
            if (![item isKindOfClass:[MLFile class]])
                return;

            MLFile *itemFile = (MLFile *)item;
            itemFile.labels = file.labels;
            @synchronized(_foundMedia) {
                [_foundMedia removeObjectAtIndex:((NSIndexPath *)_indexPaths[0]).item];
            }
            itemFile.folderTrackNumber = @([label files].count - 1);
        } else {
            //item got dragged onto folder or items should be added to folder
            MLLabel *label;
            @synchronized(_foundMedia) {
                label = _foundMedia[folderIndex];
            }
            [_indexPaths sortUsingSelector:@selector(compare:)];

            @synchronized(_foundMedia) {
                NSUInteger count = _foundMedia.count;
                for (NSInteger i = [_indexPaths count] - 1; i >= 0; i--) {
                    NSIndexPath *path = _indexPaths[i];
                    if (path.row >= count)
                        continue;
                    if (_libraryMode != VLCLibraryModeCreateFolder && ![_foundMedia[path.row] isKindOfClass:[MLFile class]])
                        continue;
                    if (_libraryMode == VLCLibraryModeCreateFolder)
                        [self updateViewContents];

                    id item = _foundMedia[path.row];

                    if (![item isKindOfClass:[MLFile class]])
                        continue;

                    MLFile *file = (MLFile *)item;
                    file.labels = [NSSet setWithObjects:label, nil];
                    [_foundMedia removeObjectAtIndex:path.row];

                    file.folderTrackNumber = @([label files].count - 1);
                }
            }
        }
        _folderObject = nil;
    } else {
        //create new folder
        MLLabel *label = [[MLMediaLibrary sharedMediaLibrary] createObjectForEntity:@"Label"];
        label.name = folderName;

        //if items were selected
        if ([_indexPaths count] != 0) {
            [_indexPaths sortUsingSelector:@selector(compare:)];

            for (NSInteger i = [_indexPaths count] - 1; i >= 0; i--) {
                NSIndexPath *path = _indexPaths[i];
                @synchronized(_foundMedia) {
                    NSUInteger index = self.usingTableViewToShowData ? path.row : path.item;
                    if (index < _foundMedia.count) {
                        id item = _foundMedia[index];
                        if (![item isKindOfClass:[MLFile class]])
                            continue;

                        MLFile *file = (MLFile *)item;
                        file.labels = [NSSet setWithObjects:label, nil];
                        file.folderTrackNumber = @([label files].count - 1);
                        [_foundMedia removeObjectAtIndex:index];
                    }
                }
            }
        }
    }
    _indexPaths = nil;
    [self setEditing:NO];
    [self updateViewContents];
}

- (void)_collectionViewHandleLongPressGesture:(UIGestureRecognizer *) sender
{
    if (sender.state == UIGestureRecognizerStateBegan && !self.isEditing)
        [self setEditing:YES animated:YES];
}

#pragma mark - UI implementation
- (void)handleSelection
{
    if (self.usingTableViewToShowData) {
        NSInteger numberOfSections = [self.tableView numberOfSections];

        for (NSInteger section = 0; section < numberOfSections; section++) {
            NSInteger numberOfRowInSection = [self.tableView numberOfRowsInSection:section];

            for (NSInteger row = 0; row < numberOfRowInSection; row++) {
                if (!_isSelected)
                    [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section] animated:NO scrollPosition:UITableViewScrollPositionNone];
                else
                    [self.tableView deselectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section] animated:NO];
            }
        }
    } else {
        NSInteger numberOfItems = [self.collectionView numberOfItemsInSection:0];

        for (NSInteger item = 0; item < numberOfItems; item++) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:item inSection:0];

            if (!_isSelected)
                [self.collectionView selectItemAtIndexPath:indexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
            else
                [self.collectionView deselectItemAtIndexPath:indexPath animated:NO];
            [(VLCPlaylistCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:indexPath] selectionUpdate];
        }
    }
    _isSelected = !_isSelected;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];

    _isSelected = NO;

    UIBarButtonItem *editButton = self.editButtonItem;
    editButton.tintColor = [UIColor whiteColor];

    if (!editing && self.navigationItem.rightBarButtonItems.lastObject == _selectAllBarButtonItem)
        [self.navigationItem setRightBarButtonItems: [self.navigationItem.rightBarButtonItems subarrayWithRange:NSMakeRange(0, self.navigationItem.rightBarButtonItems.count - 1)]];
    else
        [self.navigationItem setRightBarButtonItems:editing ? [self.navigationItem.rightBarButtonItems arrayByAddingObject:_selectAllBarButtonItem] : [self.navigationItem rightBarButtonItems] animated:YES];

    if (self.usingTableViewToShowData) {
        [self setSearchBar:!editing resetContent:!editing];
        self.tableView.allowsMultipleSelectionDuringEditing = editing;
        [self.tableView setEditing:editing animated:YES];
        [self.editButtonItem setTitle:editing ? NSLocalizedString(@"BUTTON_CANCEL", nil) : NSLocalizedString(@"BUTTON_EDIT", nil)];
    } else {
        NSArray *visibleCells = self.collectionView.visibleCells;

        [visibleCells enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            VLCPlaylistCollectionViewCell *aCell = (VLCPlaylistCollectionViewCell*)obj;

            // always clear selection when enter edit mode
            aCell.selected = NO;
            [aCell setEditing:editing animated:animated];
        }];
        self.collectionView.allowsMultipleSelection = editing;

        /* UIKit doesn't clear the selection automagically if we leave the editing mode
         * so we need to do so manually */
        if (!editing) {
            [self.collectionView addGestureRecognizer:_longPressGestureRecognizer];
            NSArray *selectedItems = [self.collectionView indexPathsForSelectedItems];
            NSUInteger count = selectedItems.count;

            for (NSUInteger x = 0; x < count; x++)
                [self.collectionView deselectItemAtIndexPath:selectedItems[x] animated:NO];
        } else
            [self.collectionView removeGestureRecognizer:_longPressGestureRecognizer];
    }

    if (_libraryMode == VLCLibraryModeCreateFolder) {
        _libraryMode = _previousLibraryMode;
        _indexPaths = nil;
        [self updateViewContents];
    }

    self.navigationController.toolbarHidden = !editing;

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        NSMutableArray *rightBarButtonItems = [self.navigationItem.rightBarButtonItems mutableCopy];
        UIBarButtonItem *toggleDisplayedView = rightBarButtonItems[0];
        toggleDisplayedView.enabled = !editing;
        rightBarButtonItems[0] = toggleDisplayedView;
        self.navigationItem.rightBarButtonItems = rightBarButtonItems;
    }
}

- (void)toggleDisplayedView:(UIBarButtonItem *)button
{
    self.usingTableViewToShowData = !self.usingTableViewToShowData;
    UIImage *newButtonImage = [UIImage imageNamed: self.usingTableViewToShowData ? @"collectionViewIcon" : @"tableViewIcon"];
    [button setImage:newButtonImage];
    [self updateViewsForCurrentDisplayMode];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)aTableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleDelete;
}

- (IBAction)leftButtonAction:(id)sender
{
    [[VLCSidebarController sharedInstance] toggleSidebar];

    if (self.isEditing)
        [self setEditing:NO animated:YES];
}

- (IBAction)backToAllItems:(id)sender
{
    if (!self.usingTableViewToShowData) {
        if (self.editing)
            [self setEditing:NO animated:NO];
    }
    _inFolder = NO;
    UIBarButtonItem *createFolderItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemOrganize target:self action:@selector(createFolder)];
    NSMutableArray *toolbarItems = [self.toolbarItems mutableCopy];
    toolbarItems[2] = createFolderItem;
    self.toolbarItems = toolbarItems;
    [self setLibraryMode:_previousLibraryMode];
    if (!self.isEditing) {
        [self setSearchBar:YES resetContent:NO];
    }
    [self updateViewContents];
}

- (void)_endEditingWithHardReset:(BOOL)hardReset
{
    [[MLMediaLibrary sharedMediaLibrary] updateMediaDatabase];
    if (hardReset)
        [self updateViewContents];
    else
        [self reloadViews];

    [self setEditing:NO animated:YES];
}

- (void)deleteSelection:(id)sender
{
    NSArray *indexPaths = [self usingTableViewToShowData] ? [self.tableView indexPathsForSelectedRows] : [self.collectionView indexPathsForSelectedItems];

    if (!indexPaths && !_deleteFromTableView) {
        UIAlertController *invalidSelection = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"DELETE_INVALID_TITLE", nil) message:NSLocalizedString(@"DELETE_INVALID_MESSAGE", nil) preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *doneAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"BUTTON_OK", nil) style:UIAlertActionStyleDefault handler:nil];

        [invalidSelection addAction:doneAction];
        [self presentViewController:invalidSelection animated:YES completion:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        UIAlertAction *deleteAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"BUTTON_DELETE", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            if (_deleteFromTableView) {
                @synchronized (_foundMedia) {
                    NSIndexPath *indexPath = (NSIndexPath *)sender;
                    if (indexPath && indexPath.row < _foundMedia.count)
                        [self removeMediaObject: _foundMedia[indexPath.row] updateDatabase:YES];
                }
            } else
                [self deletionAfterConfirmation];
            _deleteFromTableView = NO;
        }];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"BUTTON_CANCEL", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            _deleteFromTableView ? [self setEditing:NO animated:YES] : [self reloadViews];
            _deleteFromTableView = NO;
        }];
        [alert addAction:deleteAction];
        [alert addAction:cancelAction];

        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
            CGRect tmpBounds = self.view.bounds;
            [alert setTitle:NSLocalizedString(@"DELETE_TITLE", nil)];
            [alert setMessage:NSLocalizedString(@"DELETE_MESSAGE", nil)];
            [alert.popoverPresentationController setPermittedArrowDirections:0];
            [alert.popoverPresentationController setSourceView:self.view];
            [alert.popoverPresentationController setSourceRect:CGRectMake(tmpBounds.size.width / 2.0, tmpBounds.size.height / 2.0, 1.0, 1.0)];
        }
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)deletionAfterConfirmation
{
    NSArray *indexPaths;
    if (self.usingTableViewToShowData)
        indexPaths = [self.tableView indexPathsForSelectedRows];
    else
        indexPaths = [self.collectionView indexPathsForSelectedItems];

    @synchronized(_foundMedia) {
        NSUInteger count = indexPaths.count;
        NSMutableArray *objects = [[NSMutableArray alloc] initWithCapacity:count];

        for (NSUInteger x = 0; x < count; x++)
            [objects addObject:_foundMedia[[indexPaths[x] row]]];

        for (NSUInteger x = 0; x < count; x++)
            [self removeMediaObject:objects[x] updateDatabase:NO];
    }

    [self _endEditingWithHardReset:YES];
}

- (void)renameSelection
{
    NSArray *indexPaths = [self selectedIndexPaths];

    if (indexPaths.count < 1) {
        [self _endEditingWithHardReset:NO];
        return;
    }

    NSString *itemName;
    if (self.usingTableViewToShowData)
        itemName = [(VLCPlaylistTableViewCell *)[self.tableView cellForRowAtIndexPath:indexPaths[0]] titleLabel].text;
    else
        itemName = [(VLCPlaylistCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:indexPaths[0]] titleLabel].text;

    VLCAlertView *alert = [[VLCAlertView alloc] initWithTitle:[NSString stringWithFormat:NSLocalizedString(@"RENAME_MEDIA_TO", nil), itemName] message:nil cancelButtonTitle:NSLocalizedString(@"BUTTON_CANCEL", nil) otherButtonTitles:@[NSLocalizedString(@"BUTTON_RENAME", nil)]];
    [alert setAlertViewStyle:UIAlertViewStylePlainTextInput];
    [[alert textFieldAtIndex:0] setText:itemName];
    [[alert textFieldAtIndex:0] setClearButtonMode:UITextFieldViewModeAlways];

    __weak VLCAlertView *weakAlert = alert;
    alert.completion = ^(BOOL cancelled, NSInteger buttonIndex) {
        if (cancelled)
            [self _endEditingWithHardReset:NO];
        else
            [self renameMediaObjectTo:[weakAlert textFieldAtIndex:0].text];

    };
    [alert show];
}

- (void)renameMediaObjectTo:(NSString*)newName
{
    NSArray *indexPaths = [self selectedIndexPaths];
    if (indexPaths.count < 1)
        return;

    id mediaObject;

    @synchronized (_foundMedia) {
        NSUInteger row = [indexPaths[0] row];
        if (row >= _foundMedia.count)
            return;

        mediaObject = _foundMedia[row];
    }

    if ([mediaObject isKindOfClass:[MLAlbum class]] || [mediaObject isKindOfClass:[MLShowEpisode class]] || [mediaObject isKindOfClass:[MLShow class]] || [mediaObject isKindOfClass:[MLLabel class]] )
        [mediaObject setName:newName];
    else
        [mediaObject setTitle:newName];

    if (self.usingTableViewToShowData)
        [self.tableView deselectRowAtIndexPath:indexPaths[0] animated:YES];
    else
        [self.collectionView deselectItemAtIndexPath:indexPaths[0] animated:YES];

    if (indexPaths.count > 1)
        [self renameSelection];
    else
        [self _endEditingWithHardReset:NO];
}

- (void)updateViewsForCurrentDisplayMode
{
    UIImage *newButtonImage = [UIImage imageNamed: self.usingTableViewToShowData ? @"collectionViewIcon" : @"tableViewIcon"];
    [self.displayModeBarButtonItem setImage:newButtonImage];
}

#pragma mark - Sharing

// We take the array of index paths (instead of a count) to actually examine if the content is shareable. Selecting a single folder should not enable the share button.
- (void)updateActionBarButtonItemStateWithSelectedIndexPaths:(NSArray *)indexPaths
{
    NSUInteger count = [indexPaths count];
    if (!indexPaths || count == 0) {
        _openInActivityBarButtonItem.enabled = NO;
    } else {
        // Look for at least one MLFile
        @synchronized(_foundMedia) {
            for (NSUInteger x = 0; x < count; x++) {
                id mediaItem = _foundMedia[[indexPaths[x] row]];

                if ([mediaItem isKindOfClass:[MLFile class]] || [mediaItem isKindOfClass:[MLAlbumTrack class]] | [mediaItem isKindOfClass:[MLShowEpisode class]]) {
                    _openInActivityBarButtonItem.enabled = YES;
                    return;
                }
            }
        }
    }
}

- (void)actOnSelection:(UIBarButtonItem *)barButtonItem
{
    NSParameterAssert(barButtonItem);
    if (!barButtonItem) {
        APLog(@"Missing a UIBarButtonItem to present from");
        return;
    }

    NSArray *indexPaths = [self selectedIndexPaths];

    NSUInteger count = indexPaths.count;
    if (count) {
        NSMutableArray /* NSURL */ *fileURLobjects = [[NSMutableArray alloc] initWithCapacity:count];

        for (NSUInteger x = 0; x < count; x++) {
            id mediaItem;
            @synchronized (_foundMedia) {
                mediaItem = _foundMedia[[indexPaths[x] row]];
            }
            NSURL *fileURL;

            if ([mediaItem isKindOfClass:[MLFile class]])
                fileURL = [(MLFile *) mediaItem url];
            else if ([mediaItem isKindOfClass:[MLAlbumTrack class]])
                fileURL = [[(MLAlbumTrack *) mediaItem anyFileFromTrack] url];
            else if ([mediaItem isKindOfClass:[MLShowEpisode class]])
                fileURL = [[(MLShowEpisode *) mediaItem anyFileFromEpisode] url];

            if ([fileURL isFileURL])
                [fileURLobjects addObject:fileURL];
        }

        if ([fileURLobjects count]) {
            // Provide some basic user feedback as UIActivityController lags in presentation sometimes (blocking the main thread).
            [self.navigationController.toolbar.items makeObjectsPerformSelector:@selector(setEnabled:) withObject:@(NO)];

            // Just in case, since we are facing a possible delay from code we do not control (UIActivityViewController), disable any possible changes to selection (or exit from this screen)
            [[UIApplication sharedApplication] beginIgnoringInteractionEvents];

            // The reason we do a dispatch_async to the main queue here even though we are already on the main queue is because UIActivityViewController blocks the main thread at some point (either during creation or presentation), which won't let UIKit draw our call to disable the toolbar items in time. On an actual device (where the lag can be seen when UIActivityViewController is presented for the first time during an applications lifetime) this makes for a much better user experience. If you have more items to share the lag may be greater.
            dispatch_async(dispatch_get_main_queue(), ^{
                _openInActivity = [[VLCOpenInActivity alloc] init];
                _openInActivity.presentingViewController = self;
                _openInActivity.presentingBarButtonItem = barButtonItem;

                dispatch_block_t enableInteractionBlock = ^{
                    // Strangely makeObjectsPerformSelector:withObject has trouble here (when called from presentViewController:animated:completion:)
                    // [self.navigationController.toolbar.items makeObjectsPerformSelector:@selector(setEnabled:) withObject:@(YES)];
                    for (UIBarButtonItem *item in self.navigationController.toolbar.items) {
                        item.enabled = YES;
                    }

                    if ([[UIApplication sharedApplication] isIgnoringInteractionEvents]) {
                        [[UIApplication sharedApplication] endIgnoringInteractionEvents];
                    }
                };

                UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:fileURLobjects applicationActivities:@[_openInActivity]];
                if (SYSTEM_RUNS_IOS8_OR_LATER)
                    controller.popoverPresentationController.sourceView = self.navigationController.toolbar;

                controller.completionHandler = ^(NSString *activityType, BOOL completed) {
                    APLog(@"UIActivityViewController finished with activity type: %@, completed: %i", activityType, completed);

                    // Provide some feedback if saving media to the Camera Roll. Note that this could cause a false positive if the user chooses "Don't Allow" in the permissions dialog, and UIActivityViewController does not inform us of that, so check the authorization status.

                    // By the time this is called, the user has not had time to choose whether to allow access to the Photos library, so only display the message if we are truly sure we got authorization. The first time the user saves to the camera roll he won't see the confirmation because of this timing issue. This is better than showing a success message when the user had denied access. A timing workaround could be developed if needed through UIApplicationDidBecomeActiveNotification (to know when the security alert view was dismissed) or through other ALAssets APIs.
                    if (completed && [activityType isEqualToString:UIActivityTypeSaveToCameraRoll] && [ALAssetsLibrary authorizationStatus] == ALAuthorizationStatusAuthorized) {
                        VLCAlertView *alertView = [[VLCAlertView alloc] initWithTitle:NSLocalizedString(@"SHARING_SUCCESS_CAMERA_ROLL", nil)
                                                                              message:nil
                                                                             delegate:nil
                                                                    cancelButtonTitle:NSLocalizedString(@"BUTTON_OK", nil)
                                                                    otherButtonTitles:nil];
                        [alertView show];
                    }
                    _openInActivity = nil;

                    // Just in case, we could call enableInteractionBlock here. Since we are disabling touch interaction for the entire UI, to be safe that we return to the proper state: re-enable everything (if presentViewController:animated:completion: failed for some reason). But UIApplication gives us a warning even if we check isIgnoringInteractionEvents, so do not call it for now.
                    // enableInteractionBlock();
                };
                [self.navigationController presentViewController:controller animated:YES completion:enableInteractionBlock];
            });
            return;
        }
    }

    VLCAlertView *alertView = [[VLCAlertView alloc] initWithTitle:NSLocalizedString(@"SHARING_ERROR_NO_FILES", nil)
                                                          message:nil
                                                         delegate:nil
                                                cancelButtonTitle:NSLocalizedString(@"BUTTON_OK", nil)
                                                otherButtonTitles:nil];
    [alertView show];
}

#pragma mark - properties

- (void)setLibraryMode:(VLCLibraryMode)mode
{
    _libraryMode = mode;
    [self updateViewContents];

    if (mode == VLCLibraryModeAllAlbums ||
        mode == VLCLibraryModeAllSeries ||
        mode == VLCLibraryModeAllFiles) {
        _previousLibraryMode = mode;
    }
}

- (BOOL)usingTableViewToShowData
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kUsingTableViewToShowData];
}

- (void)setUsingTableViewToShowData:(BOOL)usingTableViewToShowData
{
    [[NSUserDefaults standardUserDefaults] setBool:usingTableViewToShowData forKey:kUsingTableViewToShowData];
    [self updateViewsForCurrentDisplayMode];
    [self setupContentViewWithContentInset:usingTableViewToShowData];
}

#pragma mark - autorotation

// RootController is responsible for supporting interface orientation(iOS6.0+), i.e. navigation controller
// so this will not work as intended without "voodoo magic"(UINavigationController category, subclassing, etc)
/* introduced in iOS 6 */
- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        return UIInterfaceOrientationMaskAll;

    return (_foundMedia.count > 0)? UIInterfaceOrientationMaskAllButUpsideDown:
    UIInterfaceOrientationMaskPortrait;
}

/* introduced in iOS 6 */
- (BOOL)shouldAutorotate
{
    return (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) || (_foundMedia.count > 0);
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];

    [self setViewFromDeviceOrientation];
    if (self.usingTableViewToShowData) {
        NSArray *visibleCells = [self.tableView visibleCells];
        NSUInteger cellCount = visibleCells.count;
        for (NSUInteger x = 0; x < cellCount; x++) {
            if ([visibleCells[x] isExpanded])
                [visibleCells[x] metaDataLabel].hidden = YES;
        }
    } else {
        [self.collectionView.collectionViewLayout invalidateLayout];
    }
}

#pragma mark - Search Display Controller Delegate

- (BOOL)searchDisplayController:(UISearchDisplayController *)controller shouldReloadTableForSearchString:(NSString *)searchString
{
    @synchronized (_searchData) {
        [_searchData removeAllObjects];
    }
    NSManagedObject *item;
    NSRange nameRange;

    @synchronized(_foundMedia) {
        NSInteger listCount = _foundMedia.count;
        for (int i = 0; i < listCount; i++) {
            item = _foundMedia[i];

            if ([item isKindOfClass:[MLAlbum class]]) {
                nameRange = [self _searchAlbum:(MLAlbum *)item forString:searchString];
            } else if ([item isKindOfClass:[MLAlbumTrack class]]) {
                nameRange = [self _searchAlbumTrack:(MLAlbumTrack *)item forString:searchString];
            } else if ([item isKindOfClass:[MLShowEpisode class]]) {
                nameRange = [self _searchShowEpisode:(MLShowEpisode *)item forString:searchString];
            } else if ([item isKindOfClass:[MLShow class]]) {
                nameRange = [self _searchShow:(MLShow *)item forString:searchString];
            } else if ([item isKindOfClass:[MLLabel class]])
                nameRange = [self _searchLabel:(MLLabel *)item forString:searchString];
            else // simple file
                nameRange = [self _searchFile:(MLFile*)item forString:searchString];

            @synchronized (_searchData) {
                if (nameRange.location != NSNotFound)
                    [_searchData addObject:item];
            }
        }
    }

    return YES;
}

- (NSRange)_searchAlbumTrack:(MLAlbumTrack *)albumTrack forString:(NSString *)searchString
{
    NSString *trackTitle = albumTrack.title;
    NSRange nameRange = [trackTitle rangeOfString:searchString options:NSCaseInsensitiveSearch];
    if (nameRange.location != NSNotFound)
        return nameRange;

    NSMutableArray *stringsToSearch = [[NSMutableArray alloc] initWithObjects:trackTitle, nil];
    if ([albumTrack artist])
        [stringsToSearch addObject:[albumTrack artist]];
    if ([albumTrack genre])
        [stringsToSearch addObject:[albumTrack genre]];

    NSArray *substrings = [searchString componentsSeparatedByString:@" "];
    NSUInteger substringCount = substrings.count;
    NSUInteger searchStringCount = stringsToSearch.count;

    for (NSUInteger x = 0; x < substringCount; x++) {
        for (NSUInteger y = 0; y < searchStringCount; y++) {
            nameRange = [stringsToSearch[y] rangeOfString:substrings[x] options:NSCaseInsensitiveSearch];
            if (nameRange.location != NSNotFound)
                break;
        }
        if (nameRange.location != NSNotFound)
            break;
    }
    return nameRange;
}

- (NSRange)_searchAlbum:(MLAlbum *)album forString:(NSString *)searchString
{
    NSString *albumName = [album name];
    NSRange nameRange = [albumName rangeOfString:searchString options:NSCaseInsensitiveSearch];
    if (nameRange.location != NSNotFound)
        return nameRange;

    if ([album releaseYear]) {
        nameRange = [[album releaseYear] rangeOfString:searchString options:NSCaseInsensitiveSearch];
        if (nameRange.location != NSNotFound)
            return nameRange;
    }

    /* split search string into substrings and try again */
    NSArray *substrings = [searchString componentsSeparatedByString:@" "];
    NSUInteger substringCount = substrings.count;
    if (substringCount > 1) {
        for (NSUInteger x = 0; x < substringCount; x++) {
            nameRange = [searchString rangeOfString:substrings[x] options:NSCaseInsensitiveSearch];
            if (nameRange.location != NSNotFound)
                break;
        }
    }

    if (nameRange.location != NSNotFound)
        return nameRange;

    /* search our tracks if we can't find what the user is looking for */
    NSArray *tracks = [album sortedTracks];
    NSUInteger trackCount = tracks.count;
    for (NSUInteger x = 0; x < trackCount; x++) {
        nameRange = [self _searchAlbumTrack:tracks[x] forString:searchString];
        if (nameRange.location != NSNotFound)
            break;
    }
    return nameRange;
}

- (NSRange)_searchShowEpisode:(MLShowEpisode *)episode forString:(NSString *)searchString
{
    /* basic search first, then try more complex things */
    NSString *episodeName = [episode name];
    NSRange nameRange;

    if (episodeName) {
        nameRange = [episodeName rangeOfString:searchString options:NSCaseInsensitiveSearch];
        if (nameRange.location != NSNotFound)
            return nameRange;
    }

    /* split search string into substrings and try again */
    NSArray *substrings = [searchString componentsSeparatedByString:@" "];
    NSUInteger substringCount = substrings.count;
    if (substringCount > 1) {
        for (NSUInteger x = 0; x < substringCount; x++) {
            nameRange = [searchString rangeOfString:substrings[x] options:NSCaseInsensitiveSearch];
            if (nameRange.location != NSNotFound)
                break;
        }
    }

    return nameRange;
}

- (NSRange)_searchShow:(MLShow *)mediaShow forString:(NSString *)searchString
{
    /* basic search first, then try more complex things */
    NSRange nameRange = [[mediaShow name] rangeOfString:searchString options:NSCaseInsensitiveSearch];

    if (nameRange.location != NSNotFound)
        return nameRange;

    /* split search string into substrings and try again */
    NSArray *substrings = [searchString componentsSeparatedByString:@" "];
    NSUInteger substringCount = substrings.count;
    if (substringCount > 1) {
        for (NSUInteger x = 0; x < substringCount; x++) {
            nameRange = [searchString rangeOfString:substrings[x] options:NSCaseInsensitiveSearch];
            if (nameRange.location != NSNotFound)
                break;
        }
    }
    if (nameRange.location != NSNotFound)
        return nameRange;

    /* user didn't search for our show name, let's do a deeper search on the episodes */
    NSArray *episodes = [mediaShow sortedEpisodes];
    NSUInteger episodeCount = episodes.count;
    for (NSUInteger x = 0; x < episodeCount; x++)
        nameRange = [self _searchShowEpisode:episodes[x] forString:searchString];

    return nameRange;
}

- (NSRange)_searchLabel:(MLLabel *)mediaLabel forString:(NSString *)searchString
{
    /* basic search first, then try more complex things */
    NSRange nameRange = [[mediaLabel name] rangeOfString:searchString options:NSCaseInsensitiveSearch];

    if (nameRange.location != NSNotFound)
        return nameRange;

    /* user didn't search for our label name, let's do a deeper search */
    NSArray *files = [mediaLabel sortedFolderItems];
    NSUInteger fileCount = files.count;
    for (NSUInteger x = 0; x < fileCount; x++) {
        nameRange = [self _searchFile:files[x] forString:searchString];
        if (nameRange.location != NSNotFound)
            break;
    }
    return nameRange;
}

- (NSRange)_searchFile:(MLFile *)mediaFile forString:(NSString *)searchString
{
    /* basic search first, then try more complex things */
    NSRange nameRange = [[mediaFile title] rangeOfString:searchString options:NSCaseInsensitiveSearch];
    if (nameRange.location != NSNotFound)
        return nameRange;

    NSMutableArray *stringsToSearch = [[NSMutableArray alloc] initWithObjects:[mediaFile title], nil];
    if ([mediaFile artist])
        [stringsToSearch addObject:[mediaFile artist]];
    if ([mediaFile releaseYear])
        [stringsToSearch addObject:[mediaFile releaseYear]];

    NSArray *substrings = [searchString componentsSeparatedByString:@" "];
    NSUInteger substringCount = substrings.count;
    NSUInteger searchStringCount = stringsToSearch.count;

    for (NSUInteger x = 0; x < substringCount; x++) {
        for (NSUInteger y = 0; y < searchStringCount; y++) {
            nameRange = [stringsToSearch[y] rangeOfString:substrings[x] options:NSCaseInsensitiveSearch];
            if (nameRange.location != NSNotFound)
                break;
        }
        if (nameRange.location != NSNotFound)
            break;
    }

    return nameRange;
}

#pragma mark - handoff

- (void)restoreUserActivityState:(NSUserActivity *)activity
{
    NSString *userActivityType = activity.activityType;
    if([userActivityType isEqualToString:kVLCUserActivityLibraryMode] ||
       [userActivityType isEqualToString:kVLCUserActivityLibrarySelection]) {

        NSDictionary *dict = activity.userInfo;
        NSString *folderPath = dict[@"folder"];
        if (!folderPath) return;
        NSURL *folderURL = [NSURL URLWithString:folderPath];

        @synchronized(_foundMedia) {
            NSUInteger count = _foundMedia.count;
            for (NSUInteger i = 0; i < count; i++) {
                NSManagedObject *object = _foundMedia[i];

                if([object.objectID.URIRepresentation isEqual:folderURL]) {
                    [self tableView:self.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]];
                }
            }
        }
    }
}

- (void)searchDisplayController:(UISearchDisplayController *)controller didLoadSearchResultsTableView:(UITableView *)tableView
{
    tableView.rowHeight = 90.;
    tableView.backgroundColor = [UIColor blackColor];
}

@end
