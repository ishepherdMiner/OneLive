//
//  FFmpegPlayer.m
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import "FFmpegPlayer.h"
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libavutil/imgutils.h>
#import <libavutil/avutil.h>
#import <libavutil/frame.h>
#import <libswscale/swscale.h>
#import "MetalRender.h"

@interface FFmpegPlayer ()

@property (nonatomic,weak) UIView *view;

@end

@implementation FFmpegPlayer

- (instancetype)initWithView:(UIView *)view {
    if (self = [super init]) {
        _view = view;
    }
    return self;
}

- (void)play {
    // 读取本地MP4文件并打开流
    AVFormatContext *formatContext = avformat_alloc_context();
    NSString *filePath = [NSBundle.mainBundle URLForResource:@"input" withExtension:@"mp4"].path;

    // 打开文件
    if (avformat_open_input(&formatContext, [filePath UTF8String], NULL, NULL) != 0) {
        NSLog(@"文件打开失败");
        return;
    }

    // 获取流信息
    if (avformat_find_stream_info(formatContext, NULL) < 0) {
        NSLog(@"无法获取流信息");
        return;
    }

    // 查找视频流和音频流
    int videoStreamIndex = -1;
    int audioStreamIndex = -1;
    for (int i = 0; i < formatContext->nb_streams; i++) {
        if (formatContext->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            videoStreamIndex = i;
        } else if (formatContext->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audioStreamIndex = i;
        }
    }
    
    // 初始化视频解码器
    
    /// 获取视频流的编解码参数
    /// 创建解码器上下文
    /// 打开解码器
    AVCodecParameters *videoCodecParams = formatContext->streams[videoStreamIndex]->codecpar;
    const AVCodec *videoCodec = avcodec_find_decoder(videoCodecParams->codec_id);
    AVCodecContext *videoCodecContext = avcodec_alloc_context3(videoCodec);
    avcodec_parameters_to_context(videoCodecContext, videoCodecParams);

    if (avcodec_open2(videoCodecContext, videoCodec, NULL) < 0) {
        NSLog(@"视频解码器打开失败");
        return;
    }
    
    // 解码视频帧并渲染
    /// ​​循环读取帧​​：使用 av_read_frame 逐帧读取数据包
    /// ​​解码为YUV帧​​：将数据包发送到解码器获取原始帧
    /// ​​转换为RGB​​：使用 sws_scale 将YUV转换为RGB格式（iOS渲染需RGBA）
    /// ​​OpenGL ES/Metal渲染​​：将RGB数据传递给GPU渲染
    AVPacket packet;
    AVFrame *frame = av_frame_alloc();
    struct SwsContext *swsContext = sws_getContext(
        videoCodecContext->width, videoCodecContext->height, videoCodecContext->pix_fmt,
        videoCodecContext->width, videoCodecContext->height, AV_PIX_FMT_RGBA,
        SWS_BILINEAR, NULL, NULL, NULL
    );

    while (av_read_frame(formatContext, &packet) >= 0) {
        if (packet.stream_index == videoStreamIndex) {
            avcodec_send_packet(videoCodecContext, &packet);
            if (avcodec_receive_frame(videoCodecContext, frame) == 0) {
                // 转换为RGBA
                uint8_t *rgbaData[4];
                int rgbaLinesize[4];
                av_image_alloc(rgbaData, rgbaLinesize, frame->width, frame->height, AV_PIX_FMT_RGBA, 1);
                sws_scale(swsContext, (const uint8_t **)frame->data, frame->linesize, 0, frame->height, rgbaData, rgbaLinesize);
                
                // 渲染到屏幕（使用OpenGL ES）
                MetalRender *render = [[MetalRender alloc] initWithView:self.view];
                [render renderRGBAData:rgbaData width:frame->width height:frame->height];
                av_freep(&rgbaData[0]);
            }
        }
        av_packet_unref(&packet);
    }
}

@end
