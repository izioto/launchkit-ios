//
//  LKAnalytics.m
//  Pods
//
//  Created by Rizwan Sattar on 8/13/15.
//
//

#import "LKAnalytics.h"

#import "LKLog.h"

static NSUInteger const VISITED_VIEW_CONTROLLERS_BUFFER_SIZE = 50;
static NSUInteger const RECORDED_TAPS_BUFFER_SIZE = 200;

@interface LKAnalytics () <UIGestureRecognizerDelegate>

// TODO(Riz): We don't really need this, just need it for getting serverTimeOffset
@property (strong, nonatomic) LKAPIClient *apiClient;

// Tracking the app's UI
@property (assign, nonatomic) BOOL shouldReportScreens;
@property (strong, nonatomic) NSTimer *currentViewControllerInspectionTimer;
@property (strong, nonatomic) NSString *currentViewControllerClassName;
@property (strong, nonatomic) NSDate *currentViewControllerStartTimestamp;
@property (strong, nonatomic) NSMutableArray *viewControllersVisited;

// Detecting taps
@property (assign, nonatomic) BOOL shouldReportTaps;
@property (strong, nonatomic) UITapGestureRecognizer *tapRecognizer;
@property (strong, nonatomic) NSMutableArray *recordedTaps;

@end

@implementation LKAnalytics

- (instancetype)initWithAPIClient:(LKAPIClient *)apiClient screenReporting:(BOOL)shouldReportScreens tapReportingEnabled:(BOOL)shouldReportTaps
{
    self = [super init];
    if (self) {
        self.apiClient = apiClient;
        self.shouldReportScreens = shouldReportScreens;
        self.shouldReportTaps = shouldReportTaps;
        self.viewControllersVisited = [NSMutableArray arrayWithCapacity:VISITED_VIEW_CONTROLLERS_BUFFER_SIZE];
        self.recordedTaps = [NSMutableArray arrayWithCapacity:RECORDED_TAPS_BUFFER_SIZE];
    }
    return self;
}

- (void)dealloc
{
    [self destroyListeners];
    [self stopDetectingTapsOnWindow];
}

- (NSDictionary *)trackableProperties
{
    NSMutableDictionary *propertiesToInclude = [NSMutableDictionary dictionaryWithCapacity:2];
    if (self.viewControllersVisited.count) {
        propertiesToInclude[@"screens"] = [self.viewControllersVisited copy];
    }
    if (self.recordedTaps.count) {
        propertiesToInclude[@"taps"] = [self.recordedTaps copy];
    }
    return propertiesToInclude;
}


- (void)clearTrackableProperties
{
    [self.viewControllersVisited removeAllObjects];
    [self.recordedTaps removeAllObjects];
}

- (void) updateReportingScreens:(BOOL)shouldReport
{
    if (self.shouldReportScreens == shouldReport) {
        return;
    }

    UIApplicationState state = [UIApplication sharedApplication].applicationState;

    self.shouldReportScreens = shouldReport;
    if (self.shouldReportScreens) {
        if (state == UIApplicationStateActive) {
            [self restartInspectingCurrentViewController];
        }
    } else {
        [self stopInspectingCurrentViewController];
        // Clear out our current visitation
        [self markEndOfVisitationForCurrentViewController];
    }

    if (self.verboseLogging) {
        LKLog(@"Report Screens turned %@ via remote command", (self.shouldReportScreens ? @"on" : @"off"));
    }
}

- (void) updateReportingTaps:(BOOL)shouldReport
{
    if (self.shouldReportTaps == shouldReport) {
        return;
    }

    UIApplicationState state = [UIApplication sharedApplication].applicationState;

    self.shouldReportTaps = shouldReport;
    if (self.shouldReportTaps) {
        if (state == UIApplicationStateActive) {
            [self startDetectingTapsOnWindow];
        }
    } else {
        [self stopDetectingTapsOnWindow];
    }

    if (self.verboseLogging) {
        LKLog(@"Report Taps turned %@ via remote command", (self.shouldReportTaps ? @"on" : @"off"));
    }
}

#pragma mark - Screen Detection

- (void)restartInspectingCurrentViewController
{
    [self stopInspectingCurrentViewController];
    [self inspectCurrentViewController];
    self.currentViewControllerInspectionTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                                 target:self
                                                                               selector:@selector(inspectCurrentViewController)
                                                                               userInfo:nil
                                                                                repeats:YES];
}

- (void)stopInspectingCurrentViewController
{
    if (self.currentViewControllerInspectionTimer.isValid) {
        [self.currentViewControllerInspectionTimer invalidate];
    }
    self.currentViewControllerInspectionTimer = nil;
}

- (void)inspectCurrentViewController
{
    UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    UIViewController *currentViewController = [self presentedViewControllerInViewController:rootViewController];
    NSString *className = NSStringFromClass([currentViewController class]);
    if (![className isEqualToString:self.currentViewControllerClassName]) {
        [self markEndOfVisitationForCurrentViewController];
        self.currentViewControllerClassName = className;
        self.currentViewControllerStartTimestamp = [NSDate date]; // We'll apply the serverTimeOffset only when recording
        LKLog(@"Current View Controller: %@", self.currentViewControllerClassName);
    }
}

- (void)markEndOfVisitationForCurrentViewController
{
    if (self.currentViewControllerClassName.length && self.currentViewControllerStartTimestamp) {
        NSInteger numToBeOverMax = (self.viewControllersVisited.count+1)-VISITED_VIEW_CONTROLLERS_BUFFER_SIZE;
        if (numToBeOverMax > 0) {
            [self.viewControllersVisited removeObjectsInRange:NSMakeRange(0, numToBeOverMax)];
        }
        // Save in a format that we can easily send up to server
        NSDate *now = [NSDate date];
        [self.viewControllersVisited addObject:@{@"name" : self.currentViewControllerClassName,
                                                 @"start" : @(self.currentViewControllerStartTimestamp.timeIntervalSince1970+self.apiClient.serverTimeOffset),
                                                 @"end" : @(now.timeIntervalSince1970+self.apiClient.serverTimeOffset)}];
        NSTimeInterval duration = [now timeIntervalSinceDate:self.currentViewControllerStartTimestamp];
        LKLog(@"%@ seen for about %.0fs", self.currentViewControllerClassName, duration);
        self.currentViewControllerClassName = nil;
        self.currentViewControllerStartTimestamp = nil;
    }
}


- (UIViewController *)presentedViewControllerInViewController:(UIViewController *)viewController
{
    if (viewController.presentedViewController) {

        return [self presentedViewControllerInViewController:viewController.presentedViewController];

    } else if ([viewController isKindOfClass:[UITabBarController class]]) {

        UITabBarController *tabBarController = (UITabBarController *)viewController;
        if (tabBarController.selectedViewController) {
            return [self presentedViewControllerInViewController:tabBarController.selectedViewController];
        } else {
            return tabBarController;
        }
        return [self presentedViewControllerInViewController:tabBarController.selectedViewController];

    } else if ([viewController isKindOfClass:[UINavigationController class]]) {

        UINavigationController *navController = (UINavigationController *)viewController;
        if (navController.topViewController) {
            return [self presentedViewControllerInViewController:navController.topViewController];
        }
    } else if ([viewController isKindOfClass:[UISplitViewController class]]) {

        UISplitViewController *splitViewController = (UISplitViewController *)viewController;

        BOOL returnSingleViewController = (splitViewController.viewControllers.count == 1);
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
        if ([splitViewController respondsToSelector:@selector(displayMode)]) {
            if (splitViewController.displayMode == UISplitViewControllerDisplayModePrimaryHidden) {
                returnSingleViewController = YES;
            }
        }
#endif
        if (returnSingleViewController) {
            // One VC is collapsed
            return [self presentedViewControllerInViewController:splitViewController.viewControllers.lastObject];
        } else {
            // iOS 7
            // TODO(Riz): Perhaps on iPad portrait, ask split view's delegate whether the primary vc
            // should be hidden
            return splitViewController;
        }
    }
    // Nothing to dive into, just return the view controller passed in
    return viewController;
}


#pragma mark - Detecting Taps

- (void)startDetectingTapsOnWindow
{
    if (!self.tapRecognizer) {
        self.tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleWindowTap:)];
        self.tapRecognizer.cancelsTouchesInView = NO;
        self.tapRecognizer.delegate = self;
    }
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    [window addGestureRecognizer:self.tapRecognizer];
}

- (void)stopDetectingTapsOnWindow
{
    if (self.tapRecognizer.view) {
        [self.tapRecognizer.view removeGestureRecognizer:self.tapRecognizer];
    }
    self.tapRecognizer.delegate = nil;
    self.tapRecognizer = nil;
}

- (void)handleWindowTap:(UITapGestureRecognizer *)recognizer
{
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        CGPoint touchPoint = [recognizer locationInView:nil];
        CGRect frame = recognizer.view.bounds;

        UIWindow *window = [UIApplication sharedApplication].keyWindow;
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        UIInterfaceOrientation orientation = window.rootViewController.interfaceOrientation;
        BOOL isLandscape = UIInterfaceOrientationIsLandscape(orientation);
#pragma GCC diagnostic pop

        if (![UIViewController instancesRespondToSelector:@selector(traitCollection)]) {
            // We have to transform the rect ourselves for landscape
            if (orientation != UIInterfaceOrientationPortrait) {
                double angle = [LKAnalytics angleForInterfaceOrientation:orientation];
                CGAffineTransform rotationTransform = CGAffineTransformMakeRotation((float)angle);
                frame = CGRectApplyAffineTransform(frame, rotationTransform);
                frame.origin = CGPointZero;

                if (isLandscape) {
                    CGFloat tmp = touchPoint.x;
                    touchPoint.x = touchPoint.y;
                    touchPoint.y = tmp;
                    if (orientation == UIInterfaceOrientationLandscapeLeft) {
                        touchPoint.x = CGRectGetWidth(frame)-touchPoint.x;
                    } else if (orientation == UIInterfaceOrientationLandscapeRight) {
                        touchPoint.y = CGRectGetHeight(frame)-touchPoint.y;
                    }
                } else if (orientation == UIInterfaceOrientationPortraitUpsideDown) {
                    touchPoint.x = CGRectGetWidth(frame)-touchPoint.x;
                    touchPoint.y = CGRectGetHeight(frame)-touchPoint.y;
                }
            }
        } else {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
            if ([window.screen respondsToSelector:@selector(fixedCoordinateSpace)]) {
                touchPoint = [window convertPoint:touchPoint fromCoordinateSpace:window.screen.fixedCoordinateSpace];
            }
#endif
        }
        if (self.verboseLogging) {
            LKLog(@"Tapped %@ within %@", NSStringFromCGPoint(touchPoint), NSStringFromCGRect(frame));
        }
        NSInteger numToBeOverMax = (self.recordedTaps.count+1)-RECORDED_TAPS_BUFFER_SIZE;
        if (numToBeOverMax > 0) {
            [self.recordedTaps removeObjectsInRange:NSMakeRange(0, numToBeOverMax)];
        }
        [self.recordedTaps addObject:@{@"x" : @(touchPoint.x),
                                       @"y" : @(touchPoint.y),
                                       @"time" : @([NSDate date].timeIntervalSince1970 + self.apiClient.serverTimeOffset),
                                       @"orient" : (isLandscape ? @"l" : @"p")}];

    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

#pragma mark - Listening to system/application events


- (void)createListeners
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    // App Lifecycle events
    [center addObserver:self
               selector:@selector(applicationWillTerminate:)
                   name:UIApplicationWillTerminateNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    /*
     [center addObserver:self
     selector:@selector(applicationWillEnterForeground:)
     name:UIApplicationWillEnterForegroundNotification
     object:nil];
     */

    [center addObserver:self
               selector:@selector(applicationDidEndIgnoringInteractionEvents:)
                   name:@"_UIApplicationDidEndIgnoringInteractionEventsNotification"
                 object:nil];
    [center addObserver:self
               selector:@selector(navigationControllerDidShowViewControllerNotification:)
                   name:@"UINavigationControllerDidShowViewControllerNotification"
                 object:nil];
}


- (void)destroyListeners
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Application Lifecycle Events

- (void)applicationWillTerminate:(NSNotification *)notification
{
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    [self stopInspectingCurrentViewController];
    // Clear out our current visitation
    [self markEndOfVisitationForCurrentViewController];
    [self stopDetectingTapsOnWindow];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    if (self.shouldReportScreens) {
        [self restartInspectingCurrentViewController];
    }
    if (!self.tapRecognizer && self.shouldReportTaps) {
        [self startDetectingTapsOnWindow];
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
}

// Called usually after a modal presentation animation ends
- (void)applicationDidEndIgnoringInteractionEvents:(NSNotification *)notification
{
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    if (state == UIApplicationStateActive && self.shouldReportScreens) {
        [self restartInspectingCurrentViewController];
    }
}

- (void)navigationControllerDidShowViewControllerNotification:(NSNotification *)notification
{
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    if (state == UIApplicationStateActive && self.shouldReportScreens) {
        [self restartInspectingCurrentViewController];
    }
}


#pragma mark - Convenience Methods

// Thanks, Mixpanel
+ (double)angleForInterfaceOrientation:(UIInterfaceOrientation)orientation
{
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return -M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
            return M_PI_2;
        case UIInterfaceOrientationPortraitUpsideDown:
            return M_PI;
        default:
            return 0.0;
    }
}

- (CGRect)frameFixedForOrientation:(UIInterfaceOrientation)interfaceOrientation fromFrame:(CGRect)sourceFrame
{
    // Thanks to Mixpanel here...
    CGRect transformedFrame;
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 80000
    // Guaranteed running iOS 8 and above (which fixes window coordinates for orientation)
    transformedFrame = sourceFrame;
#elif __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
    // iOS 8 is possible, but could be running lower, so check for iOS 8
    if ([[UIViewController class] instancesRespondToSelector:@selector(viewWillTransitionToSize:withTransitionCoordinator:)]) {
        transformedFrame = sourceFrame;
    } else {
        double angle = [LKAnalytics angleForInterfaceOrientation:interfaceOrientation];
        transformedFrame = CGRectApplyAffineTransform(sourceFrame, CGAffineTransformMakeRotation((float)angle));
    }
#else
    // Guaranteed running iOS 7 and below
    double angle = [self angleForInterfaceOrientation:[self interfaceOrientation]];
    transformedFrame = CGRectApplyAffineTransform(sourceFrame, CGAffineTransformMakeRotation((float)angle));
#endif
    return transformedFrame;
}

@end