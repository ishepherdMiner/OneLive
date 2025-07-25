//
//  CameraCapture.h
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <libavcodec/avcodec.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CameraCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate,AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, assign) AVCodecContext *videoCodecContext;
@property (nonatomic, assign) AVCodecContext *audioCodecContext;

// 全局访问点（类方法）
+ (instancetype)sharedInstance;

- (void)startCaptureWithParentView:(UIView *)view;
- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
