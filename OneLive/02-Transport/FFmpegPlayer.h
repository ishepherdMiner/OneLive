//
//  FFmpegPlayer.h
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFmpegPlayer : NSObject

- (instancetype)initWithView:(UIView *)view;
- (void)play;

@end

NS_ASSUME_NONNULL_END
