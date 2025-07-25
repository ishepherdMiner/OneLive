//
//  ViewController.m
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import "ViewController.h"
#import "CameraEncoder.h"
#import "CameraCapture.h"

#import "FFmpegPlayer.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self saveToLocalDemo];
}

- (void)encoderDemo {
    [[CameraEncoder sharedInstance] startCaptureWithParentView:self.view];
}

- (void)saveToLocalDemo {
    [[CameraCapture sharedInstance] startCaptureWithParentView:self.view];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[CameraCapture sharedInstance] stopCapture];
    });
}


@end
