//
//  LaunchKitShared.h
//  LaunchKit
//
//  Created by Rizwan Sattar on 6/19/15.
//
//

#ifndef LaunchKitShared_h
#define LaunchKitShared_h

#import <UIKit/UIKit.h>

#import "LKViewController.h"

#define LAUNCHKIT_VERSION @"0.2.0"

#pragma mark - LKConfig Convenience Functions

extern BOOL LKConfigBool(NSString *__nonnull key, BOOL defaultValue);
extern NSInteger LKConfigInteger(NSString *__nonnull key, NSInteger defaultValue);
extern double LKConfigDouble(NSString *__nonnull key, double defaultValue);
extern NSString * __nullable LKConfigString(NSString *__nonnull key, NSString *__nullable defaultValue);

#pragma mark - Remote UI
typedef void (^LKRemoteUILoadHandler)(LKViewController *__nullable viewController, NSError *__nullable error);
typedef void (^LKRemoteUIDismissalHandler)(LKViewControllerFlowResult flowResult);

#endif