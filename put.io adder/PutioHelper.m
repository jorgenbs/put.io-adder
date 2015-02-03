//
//  PutioHelper.m
//  put.io adder
//
//  Created by Nico on 7/13/13.
//  Copyright (c) 2013 Nicolas Oelgart. All rights reserved.
//

#import "PutioHelper.h"
#import "PutioMainController.h"
#import "SSKeychain.h"
#import "V2PutIOAPIClient.h"
#import "NSString+DisplayName.h"
#import "AFPropertyListRequestOperation.h"
#import <AppKit/AppKit.h>

@implementation PutioHelper

@synthesize putioController, putioAPI;

static PutioHelper *sharedHelper = nil;


+ (PutioHelper*)sharedHelper
{
    @synchronized(self)
    {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            sharedHelper = [[self alloc] init];
            sharedHelper.putioAPI = [V2PutIOAPIClient setup];
        });
    }
    
    return sharedHelper;
}


- (void)authenticateUser
{
    NSError *error;
    NSString *token = [SSKeychain passwordForService:@"put.io adder" account:@"711" error:&error];
    
    if ([error code] == SSKeychainErrorNotFound)
    {
        self.putioController.message.stringValue = NSLocalizedString(@"HELPER_AUTH_REQUIRED", nil);
        self.putioController.userInfo.stringValue = self.putioController.message.stringValue;
        self.putioController.transferInfo.stringValue = @"Please log into put.io";
        
        NSString *url = @"https://api.put.io/v2/oauth2/authenticate?client_id=711&response_type=token&redirect_uri=putio://callback";
        [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: url]];
    }
    else
    {
        [self.putioAPI setApiToken: token];
        [self updateUserInfo];
        [self.putioController.toggleShowTransfers setEnabled:YES];
        
        [self startUserinfoTimer];
    }
}


- (void)startUserinfoTimer
{
    userInfoTimer = [NSTimer scheduledTimerWithTimeInterval:20.0  target:self selector:@selector(updateUserInfo) userInfo:nil repeats:YES];
}


- (void)updateUserInfo
{
    [self.putioAPI getAccount:^(PKAccount *account)
    {
        putioController.userInfo.stringValue = [NSString stringWithFormat:NSLocalizedString(@"HELPER_USERINFO_ACCOUNT", nil),
             [account username],
             [self transformedValue:[account diskUsed]],
             [self transformedValue:[account diskSize]]
        ];
    }
    failure:^(NSError *error)
    {
        putioController.userInfo.stringValue = NSLocalizedString(@"HELPER_USERINFO_FAILED", nil);
    }];
    
    [self.putioAPI getTransfers:^(NSArray *putioTransfers)
    {
        if (putioController.transfers.count > 0)
        {
            PKTransfer *currentTransfer;
            PKTransfer *newTransfer;
             
            for (unsigned i = 0; i < putioController.transfers.count; i++)
            {
                currentTransfer = (PKTransfer*)[putioController.transfers objectAtIndex:i];
                 
                for (unsigned j = 0; j < putioTransfers.count; j++)
                {
                    newTransfer = (PKTransfer*)[putioTransfers objectAtIndex:j];
                     
                    if ((currentTransfer.id == newTransfer.id) &&
                         ((![currentTransfer.status isEqualToString:@"COMPLETED"] &&
                           ![currentTransfer.status isEqualToString:@"SEEDING"])
                          &&
                          ([newTransfer.status isEqualToString:@"COMPLETED"]
                          || [newTransfer.status isEqualToString:@"SEEDING"])))
                    {
                        NSUserNotification *notification = [[NSUserNotification alloc] init];
                        notification.title = NSLocalizedString(@"NOTIFICATION_TITLE", nil);
                        notification.informativeText = [NSString stringWithFormat:NSLocalizedString(@"NOTIFICATION_MSG", nil), newTransfer.name];
                        notification.soundName = NSUserNotificationDefaultSoundName;
                        notification.userInfo = @{@"fileID": newTransfer.fileID};

                        NSUserNotificationCenter *notificationCenter = [NSUserNotificationCenter defaultUserNotificationCenter];
                        [notificationCenter setDelegate:self.putioController];

                        // NS_AVAILABLE(10_9, NA)
                        if ([notification respondsToSelector:@selector(setContentImage:)])
                        {
                            // PutioKit failed me at getting additional file info.
                            // Maybe I failed
                            // Using this until I know how to fix it.
                            NSString *baseurl = @"https://api.put.io/";
                            NSString *path = [NSString stringWithFormat:@"/v2/files/%@", newTransfer.fileID];
                            
                            AFHTTPClient *client = [[AFHTTPClient alloc] initWithBaseURL:[NSURL URLWithString:baseurl]];
                            [client registerHTTPOperationClass:[AFJSONRequestOperation class]];
                            [client setDefaultHeader:@"Accept" value:@"application/json"];
                            [client setParameterEncoding:AFJSONParameterEncoding];
                            
                            [client
                                getPath:path
                                parameters:@{@"oauth_token": sharedHelper.putioAPI.apiToken}
                                success: ^(AFHTTPRequestOperation *operation, id JSON)
                            {
                                NSDictionary *file = [JSON valueForKey:@"file"];
                                NSString *contentImage;
                                if (file)
                                {
                                    if ([file valueForKey:@"screenshot"] != nil)
                                    {
                                        contentImage = [file valueForKey:@"screenshot"];
                                    }
                                    else
                                    {
                                        contentImage = [file valueForKey:@"icon"];
                                    }
                                    
                                    @try
                                    {
                                        notification.contentImage = [[NSImage alloc] initWithContentsOfURL:[NSURL URLWithString:contentImage]];
                                    }
                                    @catch (NSException *e)
                                    {
                                    }
                                    @finally
                                    {
                                        [notificationCenter deliverNotification:notification];
                                    }
                                }

                                
                            }
                            failure:^(AFHTTPRequestOperation *operation, NSError *error)
                            {
                                // NSLog("Failed to fetch screenshot/icon");
                            }];
                        }
                        else
                        {
                            [notificationCenter deliverNotification:notification];
                        }
                    }
                }
            }
        }
         
        [self.putioController setTransfers: [putioTransfers mutableCopy]];
        [self.putioController.tableView reloadData];
         
        int pendingDownloads = 0;
        int completedDownloads = 0;
        int totalTransfers = (int)putioTransfers.count;
        int percentDone = 0;
        NSString *status;
         
        for (int i = 0; i < totalTransfers; i++)
        {
            status = [[putioTransfers objectAtIndex:i] valueForKey:@"status"];
             
            if ([status isEqualToString:@"WAITING"] || [status isEqualToString:@"DOWNLOADING"] || [status isEqualToString:@"IN_QUEUE"])
            {
                pendingDownloads++;
                percentDone += [[[putioTransfers objectAtIndex:i] percentDone] integerValue];
            }
            else if ([status isEqualToString:@"COMPLETED"] || [status isEqualToString:@"SEEDING"])
            {
                completedDownloads++;
            }
        }
        
        if (putioController.statusItem == nil && pendingDownloads > 0)
        {
            putioController.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
            [putioController.statusItem setMenu:[[NSMenu alloc] init]];
            [putioController.statusItem setImage:[NSImage imageNamed:@"puticon"]];
        }
        
        if (pendingDownloads == 0)
        {
            putioController.transferInfo.stringValue = [NSString stringWithFormat:NSLocalizedString(@"HELPER_NO_PENDING_TRANSFERS", nil), completedDownloads];
            
            [[NSStatusBar systemStatusBar] removeStatusItem: putioController.statusItem];
            putioController.statusItem = nil;
        }
        else
        {
            [putioController.statusItem setTitle:[NSString stringWithFormat:@"%i%%", (percentDone / pendingDownloads)]];
            
            if (pendingDownloads == 1)
            {
                putioController.transferInfo.stringValue = [NSString stringWithFormat:NSLocalizedString(@"HELPER_PENDING_TRANSFERS_SINGULAR", nil), completedDownloads];
            }
            else
            {
                putioController.transferInfo.stringValue = [NSString stringWithFormat:NSLocalizedString(@"HELPER_PENDING_TRANSFERS_PURAL", nil), pendingDownloads, completedDownloads];
            }
        }
    }
    failure:^(NSError *error)
    {
        putioController.userInfo.stringValue = NSLocalizedString(@"HELPER_TRANSFERS_FAILED", nil);
    }];
}


- (void)handleURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{
    NSString *url = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    
    if ([url hasPrefix:@"magnet:"])
    {
        [self addMagnet:url];
    }
    else if ([url hasPrefix:@"putio:"])
    {
        [self saveAccessToken:url];
    }
}


- (void)addMagnet:(NSString *)magnetURL
{
    [closeTimer invalidate];
    
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"dn=([^&]{5,})" options:0 error:&error];
    NSArray *matches = [regex matchesInString:magnetURL options:0 range:NSMakeRange(0, [magnetURL length])];
    NSString *displayName;
    
    if ([matches count] > 0)
    {
        displayName = [[magnetURL substringWithRange:[[matches objectAtIndex:0] rangeAtIndex:1]] displayNameString];
    }
    else
    {
        displayName = magnetURL;
    }
    
    putioController.message.stringValue = [NSString stringWithFormat:NSLocalizedString(@"HELPER_MAGNET_ADDING", nil), displayName];
    [putioController.activityIndicator startAnimation:nil];
    
    [self.putioAPI requestTorrentOrMagnetURLAtPath:magnetURL :^(id userInfoObject)
     {
         if ([[NSUserDefaults standardUserDefaults] boolForKey:@"close.magnet"])
         {
             putioController.message.stringValue = NSLocalizedString(@"HELPER_MAGNET_ADDED_CLOSING", nil);
             closeTimer = [NSTimer scheduledTimerWithTimeInterval:5.0  target:[NSApplication sharedApplication] selector:@selector(terminate:) userInfo:nil repeats:NO];
         }
         else
         {
             putioController.message.stringValue = NSLocalizedString(@"HELPER_MAGNET_ADDED", nil);
         }
         
         [self updateUserInfo];
         [putioController.activityIndicator stopAnimation:nil];
     }
     addFailure:^
     {
         putioController.message.stringValue = NSLocalizedString(@"HELPER_MAGNET_ERROR", nil);
         [putioController.activityIndicator stopAnimation:nil];
     }
                                    networkFailure:^(NSError *error)
     {
         // Put.io returns HTTP 400 if you're adding an URL that's already in the queue...
         // ... and thereby causing AFNetworking to throw a network error.
         putioController.message.stringValue = NSLocalizedString(@"HELPER_MAGNET_DUPLICATE", nil);
         [putioController.activityIndicator stopAnimation:nil];
     }];
}


- (void)uploadTorrent:(NSString*)filePath
{
    [closeTimer invalidate];
    
    NSString *fileName = [filePath lastPathComponent];
    putioController.message.stringValue = [NSString stringWithFormat: NSLocalizedString(@"HELPER_TORRENT_UPLOADING", nil), [fileName displayNameString]];
    [putioController.activityIndicator startAnimation:nil];
    
    [self.putioAPI uploadFile:filePath :^(id userInfoObject)
     {
         if ([[NSUserDefaults standardUserDefaults] boolForKey:@"close.torrent"])
         {
             putioController.message.stringValue = NSLocalizedString(@"HELPER_TORRENT_ADDED_CLOSING", nil);
             closeTimer = [NSTimer scheduledTimerWithTimeInterval:5.0  target:[NSApplication sharedApplication] selector:@selector(terminate:) userInfo:nil repeats:NO];
         }
         else
         {
             putioController.message.stringValue = NSLocalizedString(@"HELPER_TORRENT_ADDED", nil);
         }
         
         [self updateUserInfo];
         [putioController.activityIndicator stopAnimation:nil];
     }
     addFailure:^
     {
         putioController.message.stringValue = NSLocalizedString(@"HELPER_MAGNET_ERROR", nil);
         [putioController.activityIndicator stopAnimation:nil];
     }
     networkFailure:^(NSError *error)
     {
         // Put.io returns HTTP 400 if you're adding an URL that's already in the queue...
         // ... and thereby causing AFNetworking to throw a network error.
         putioController.message.stringValue = NSLocalizedString(@"HELPER_TORRENT_DUPLICATE", nil);
         [putioController.activityIndicator stopAnimation:nil];
     }];
}


- (void)checkForUpdates
{
    NSURL *url = [NSURL URLWithString:@"https://raw.github.com/nicoSWD/put.io-adder/master/put.io%20adder/put.io%20adder-Info.plist"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    
    // GitHub doesn't send the correct x-plist content-type header.
    [AFPropertyListRequestOperation addAcceptableContentTypes:[NSSet setWithObject:@"text/plain"]];
    AFPropertyListRequestOperation *operation = [AFPropertyListRequestOperation propertyListRequestOperationWithRequest:request
    success:^(NSURLRequest *request, NSHTTPURLResponse *response, id propertyList)
     {
         NSString *latestVersion = [propertyList valueForKey:@"CFBundleShortVersionString"];
         NSString *currentVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
         
         if (![latestVersion isEqualToString:currentVersion])
         {
             [closeTimer invalidate];
             
             NSAlert *alert = [[NSAlert alloc] init];
             [alert setAlertStyle:NSWarningAlertStyle];
             [alert addButtonWithTitle:NSLocalizedString(@"HELPER_OKAY", nil)];
             [alert addButtonWithTitle:NSLocalizedString(@"HELPER_CANCEL", nil)];
             [alert setMessageText:NSLocalizedString(@"HELPER_NEW_VERSION_TITLE", nil)];
             [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"HELPER_NEW_VERSION_BODY", nil), latestVersion]];
             [alert setShowsSuppressionButton:YES];
             
             if ([alert runModal] == NSAlertFirstButtonReturn)
             {
                 [self.putioController openGithub:nil];
             }
             
             if ([[alert suppressionButton] state] == NSOnState)
             {
                 NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                 [defaults setBool:NO forKey:@"checkupdate"];
                 [defaults synchronize];
             }
         }
     }
     failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id propertyList)
     {
         NSLog(@"Error: %@", error);
     }];
    
    [operation start];
}


- (void)saveAccessToken:(NSString *)url
{
    NSError *error = nil;
    NSString *pattern = @"^putio://callback#access_token=(.*)";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    NSArray *matches = [regex matchesInString:url options:0 range:NSMakeRange(0, [url length])];
    
    PutioHelper *helper = [PutioHelper sharedHelper];
    PutioMainController *controller = self.putioController;

    if ([matches count] > 0)
    {
        NSString *token = [url substringWithRange:[[matches objectAtIndex:0] rangeAtIndex:1]];
        
        if ([SSKeychain setPassword:token forService:@"put.io adder" account:@"711"])
        {
            controller.message.stringValue = @"Authenticated and ready to go!";
            helper.putioAPI.apiToken = token;
            [helper updateUserInfo];
            
            [controller.toggleShowTransfers setEnabled:YES];
            [controller.window orderFront:self];
        }
        else
        {
            controller.message.stringValue = @"Error saving token to KeyChain!";
        }
    }
    else
    {
        controller.userInfo.stringValue = @"ERROR: Failed to get access token";
    }
}


/**
 * transformedValue method by "Parag Bafna", from: http://stackoverflow.com/questions/7846495/
 *
 **/
- (NSString*)transformedValue:(id)value
{
    double convertedValue = [value doubleValue];
    int multiplyFactor = 0;
    
    NSArray *tokens = [NSArray arrayWithObjects:@"bytes",@"KiB",@"MiB",@"GiB",@"TiB",nil];
    
    while (convertedValue > 1024)
    {
        convertedValue /= 1024;
        multiplyFactor++;
    }
    
    return [NSString stringWithFormat:@"%4.2f %@", convertedValue, [tokens objectAtIndex:multiplyFactor]];
}

@end