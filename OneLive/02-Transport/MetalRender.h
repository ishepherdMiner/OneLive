//
//  MetalRender.h
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MetalRender : NSObject

- (instancetype)initWithView:(UIView *)view;
- (void)renderRGBAData:(uint8_t *)rgbaData width:(NSUInteger)width height:(NSUInteger)height;

@end

NS_ASSUME_NONNULL_END
