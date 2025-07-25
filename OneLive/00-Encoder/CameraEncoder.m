//
//  CameraCapture.m
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import "CameraEncoder.h"
#import <libswscale/swscale.h>

@interface CameraEncoder ()

@property (nonatomic) struct SwsContext *swsContext;

@end

@implementation CameraEncoder

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static id instance;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)startCaptureWithParentView:(UIView *)view {
    // 1. 初始化AVCaptureSession
    _captureSession = [[AVCaptureSession alloc] init];
    _captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
    
    // 2. 获取摄像头设备
    AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:camera error:nil];
    
    // 3. 配置视频输出
    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    [output setSampleBufferDelegate:self queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
    output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    
    // 4. 添加输入/输出
    [_captureSession addInput:input];
    [_captureSession addOutput:output];
    
    AVCaptureVideoPreviewLayer *previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_captureSession];
    previewLayer.frame = view.bounds;
    previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;  // 填充模式
    [view.layer insertSublayer:previewLayer atIndex:0];
    
    // 5. 启动采集
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [self.captureSession startRunning];
    });
    
    [self setupFFmpegEncoder];
}

- (void)dealloc {
    NSLog(@"%s",__func__);
    [_captureSession stopRunning];
    _captureSession = nil;
        
    if (_ffmpegContext) {
        // avcodec_close(_ffmpegContext); // 关闭编码器
        avcodec_free_context(&_ffmpegContext);
    }
        
    if (_swsContext) {
        sws_freeContext(_swsContext);
    }
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 获取视频帧（CVPixelBuffer）
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // 转换为FFmpeg所需格式（YUV420P）
    AVFrame *frame = [self convertPixelBufferToFFmpegFrame:pixelBuffer];
    
    // 调用FFmpeg编码
    [self encodeFrameWithFFmpeg:frame];
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

- (AVFrame *)convertPixelBufferToFFmpegFrame:(CVPixelBufferRef)pixelBuffer {
    // 1. 创建AVFrame并分配内存
    AVFrame *frame = av_frame_alloc();
    frame->format = AV_PIX_FMT_YUV420P;
    frame->width = (int)CVPixelBufferGetWidth(pixelBuffer);
    frame->height = (int)CVPixelBufferGetHeight(pixelBuffer);
    av_frame_get_buffer(frame, 0);
    
    // 2. 获取BGRA数据
    uint8_t *src = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    int srcStride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    // 3. 执行转换
    uint8_t *dstData[4] = {frame->data[0], frame->data[1], frame->data[2], NULL};
    int dstLinesize[4] = {frame->linesize[0], frame->linesize[1], frame->linesize[2], 0};
    sws_scale(self.swsContext, (const uint8_t **)&src, &srcStride, 0, frame->height, dstData, dstLinesize);
    
    return frame;
}

- (void)encodeFrameWithFFmpeg:(AVFrame *)frame {
    AVPacket pkt;
    av_init_packet(&pkt);
    pkt.data = NULL;
    pkt.size = 0;
    
    // 1. 发送帧到编码器
    int ret = avcodec_send_frame(_ffmpegContext, frame);
    if (ret < 0) {
        NSLog(@"发送帧失败");
        return;
    }
    
    // 2. 接收编码后的数据包
    while (ret >= 0) {
        ret = avcodec_receive_packet(_ffmpegContext, &pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        
        // 3. 处理编码后的数据（写入文件/网络传输）
        NSData *encodedData = [NSData dataWithBytes:pkt.data length:pkt.size];
        [self saveToFile:encodedData]; // 自定义存储函数
        av_packet_unref(&pkt);
    }
    av_frame_free(&frame);
}

- (void)saveToFile:(NSData *)data {
    // 1. 获取Documents目录下的文件路径
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
    NSString *filePath = [documentsDirectory stringByAppendingPathComponent:@"output.mp4"]; // 文件名自定义
        
    // 2. 检查文件是否存在，不存在则创建
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:filePath]) {
        [fileManager createFileAtPath:filePath contents:nil attributes:nil];
    }
        
    // 3. 追加数据到文件
    @try {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
        [fileHandle seekToEndOfFile]; // 移动指针到文件末尾
        [fileHandle writeData:data];   // 追加写入数据
        [fileHandle closeFile];        // 关闭文件句柄
    } @catch (NSException *exception) {
        NSLog(@"写入文件失败: %@", exception.reason);
    }
}

- (void)setupFFmpegEncoder {
    // 1. 查找H.264编码器
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_H264);
    
    // 2. 创建编码上下文
    _ffmpegContext = avcodec_alloc_context3(codec);
    _ffmpegContext->width = 1280;      // 视频宽度
    _ffmpegContext->height = 720;      // 视频高度
    _ffmpegContext->pix_fmt = AV_PIX_FMT_YUV420P; // FFmpeg输入格式
    _ffmpegContext->time_base = (AVRational){1, 30}; // 帧率（30FPS）
    _ffmpegContext->bit_rate = 4000000; // 码率（4Mbps）
    
    // 3. 打开编码器
    if (avcodec_open2(_ffmpegContext, codec, NULL) < 0) {
        NSLog(@"FFmpeg编码器初始化失败");
    }
    
    self.swsContext = sws_getContext(1280, 720, AV_PIX_FMT_BGRA,_ffmpegContext->width, _ffmpegContext->height, AV_PIX_FMT_YUV420P,
        SWS_BILINEAR, NULL, NULL, NULL
    );
}

@end
