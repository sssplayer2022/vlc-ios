/*****************************************************************************
 * VLCGoogleDriveTableViewController.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013-2015 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Carola Nitz <nitz.carola # googlemail.com>
 *          Felix Paul Kühne <fkuehne # videolan.org>
 *          Soomin Lee <TheHungryBu # gmail.com>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCGoogleDriveTableViewController.h"
#import "VLCAppDelegate.h"
#import "VLCGoogleDriveController.h"
#import "VLCCloudStorageTableViewCell.h"
#import "VLC-Swift.h"

#import <AppAuth/AppAuth.h>
#import <GTMAppAuth/GTMAppAuth.h>

@interface VLCGoogleDriveTableViewController () <VLCCloudStorageTableViewCell>
{
    VLCGoogleDriveController *_googleDriveController;

    GTLRDrive_File *_selectedFile;
}

@end

@implementation VLCGoogleDriveTableViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    _googleDriveController = [VLCGoogleDriveController sharedInstance];
    _googleDriveController.delegate = self;
    self.controller = _googleDriveController;

    self.navigationItem.titleView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"DriveWhite"]];

    [self.cloudStorageLogo setImage:[UIImage imageNamed:@"DriveWhite"]];

    [self.cloudStorageLogo sizeToFit];
    self.cloudStorageLogo.center = self.view.center;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    if (@available(iOS 11.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles = NO;
    }

    [self updateViewAfterSessionChange];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    NSInteger currentOffset = scrollView.contentOffset.y;
    NSInteger maximumOffset = scrollView.contentSize.height - scrollView.frame.size.height;

    if (maximumOffset - currentOffset <= - self.tableView.rowHeight) {
        if (_googleDriveController.hasMoreFiles && !self.activityIndicator.isAnimating) {
            [self requestInformationForCurrentPath];
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if ((VLCAppDelegate *)[UIApplication sharedApplication].delegate.window.rootViewController.presentedViewController == nil) {
        [_googleDriveController stopSession];
        [self.tableView reloadData];
    }

}

#pragma mark - Table view data source

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"GoogleDriveCell";

    VLCCloudStorageTableViewCell *cell = (VLCCloudStorageTableViewCell *)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil)
        cell = [VLCCloudStorageTableViewCell cellWithReuseIdentifier:CellIdentifier];

    NSArray *listOfFiles = _googleDriveController.currentListFiles;
    NSInteger row = indexPath.row;
    if (row < listOfFiles.count) {
        cell.driveFile = listOfFiles[row];
        if ([cell.driveFile.mimeType isEqualToString:@"application/vnd.google-apps.folder"])
            [cell setIsDownloadable:NO];
        else
            [cell setIsDownloadable:YES];
    }
    cell.delegate = self;

    return cell;
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self.tableView deselectRowAtIndexPath:indexPath animated:NO];

    if (indexPath.row >= _googleDriveController.currentListFiles.count)
        return;

    _selectedFile = _googleDriveController.currentListFiles[indexPath.row];
    if (![_selectedFile.mimeType isEqualToString:@"application/vnd.google-apps.folder"]) {
        [_googleDriveController streamFile:_selectedFile];
    } else {
        /* dive into subdirectory */
        if (![self.currentPath isEqualToString:@""])
            self.currentPath = [self.currentPath stringByAppendingString:@"/"];
        self.currentPath = [self.currentPath stringByAppendingString:_selectedFile.identifier];
        [self requestInformationForCurrentPath];
    }
}

- (void)triggerDownloadForCell:(VLCCloudStorageTableViewCell *)cell
{
    _selectedFile = _googleDriveController.currentListFiles[[self.tableView indexPathForCell:cell].row];

    if (_selectedFile.size.longLongValue < [[UIDevice currentDevice] VLCFreeDiskSpace].longLongValue) {
        /* selected item is a proper file, ask the user if s/he wants to download it */
        NSArray<VLCAlertButton *> *buttonsAction = @[[[VLCAlertButton alloc] initWithTitle: NSLocalizedString(@"BUTTON_CANCEL", nil)
                                                                                     style: UIAlertActionStyleCancel
                                                                                  action: ^(UIAlertAction *action) {
                                                                                      self->_selectedFile = nil;
                                                                                  }],
                                                     [[VLCAlertButton alloc] initWithTitle: NSLocalizedString(@"BUTTON_DOWNLOAD", nil)
                                                                                  action: ^(UIAlertAction *action) {
                                                                                      [self->_googleDriveController downloadFileToDocumentFolder:self->_selectedFile];
                                                                                      self->_selectedFile = nil;
                                                                                  }]
                                                     ];
        [VLCAlertViewController alertViewManagerWithTitle:NSLocalizedString(@"DROPBOX_DOWNLOAD", nil)
                                             errorMessage:[NSString stringWithFormat:NSLocalizedString(@"DROPBOX_DL_LONG", nil), _selectedFile.name, [[UIDevice currentDevice] model]]
                                           viewController:self
                                            buttonsAction:buttonsAction];
    } else {
        [VLCAlertViewController alertViewManagerWithTitle:NSLocalizedString(@"DISK_FULL", nil)
                                             errorMessage:[NSString stringWithFormat:NSLocalizedString(@"DISK_FULL_FORMAT", nil), _selectedFile.name, [[UIDevice currentDevice] model]]
                                           viewController:self];
    }
}
#pragma mark - login dialog

- (IBAction)loginAction:(id)sender
{
    if (![_googleDriveController isAuthorized]) {

        self.authorizationInProgress = YES;

        // Build the request with the clientID and scopes.
        OIDAuthorizationRequest *request = [[OIDAuthorizationRequest alloc] initWithConfiguration:[GTMAppAuthFetcherAuthorization configurationForGoogle]
                                                                                         clientId:kVLCGoogleDriveClientID
                                                                                     clientSecret:kVLCGoogleDriveClientSecret
                                                                                           scopes:@[OIDScopeOpenID, kGTLRAuthScopeDrive]
                                                                                      redirectURL:[NSURL URLWithString:kVLCGoogleRedirectURI]
                                                                                     responseType:OIDResponseTypeCode
                                                                             additionalParameters:nil];

        // Perform the previously built request and saving the current authorization flow.

        URLHandlers.googleURLHandler.currentGoogleAuthorizationFlow = [OIDAuthState authStateByPresentingAuthorizationRequest:request presentingViewController:self
           callback:^(OIDAuthState *_Nullable authState, NSError *_Nullable error) {

               self.authorizationInProgress = NO;
               if (authState) {
                   // Upon successful completion...
                   self->_googleDriveController.driveService.authorizer = [[GTMAppAuthFetcherAuthorization alloc] initWithAuthState:authState];
                   [GTMAppAuthFetcherAuthorization saveAuthorization:(GTMAppAuthFetcherAuthorization *)self->_googleDriveController.driveService.authorizer
                                                   toKeychainForName:kKeychainItemName];
                   [self updateViewAfterSessionChange];
                   [self.activityIndicator startAnimating];
               } else {
                   self->_googleDriveController.driveService.authorizer = nil;
               }
           }];

    } else {
        [_googleDriveController logout];
    }
}

@end
