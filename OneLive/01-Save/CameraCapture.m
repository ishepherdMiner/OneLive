//
//  CameraCapture.m
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import "CameraCapture.h"
#import <libswscale/swscale.h>
#import <libavformat/avformat.h>
#import <libavutil/channel_layout.h>
#import <libswresample/swresample.h>
#import <libavutil/samplefmt.h>
#import <AVFAudio/AVFAudio.h>
#import <libavutil/audio_fifo.h>
#import <libavutil/opt.h>

static int avcodec_get_audio_config(AVCodecContext *ctx, uint8_t *asc, int asc_size) {
    if (ctx->codec_id != AV_CODEC_ID_AAC) return -1;
    
    // 构建AudioSpecificConfig (AAC-LC)
    // 对于48000Hz采样率，采样率索引 = 3 (参考ISO/IEC 14496-3标准)
    asc[0] = 0x10 | ((ctx->profile + 1) << 3) | (ctx->ch_layout.nb_channels >> 3);
    asc[1] = ((ctx->ch_layout.nb_channels & 0x7) << 5) | (3 << 2); // 3=48000Hz索引
    
    return 2;
}

@interface CameraCapture ()

@property (nonatomic) struct SwsContext *swsContext;
@property (nonatomic) AVFormatContext *formatContext;
@property (nonatomic) AVStream *videoStream;
@property (nonatomic) AVStream *audioStream;
@property (nonatomic,assign) int64_t frameCount;
@property (nonatomic,assign) int64_t audioPts;
@property (nonatomic,assign) BOOL isInitVideoEncoder;
@property (nonatomic,assign) BOOL isPrintVoiceFrameInfo;
@property (nonatomic) AVAudioFifo *audioFifo;
@property (nonatomic,assign) BOOL isStop;

@end

@implementation CameraCapture

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static id instance;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (connection.audioChannels.count > 0) {
       [self processAudioSampleBuffer:sampleBuffer];
    } else {
        [self processVideoSampleBuffer:sampleBuffer];
    }
}

- (void)getFrameInfo:(CMSampleBufferRef)sampleBuffer {
    CMAudioFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);
        
    // 打印关键参数
    NSLog(@"采样率: %.0f", asbd->mSampleRate);
    NSLog(@"声道数: %u", asbd->mChannelsPerFrame);
    NSLog(@"位深度: %u", asbd->mBitsPerChannel);
    NSLog(@"格式ID: %c%c%c%c",
          (char)(asbd->mFormatID >> 24),
          (char)(asbd->mFormatID >> 16),
          (char)(asbd->mFormatID >> 8),
          (char)(asbd->mFormatID));
}

- (void)processVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // 获取视频帧（CVPixelBuffer）
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if(!_isInitVideoEncoder) {
        // 动态获取宽高
        int width = (int)CVPixelBufferGetWidth(pixelBuffer);
        int height = (int)CVPixelBufferGetHeight(pixelBuffer);
        [self setupFFmpegEncoderWithWidth:width height:height];
        _isInitVideoEncoder = YES;
    }
    // 转换为FFmpeg所需格式（YUV420P）
    AVFrame *frame = [self convertPixelBufferToFFmpegFrame:pixelBuffer];
    // 调用FFmpeg编码
    [self encodeFrameWithFFmpeg:frame];
    av_frame_free(&frame);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // 获取PCM原始数据
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t totalLength;
    char *pcmData;
    CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &pcmData);
    
    // 计算采样数（iOS采集的样本数动态变化）
    CMItemCount sampleCount = CMSampleBufferGetNumSamples(sampleBuffer);
    if (!_isPrintVoiceFrameInfo) {
        [self getFrameInfo:sampleBuffer];
        _isPrintVoiceFrameInfo = YES;
    }
    
    // 验证原始音频流
    // NSString *outputPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"origin.pcm"];
    //    
    // FILE *pcmFile = fopen(outputPath.UTF8String, "ab");
    // fwrite(pcmData, 1, totalLength, pcmFile);
    // fclose(pcmFile);
    
    // 初始化重采样器（S16交错 → FLTP平面）
    SwrContext *swr = NULL;
    AVChannelLayout in_layout = AV_CHANNEL_LAYOUT_MONO;
    enum AVSampleFormat in_fmt = AV_SAMPLE_FMT_S16;
    
    int ret = swr_alloc_set_opts2(
        &swr,
        &_audioCodecContext->ch_layout, // 目标布局
        _audioCodecContext->sample_fmt,  // 目标格式（FLTP）
        _audioCodecContext->sample_rate, // 目标采样率
        &in_layout,                      // 输入布局
        in_fmt,                          // 输入格式（S16）
        44100,                           // 输入采样率
        0, NULL
    );
    if (ret < 0 || swr_init(swr) < 0) {
        NSLog(@"重采样器初始化失败");
        swr_free(&swr);
        return;
    }
    
    // 创建临时帧存储重采样结果
    AVFrame *tempFrame = av_frame_alloc();
    tempFrame->nb_samples = (int)sampleCount;
    tempFrame->format = _audioCodecContext->sample_fmt;
    av_channel_layout_copy(&tempFrame->ch_layout, &_audioCodecContext->ch_layout);
    av_frame_get_buffer(tempFrame, 0); // 分配缓冲区

    // 执行重采样（S16 → FLTP）
    const uint8_t *in_data[8] = { (uint8_t *)pcmData, NULL };
    ret = swr_convert(
        swr,
        tempFrame->data,          // 输出到临时帧
        tempFrame->nb_samples,
        in_data,
        (int)sampleCount
    );
    if (ret < 0) {
        NSLog(@"重采样失败: %s", av_err2str(ret));
        swr_free(&swr);
        av_frame_free(&tempFrame);
        return;
    }
    // 将重采样后的数据写入FIFO队列
    if (ret > 0) {
        av_audio_fifo_write(_audioFifo, (void**)tempFrame->data, ret);
    }
    
    // 从FIFO中读取1024样本并编码
    while (av_audio_fifo_size(_audioFifo) >= _audioCodecContext->frame_size) {
        AVFrame *encodeFrame = av_frame_alloc();
        encodeFrame->nb_samples = _audioCodecContext->frame_size; // AAC要求1024
        encodeFrame->format = _audioCodecContext->sample_fmt;
        av_channel_layout_copy(&encodeFrame->ch_layout, &_audioCodecContext->ch_layout);
        av_frame_get_buffer(encodeFrame, 0);

        // 从FIFO读取数据
        ret = av_audio_fifo_read(
            _audioFifo,
            (void **)encodeFrame->data,
            encodeFrame->nb_samples
        );
        if (ret < 0) break;

        // 设置PTS（按样本数计算）
        encodeFrame->pts = _audioPts;
        _audioPts += ret;
        [self encodeAudioFrame:encodeFrame];
        av_frame_free(&encodeFrame);
    }

    // 释放资源
    swr_free(&swr);
    av_frame_free(&tempFrame);
}

- (void)encodeAudioFrame:(AVFrame *)frame {
    if (frame == NULL || !_audioCodecContext) { return ; }
    
    AVPacket *pkt = av_packet_alloc();
    avcodec_send_frame(_audioCodecContext, frame);
    int ret = avcodec_receive_packet(_audioCodecContext, pkt);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF || ret < 0) {
        av_packet_unref(pkt);
        return;
    }
    // NSLog(@"输入帧 PTS: %lld, 输出 Packet PTS: %lld", frame->pts, pkt->pts);
    if (pkt->size > 0 || pkt->side_data_elems > 0) {
        pkt->stream_index = _audioStream->index;
        NSLog(@"音频 PTS: %lld, 样本数: %d", pkt->pts, frame->nb_samples);
        if (_formatContext && _formatContext->pb) {
            av_interleaved_write_frame(_formatContext,pkt);
        }
    }
    av_packet_unref(pkt);
}

- (AVFrame *)convertPixelBufferToFFmpegFrame:(CVPixelBufferRef)pixelBuffer {
    // 创建AVFrame并分配内存
    AVFrame *frame = av_frame_alloc();
    frame->format = AV_PIX_FMT_YUV420P;
    frame->width = (int)CVPixelBufferGetWidth(pixelBuffer);
    frame->height = (int)CVPixelBufferGetHeight(pixelBuffer);
    av_frame_get_buffer(frame, 0);
    
    // 获取BGRA数据
    uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    int srcStride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    // 执行转换
    uint8_t *dstData[4] = {frame->data[0], frame->data[1], frame->data[2], NULL};
    int dstLinesize[4] = {frame->linesize[0], frame->linesize[1], frame->linesize[2], 0};
    sws_scale(self.swsContext, (const uint8_t **)&src, &srcStride, 0, frame->height, dstData, dstLinesize);
    
    return frame;
}

- (void)encodeFrameWithFFmpeg:(AVFrame *)frame {
    if (_videoCodecContext == NULL) { return; }

    frame->pts = _frameCount++;
    AVPacket *pkt = av_packet_alloc();
    avcodec_send_frame(_videoCodecContext, frame);
    avcodec_receive_packet(_videoCodecContext, pkt);
    
    if (pkt->size > 0 || pkt->side_data_elems > 0) {
        av_packet_rescale_ts(pkt, _videoCodecContext->time_base, _videoStream->time_base);
        pkt->stream_index = _videoStream->index;
        NSLog(@"视频 PTS: %lld,DTS: %lld", pkt->pts,pkt->dts);
        av_interleaved_write_frame(_formatContext,pkt);
    }
    av_packet_unref(pkt);
}

#pragma mark - LifeCycle -

- (void)startCaptureWithParentView:(UIView *)view {
    // 初始化AVCaptureSession
    _captureSession = [[AVCaptureSession alloc] init];
    _captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
    
    // 获取摄像头设备
    AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:camera error:nil];
    
    // 添加音频输入
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:nil];
    
    // 配置视频输出
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    dispatch_queue_t videoQueue = dispatch_queue_create("video_queue", DISPATCH_QUEUE_SERIAL);
    [videoOutput setSampleBufferDelegate:self
                                   queue:videoQueue];
    videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    
    // 添加音频输出
    AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    dispatch_queue_t audioQueue = dispatch_queue_create("audio_queue", DISPATCH_QUEUE_SERIAL);
    [audioOutput setSampleBufferDelegate:self queue:audioQueue];
    
    // 添加输入/输出
    [self addInput:input];
    [self addInput:audioInput];
    [self addOutput:videoOutput];
    [self addOutput:audioOutput];
    
    // 视频画面旋转90度
    AVCaptureConnection *conn = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (conn.isVideoOrientationSupported) {
        conn.videoOrientation = AVCaptureVideoOrientationPortrait;
    }
    
    _audioPts = 0;
    _frameCount = 0;
    _isPrintVoiceFrameInfo = NO;
    _isInitVideoEncoder = NO;
    [self setupFFmpegFormatContextAndAudioEncoder];
    
    AVCaptureVideoPreviewLayer *previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_captureSession];
    previewLayer.frame = view.bounds;
    previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;  // 填充模式
    [view.layer insertSublayer:previewLayer atIndex:0];
    // 启动采集
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSLog(@"开始采集:10s结束");
        [self.captureSession startRunning];
    });
}

- (void)dealloc {
    NSLog(@"%s",__func__);

    [self _stopCapture]; // 确保统一释放
    if (_swsContext) sws_freeContext(_swsContext);
}


- (void)stopCapture {
    _isStop = YES;
    [_captureSession stopRunning];
    _captureSession = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _stopCapture];
    });
}

- (void)_stopCapture {
    if (!_isStop) return;
    [self flushAudioFifo];
    [self flushVideoEncoder];

    if (self.formatContext->priv_data) {
        av_write_trailer(self.formatContext);
    }
    
    if (_audioFifo) {
        av_audio_fifo_free(_audioFifo);
        _audioFifo = NULL;
    }
        
    // 释放资源
    if (_videoCodecContext) {
        avcodec_free_context(&_videoCodecContext);
    }
    if (_audioCodecContext) {
        avcodec_free_context(&_audioCodecContext);
    }
    
    if (_formatContext) {
        avformat_free_context(_formatContext);
    }
    NSLog(@"结束");
}

- (void)flushAudioFifo {
    const int frame_size = _audioCodecContext->frame_size;
    int remaining = av_audio_fifo_size(_audioFifo);
    
    while (remaining > 0) {
        int samples = MIN(remaining, frame_size);
        AVFrame *frame = av_frame_alloc();
        frame->nb_samples = samples;
        frame->format = _audioCodecContext->sample_fmt;
        av_channel_layout_copy(&frame->ch_layout, &_audioCodecContext->ch_layout);
        av_frame_get_buffer(frame, 0);
        
        av_audio_fifo_read(_audioFifo, (void **)frame->data, samples);
        
        // 设置正确的PTS
        frame->pts = _audioPts;
        _audioPts += samples;
        
        [self encodeAudioFrame:frame];
        av_frame_free(&frame);
        
        remaining = av_audio_fifo_size(_audioFifo);
    }
    [self flushAudioEncoder];
}

- (void)flushVideoEncoder {
    avcodec_send_frame(_videoCodecContext, NULL);
    AVPacket *pkt = av_packet_alloc();
    
    while (YES) {
        int ret = avcodec_receive_packet(_videoCodecContext, pkt);
        if (ret == AVERROR_EOF || ret < 0) {
            break;
        }
        
        if (pkt->size > 0 || pkt->side_data_elems > 0) {
            av_packet_rescale_ts(pkt, _videoCodecContext->time_base, _videoStream->time_base);
            pkt->stream_index = _videoStream->index;
            av_interleaved_write_frame(_formatContext, pkt);
        }
        av_packet_unref(pkt);
    }
    
    av_packet_free(&pkt);
}

// 添加编码器刷新方法
- (void)flushAudioEncoder {
    // 发送NULL帧刷新编码器
    avcodec_send_frame(_audioCodecContext, NULL);
    
    AVPacket *pkt = av_packet_alloc();
    // 接收所有剩余包
    while (YES) {
        int ret = avcodec_receive_packet(_audioCodecContext, pkt);
        if (ret == AVERROR_EOF || ret < 0) {
            break;
        }
        
        if (pkt->size > 0 || pkt->side_data_elems > 0) {
            pkt->stream_index = _audioStream->index;
            av_interleaved_write_frame(_formatContext, pkt);
        }
        av_packet_unref(pkt);
    }
    
    av_packet_free(&pkt);
}

- (void)setupFFmpegEncoderWithWidth:(int)width height:(int)height {
    // 初始化视频编码器
    [self generateVideoEnderWithWidth:width height:height];
    // 现在音频/视频流都已添加,写入文件头
    avformat_write_header(_formatContext,NULL);
    // 初始化视频转换上下文
    self.swsContext = sws_getContext(width, height, AV_PIX_FMT_BGRA,width, height, AV_PIX_FMT_YUV420P,
        SWS_BILINEAR, NULL, NULL, NULL
    );
}

- (void)generateVideoEnderWithWidth:(int)width height:(int)height {
    // 创建视频编码器（H264）
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_H264);
    _videoCodecContext = avcodec_alloc_context3(codec);
    _videoCodecContext->width = width;    // 视频宽度
    _videoCodecContext->height = height;  // 视频高度
    _videoCodecContext->pix_fmt = AV_PIX_FMT_YUV420P; // FFmpeg输入格式
    _videoCodecContext->time_base = (AVRational){1, 30}; // 帧率（30FPS）
    _videoCodecContext->bit_rate = 4000000; // 码率（4Mbps）,根据实际场景设置
    _videoCodecContext->color_range = AVCOL_RANGE_JPEG;
    _videoCodecContext->gop_size = 30; // 设置GOP和Profile
    // WebRTC => AV_PROFILE_H264_CONSTRAINED_BASELINE;
    _videoCodecContext->profile = AV_PROFILE_H264_MAIN;
    
    // 创建视频流并关联编码器
    _videoStream = avformat_new_stream(_formatContext, NULL);
    _videoStream->codecpar->width = width;
    _videoStream->codecpar->height = height;
    // MP4: {1,90000}
    // _videoStream->time_base = _videoCodecContext->time_base;
    avcodec_parameters_from_context(_videoStream->codecpar, _videoCodecContext);
    
    // 打开编码器
    if (avcodec_open2(_videoCodecContext, codec, NULL) < 0) {
        NSLog(@"初始化:H264视频编码器失败");
    }
    
    NSLog(@"视频流参数: width=%d, height=%d", _videoStream->codecpar->width, _videoStream->codecpar->height);
    
    NSString *outputPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"output.mp4"];
    
    /// 指定写入的文件
    avio_open(&_formatContext->pb, [outputPath UTF8String], AVIO_FLAG_WRITE);
}

- (void)generateAudioEncoder {
    // 添加音频编码器
    const AVCodec *audioCodec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    _audioCodecContext = avcodec_alloc_context3(audioCodec);
        
    // 配置音频参数
    _audioCodecContext->sample_rate = 44100;
    _audioCodecContext->profile = AV_PROFILE_AAC_LOW;
    _audioCodecContext->sample_fmt = AV_SAMPLE_FMT_FLTP; // AAC编码要求平面格式
    _audioCodecContext->bit_rate = 128000;
    _audioCodecContext->codec_type = AVMEDIA_TYPE_AUDIO;
    _audioCodecContext->time_base = (AVRational){1, _audioCodecContext->sample_rate};
    // 显式指定单声道布局
    av_channel_layout_from_mask(&_audioCodecContext->ch_layout, AV_CH_LAYOUT_MONO);
    // 验证声道数
    _audioCodecContext->ch_layout.nb_channels = 1;
    _audioCodecContext->frame_size = 1024;
    
    // 创建音频流
    _audioStream = avformat_new_stream(_formatContext, audioCodec);
    avcodec_parameters_from_context(_audioStream->codecpar, _audioCodecContext);
    // 确保流的时间基与编码器一致
    _audioStream->time_base = _audioCodecContext->time_base;
        
    // 打开音频编码器
    if (avcodec_open2(_audioCodecContext, audioCodec, NULL) < 0) {
        NSLog(@"初始化:AAC音频编码器失败");
    }
    
    // 初始化FIFO（AAC音频编码器要求1024）
    _audioFifo = av_audio_fifo_alloc(
        _audioCodecContext->sample_fmt,
        _audioCodecContext->ch_layout.nb_channels, // 声道数
        1024 * 20 // 缓存容量
    );
}

- (void)setupFFmpegFormatContextAndAudioEncoder {
    // 初始化封装格式上下文（MP4容器）
    avformat_alloc_output_context2(&_formatContext, NULL, "mp4", NULL);
    
    // 初始化音频编码器
    [self generateAudioEncoder];
}

#pragma mark - Utils -
- (void)addOutput:(AVCaptureOutput *)output {
    if ([_captureSession canAddOutput:output]) {
        [_captureSession addOutput:output];
    }
}

- (void)addInput:(AVCaptureInput *)input {
    if ([_captureSession canAddInput:input]) {
        [_captureSession addInput:input];
    }
}

@end
