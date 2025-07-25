//
//  MetalRender.m
//  OneLive
//
//  Created by WangDL on 2025/7/24.
//

#import "MetalRender.h"

@interface MetalRender()

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;

@end

@implementation MetalRender

- (instancetype)initWithView:(UIView *)view {
    self = [super init];
    if (self) {
        _device = MTLCreateSystemDefaultDevice();
        _commandQueue = [_device newCommandQueue];
        
        // 设置 Metal 图层
        _metalLayer = [CAMetalLayer layer];
        _metalLayer.device = _device;
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _metalLayer.frame = view.bounds;
        [view.layer addSublayer:_metalLayer];
        
        // 初始化渲染管线
        _pipelineState = [self setupPipelineStateWithDevice:_device];
    }
    return self;
}

- (void)renderRGBAData:(uint8_t *)rgbaData width:(NSUInteger)width height:(NSUInteger)height {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLTexture> texture = [self createTextureFromRGBA:rgbaData width:width height:height device:device];
        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        if (!drawable) return;
        
        // 渲染指令编码（略，见上文步骤4）
    }
}

- (id<MTLRenderPipelineState>)setupPipelineStateWithDevice:(id<MTLDevice>)device {
    id<MTLLibrary> library = [device newDefaultLibrary];
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragmentShader"];
    
    MTLRenderPipelineDescriptor *pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDesc.vertexFunction = vertexFunc;
    pipelineDesc.fragmentFunction = fragmentFunc;
    pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; // 与图层格式一致
    
    return [device newRenderPipelineStateWithDescriptor:pipelineDesc error:nil];
}

- (id<MTLTexture>)createTextureFromRGBA:(uint8_t*)rgbaData
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                 device:(id<MTLDevice>)device {
    MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO]; // 无缩略图
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDesc];
    
    // 复制数据到纹理
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region
               mipmapLevel:0
                 withBytes:rgbaData
               bytesPerRow:width * 4]; // RGBA 每像素占 4 字节
    return texture;
}

@end
