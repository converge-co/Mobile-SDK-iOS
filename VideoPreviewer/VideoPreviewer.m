//
//  VideoPreviewer.m
//  DJI
//
//  Copyright (c) 2013. All rights reserved.
//

#import "VideoPreviewer.h"
#import "DJIVTH264DecoderPublic.h"
#import "LB2AUDHackParser.h"
#import <DJISDK/DJISDK.h>

#define BEGIN_DISPATCH_QUEUE __weak VideoPreviewer* weakSelf = self; dispatch_async(_dispatchQueue, ^{ __strong VideoPreviewer* strongLocalSelf = weakSelf;
#define END_DISPATCH_QUEUE   });

@interface VideoPreviewer ()<DJIVTH264DecoderOutput, LB2AUDHackParserDelegate>

@property(nonatomic, strong) id<DJIVTH264DecoderProtocol> hwDecoder; //hardware decoder;

@property(nonatomic, assign) BOOL useHardware;
@property(nonatomic, assign) int decoderErrorCount;

@property(nonatomic, assign) CGSize frameSize;

@property(nonatomic, assign) int badFrameCounter;
@property(nonatomic, assign) BOOL canReset;

//Remove the redundant AUD for lb2
@property (nonatomic) BOOL isLB2;
@property (strong, nonatomic) LB2AUDHackParser* lb2Hack;

@end

@implementation VideoPreviewer

static VideoPreviewer* previewer = nil;
-(id)init
{
    self= [super init];
    
    _decodeThread = nil;
    _glView = nil;
    _delegate = nil;
    
    _dataQueue = [[DJILinkQueues alloc] initWithSize:10000];
    _videoExtractor = [[VideoFrameExtractor alloc] initExtractor];
    
    _dispatchQueue = dispatch_queue_create("video_previewer_async_queue", DISPATCH_QUEUE_SERIAL);
    
    for(int i = 0;i<RENDER_FRAME_NUMBER;i++){
        _renderYUVFrame[i] = NULL;
    }
    _renderFrameIndex = 0;
    _decodeFrameIndex = 0;
    
    self.useHardware = NO;
    self.isHardwareDecoding = NO;
    if (true) {
        //create hardware decoder
        self.hwDecoder = [DJIVTH264DecoderPublic createDecoderWithDataSource:DJIVTH264DecoderDataSourceNone];
        [self.hwDecoder setVTDecoderDelegate:self];
    }
    
    memset(&_status, 0, sizeof(VideoPreviewerStatus));
    _status.isInit = YES;
    
    //lb2 hack
    _lb2Hack = [[LB2AUDHackParser alloc] init];
    _lb2Hack.delegate = self;
    _isLB2 = NO;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeGround:) name:UIApplicationWillEnterForegroundNotification object:nil];
    return self;
}

-(void) appDidEnterBackground:(NSNotification*)notify
{
    [self enterBackground];
}

-(void) appWillEnterForeGround:(NSNotification *)notify
{
    [self enterForeground];
}

#pragma mark - public

+(VideoPreviewer*) instance
{
    //static dispatch_once_t predicate;
    if (nil == previewer){
        @synchronized(self) {
            if (nil == previewer) {
                previewer = [[VideoPreviewer alloc] init];
            }
        };
    }
    
    return previewer;
}

+ (void) removePreview{
    
    if (previewer != nil) {
        @synchronized(self) {
            if (nil != previewer) {
                
                [previewer clean];
                previewer = nil;
            }
        };
    }
}

-(void) setDecoderDataSource:(int)type
{
    if (type == kDJIDecoderDataSoureNone) {
        self.useHardware = NO;
        self.isLB2 = NO;
    }
    else if (type == kDJIDecoderDataSourceLightbridge2) {
        self.useHardware = NO;
        self.isLB2 = YES;
    }
    else {
        self.useHardware = YES;
        self.isLB2 = NO;
        [self.hwDecoder setDecoderDataSource:(DJIVTH264DecoderDataSource)type];
    }
}

- (BOOL) setDecoderWithProduct:(DJIBaseProduct*)product andDecoderType:(VideoPreviewerDecoderType)decoder {
    if (product == nil) {
        return NO;
    }
    
    NSString* stringName = product.model;
    
    if ([stringName isEqualToString:DJIAircraftModelNameUnknownAircraft]) {
        // determine if it is Lightbridge 2
        if ([product isKindOfClass:[DJIAircraft class]]) {
            DJIAircraft* aircraft = (DJIAircraft*)product;
            if (aircraft.camera == nil && aircraft.airLink && aircraft.airLink.lbAirLink && [aircraft.airLink.lbAirLink isSecondaryVideoOutputSupported]) {
                self.useHardware = NO;
                self.isLB2 = YES;
                return YES;
            }
        }
        
        return NO;
    }
    
    // Otherwise, the decoder depends on the camera
    DJICamera* camera = nil;
    if ([product isKindOfClass:[DJIAircraft class]]) {
        DJIAircraft* aircraft = (DJIAircraft*)product;
        camera = aircraft.camera;
    }
    else if ([product isKindOfClass:[DJIHandheld class]]) {
        DJIHandheld* handheld = (DJIHandheld*)product;
        camera = handheld.camera;
    }
    
    if (camera == nil) {
        return NO;
    }
    
    // if the decoder type is software decoder, we don't care about the camera type
    if (decoder == VideoPreviewerDecoderTypeSoftwareDecoder) {
        self.useHardware = NO;
        self.isLB2 = NO;
        
        return YES;
    }
    
    DJIVTH264DecoderDataSource dataSource = [VideoPreviewer getDataSourceWithCameraName:camera.displayName];
    if (dataSource == DJIVTH264DecoderDataSourceNone) { // The product does not support hardware decoding
        return NO;
    }
    
    self.useHardware = YES;
    self.isLB2 = NO;
    [self.hwDecoder setDecoderDataSource:dataSource];
    
    return YES;
}

+ (DJIVTH264DecoderDataSource) getDataSourceWithCameraName:(NSString*)name {
    if ([name isEqualToString:DJICameraDisplayNameX3] ||
        [name isEqualToString:DJICameraDisplayNameX5] ||
        [name isEqualToString:DJICameraDisplayNameX5R]) {
        return DJIVTH264DecoderDataSourceInspire;
    }
    else if ([name isEqualToString:DJICameraDisplayNamePhantom3ProfessionalCamera]) {
        return DJIVTH264DecoderDataSourcePhantom3Professional;
    }
    else if ([name isEqualToString:DJICameraDisplayNamePhantom3AdvancedCamera]) {
        return DJIVTH264DecoderDataSourcePhantom3Advanced;
    }
    else if ([name isEqualToString:DJICameraDisplayNamePhantom3StandardCamera]) {
        return DJIVTH264DecoderDataSourcePhantom3Standard;
    }
    
    return DJIVTH264DecoderDataSourceNone;
}


-(BOOL)setView:(UIView *)view
{
    if (view == nil) {
        [self unSetView];
    }
    else
    {
        BEGIN_DISPATCH_QUEUE
        dispatch_async(dispatch_get_main_queue(), ^{
            if(strongLocalSelf->_glView == nil){
                strongLocalSelf->_glView = [[MovieGLView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 1280, 720)];
            }

            if(strongLocalSelf->_glView.superview != view){
                [view addSubview:strongLocalSelf->_glView];
            }
            [view sendSubviewToBack:strongLocalSelf->_glView];
            [strongLocalSelf->_glView adjustSize];
            strongLocalSelf->_status.isGLViewInit = YES;

        });
        END_DISPATCH_QUEUE
    }
    return NO;
}

-(void)unSetView
{
    BEGIN_DISPATCH_QUEUE
    dispatch_async(dispatch_get_main_queue(), ^{
        if(strongLocalSelf->_glView != nil && strongLocalSelf->_glView.superview !=nil)
        {
            [strongLocalSelf->_glView removeFromSuperview];
            strongLocalSelf->_status.isGLViewInit = NO;
        }
    });
    END_DISPATCH_QUEUE
}

- (BOOL)start
{
    BEGIN_DISPATCH_QUEUE
    if(strongLocalSelf->_decodeThread == nil && !strongLocalSelf->_status.isRunning)
    {
        strongLocalSelf->_decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(startRun) object:nil];
        [strongLocalSelf->_decodeThread start];
    }
    END_DISPATCH_QUEUE
    return YES;
}

- (void)resume
{
    BEGIN_DISPATCH_QUEUE
    strongLocalSelf->_status.isPause = NO;
    NSLog(@"Resume video decoder");
    END_DISPATCH_QUEUE
}

- (void)pause
{
    BEGIN_DISPATCH_QUEUE
    strongLocalSelf->_status.isPause = YES;
    NSLog(@"Pause video decoder");
    END_DISPATCH_QUEUE
}

- (void)close
{
    BEGIN_DISPATCH_QUEUE
    [strongLocalSelf->_dataQueue clear];
    if(strongLocalSelf->_decodeThread!=nil){
        [strongLocalSelf->_decodeThread cancel];
    }
    strongLocalSelf->_status.isRunning = NO;
    END_DISPATCH_QUEUE
}

- (void)stop
{
    BEGIN_DISPATCH_QUEUE
    [strongLocalSelf->_dataQueue clear];
    if(strongLocalSelf->_decodeThread!=nil){
        [strongLocalSelf->_decodeThread cancel];
    }
    strongLocalSelf->_status.isRunning = NO;
    END_DISPATCH_QUEUE
}

- (void)enterBackground{
    BEGIN_DISPATCH_QUEUE
    strongLocalSelf->_status.isBackground = YES;
    END_DISPATCH_QUEUE
}

- (void)enterForeground{
    BEGIN_DISPATCH_QUEUE
    strongLocalSelf->_status.isBackground = NO;
    END_DISPATCH_QUEUE
}

-(void) reset
{
    BEGIN_DISPATCH_QUEUE
    
    if(strongLocalSelf->_decodeThread && strongLocalSelf->_status.isRunning)
    {
        strongLocalSelf->_status.isRunning = NO;
        while (!strongLocalSelf->_status.isFinish) {
            usleep(1000);
        }
        
        strongLocalSelf->_decodeThread = nil;
        [strongLocalSelf->_videoExtractor clearBuffer];
        [strongLocalSelf->_dataQueue clear];
        
        strongLocalSelf->_decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(startRun) object:nil];
        [strongLocalSelf->_decodeThread start];
        
        if (strongLocalSelf.hwDecoder) {
            [strongLocalSelf.hwDecoder resetLater];
        }
    }
    
    END_DISPATCH_QUEUE
}

-(void) encounterBadFrame
{
    self.badFrameCounter++;
    if (self.badFrameCounter > 6) {
        if (self.canReset) {
            [self reset];
            self.canReset = NO;
        }
        self.badFrameCounter = 0;
    }
}

#pragma mark - private

-(void)grayFilter:(VideoFrameYUV *)yuv
{
    if(yuv->gray) return;
    yuv->gray = 1;
    uint8_t *cb = yuv->chromaB;
    for(int i = 0 ; i <yuv->height*yuv->width/4; ++i)
    {
        *(cb++) = 127;
    }
    memcpy(yuv->chromaR, yuv->chromaB, yuv->height*yuv->width/4);
}

-(void)startRun
{
    __weak VideoPreviewer* weakSelf = self;
    for(int i = 0;i<RENDER_FRAME_NUMBER;i++)
    {
        _renderYUVFrame[i] = (VideoFrameYUV *)malloc(sizeof(VideoFrameYUV)) ;
        memset(_renderYUVFrame[i], 0, sizeof(VideoFrameYUV));
        pthread_rwlock_init(&(_renderYUVFrame[i]->mutex), NULL);
    }
    _decodeFrameIndex = 0;
    _renderFrameIndex = 0;
    _status.isRunning = YES;
    _status.isFinish = NO;
    
    while(_status.isRunning)
    {
        @autoreleasepool
        {
            int inputDataSize = 0;
            uint8_t *inputData = [_dataQueue pull:&inputDataSize];
            
            if(inputData == NULL)
            {
                if(_renderYUVFrame[_renderFrameIndex]->chromaB!=nil){
                    pthread_rwlock_wrlock(&(_renderYUVFrame[_renderFrameIndex]->mutex));
                    [self grayFilter:_renderYUVFrame[_renderFrameIndex]];
                    pthread_rwlock_unlock(&(_renderYUVFrame[_renderFrameIndex]->mutex));
                    if(_status.isGLViewInit && !_status.isPause && !_status.isBackground){
                        [_glView render:_renderYUVFrame[_renderFrameIndex]];
                    }
                }
                
                if(_status.hasImage){
                    _status.hasImage = NO;
                    if(self.delegate !=nil && [self.delegate respondsToSelector:@selector(previewDidReceiveEvent:)]){
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.delegate previewDidReceiveEvent:VideoPreviewerEventNoImage];
                        });
                    }
                }
                continue;
            }
            if(!_status.hasImage){
                _status.hasImage = YES;
                if(self.delegate !=nil && [self.delegate respondsToSelector:@selector(previewDidReceiveEvent:)]){
                    [self.delegate previewDidReceiveEvent:VideoPreviewerEventHasImage];
                }
            }
            
            if (self.useHardware) {
                if (!self.isHardwareDecoding) {
                    self.isHardwareDecoding = YES;
                }
                if (!_status.isPause && !_status.isBackground) {
                    //use hardware decode
                    [_videoExtractor parse:inputData length:inputDataSize callback:^(uint8_t *frame, int length, int frame_width, int frame_height) {
                        __strong VideoPreviewer* strongLocalSelf = weakSelf;
                        BOOL sizeChanged = NO;
                        if (frame_width > 0 && frame_height > 0) {
                            if (strongLocalSelf->_frameSize.width == 0 || strongLocalSelf->_frameSize.height == 0) {
                                strongLocalSelf->_frameSize.width = frame_width;
                                strongLocalSelf->_frameSize.height = frame_height;
                            }
                            else
                            {
                                if (strongLocalSelf->_frameSize.width != frame_width || strongLocalSelf->_frameSize.height != frame_height) {
                                    sizeChanged = YES;
                                    strongLocalSelf->_frameSize.width = frame_width;
                                    strongLocalSelf->_frameSize.height = frame_height;
                                }
                            }
                        }
                        if (sizeChanged) {
                            [self.hwDecoder resetLater];
                        }
                        else
                        {
                            DJIVTH264DecoderUserData data;
                            data.frame_size = length;
                            data.frame_uuid = strongLocalSelf->_decodeFrameIndex++;
                            BOOL ret = [self.hwDecoder decodeFrame:frame length:length userData:data];
                            if (ret != YES) {
                                self.decoderErrorCount++;
                                if (self.decoderErrorCount > 6) {
                                    self.decoderErrorCount = 0;
                                    [self.hwDecoder resetLater];
                                }
                            }
                        }
                    }];
                }
            }
            else
            {
                if (self.isHardwareDecoding) {
                    self.isHardwareDecoding = NO;
                }
                if (self.isLB2) {
                    [_lb2Hack parse:inputData inSize:inputDataSize];
                }
                else {
                    [_videoExtractor decode:inputData length:inputDataSize callback:^(BOOL hasFrame)
                     {
                         __strong VideoPreviewer* strongLocalSelf = weakSelf;
                         if (hasFrame) {
                             self.canReset = YES;
                             if (strongLocalSelf->_decodeFrameIndex >= RENDER_FRAME_NUMBER) {
                                 strongLocalSelf->_decodeFrameIndex = 0;
                             }
                             pthread_rwlock_wrlock(&(strongLocalSelf->_renderYUVFrame[strongLocalSelf->_decodeFrameIndex]->mutex));
                             [strongLocalSelf->_videoExtractor getYuvFrame:strongLocalSelf->_renderYUVFrame[strongLocalSelf->_decodeFrameIndex]];
                             strongLocalSelf->_renderYUVFrame[strongLocalSelf->_decodeFrameIndex]->gray = 0;
                             pthread_rwlock_unlock(&(strongLocalSelf->_renderYUVFrame[strongLocalSelf->_decodeFrameIndex]->mutex));
                             strongLocalSelf->_renderFrameIndex = strongLocalSelf->_decodeFrameIndex;
                             if(strongLocalSelf->_status.isGLViewInit && !strongLocalSelf->_status.isPause && !strongLocalSelf->_status.isBackground)
                             {
                                 [strongLocalSelf->_glView render:strongLocalSelf->_renderYUVFrame[strongLocalSelf->_renderFrameIndex]];
                             }
                             if((++strongLocalSelf->_decodeFrameIndex)>=RENDER_FRAME_NUMBER){
                                 strongLocalSelf->_decodeFrameIndex = 0;
                             }
                         }
                         else
                         {
                             [self encounterBadFrame];
                         }
                         
                     }];
                }
            }
            
            free(inputData);
            inputData = NULL;
        }
    }
    
    for(int i = 0;i<RENDER_FRAME_NUMBER;i++)
    {
        pthread_rwlock_wrlock(&(_renderYUVFrame[i]->mutex));
        free(_renderYUVFrame[i]->luma);
        free(_renderYUVFrame[i]->chromaB);
        free(_renderYUVFrame[i]->chromaR);
        pthread_rwlock_unlock(&(_renderYUVFrame[i]->mutex));
        free(_renderYUVFrame[i]);
    }
    
    _decodeThread = nil;
    _status.isFinish = YES;
}

-(void) clean
{
    [_videoExtractor freeExtractor];
    [self stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    
    _glView = nil;
}

//-(void) dealloc
//{
//    [_videoExtractor freeExtractor];
//    [self stop];
//    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
//    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
//}

#pragma mark - hardware decoder

-(void) decompressedFrame:(CVImageBufferRef)image frameInfo:(DJIVTH264DecoderUserData)frame
{
    if (image == nil || !self.useHardware) {
        //decode falied
        return;
    }
    //can use CVOpenGLESTextureCacheCreateTextureFromImage to optimize performance.
    //CVPixelBufferLockBaseAddress is copy the yuv image from GPU to CPU.
    
    if(_status.isGLViewInit && !_status.isPause && !_status.isBackground)
    {
        CFTypeID imageType = CFGetTypeID(image);
        if (imageType == CVPixelBufferGetTypeID() &&
            (kCVPixelFormatType_420YpCbCr8Planar == CVPixelBufferGetPixelFormatType(image)   ||
             kCVPixelFormatType_420YpCbCr8PlanarFullRange == CVPixelBufferGetPixelFormatType(image)))
        {
            //make sure this is a yuv420 image
            CGSize size = CVImageBufferGetDisplaySize(image);
            if(kCVReturnSuccess != CVPixelBufferLockBaseAddress(image, 0))
                return;
            VideoFrameYUV yuvImage = {0};
            yuvImage.luma = CVPixelBufferGetBaseAddressOfPlane(image, 0);
            yuvImage.chromaB = CVPixelBufferGetBaseAddressOfPlane(image, 1);
            yuvImage.chromaR = CVPixelBufferGetBaseAddressOfPlane(image, 2);
            yuvImage.width = size.width;
            yuvImage.height = size.height;
            
            [_glView render:&yuvImage];
            
            CVPixelBufferUnlockBaseAddress(image, 0);
        }
    }
}

-(void) lb2AUDHackParser:(id)parser didParsedData:(void *)data size:(int)size{
    __weak VideoPreviewer* weakSelf = self;
    [_videoExtractor decode:data length:size callback:^(BOOL hasFrame)
     {
         __strong VideoPreviewer* strongLocalSelf = weakSelf;
         if (hasFrame) {
             self.canReset = YES;
             if (strongLocalSelf->_decodeFrameIndex >= RENDER_FRAME_NUMBER) {
                 strongLocalSelf->_decodeFrameIndex = 0;
             }
             pthread_rwlock_wrlock(&(strongLocalSelf->_renderYUVFrame[strongLocalSelf->_decodeFrameIndex]->mutex));
             [strongLocalSelf->_videoExtractor getYuvFrame:strongLocalSelf->_renderYUVFrame[strongLocalSelf->_decodeFrameIndex]];
             strongLocalSelf->_renderFrameIndex = strongLocalSelf->_decodeFrameIndex;
             if(strongLocalSelf->_status.isGLViewInit && !strongLocalSelf->_status.isPause && !strongLocalSelf->_status.isBackground)
             {
                 [strongLocalSelf->_glView render:strongLocalSelf->_renderYUVFrame[strongLocalSelf->_renderFrameIndex]];
             }
             if((++strongLocalSelf->_decodeFrameIndex)>=RENDER_FRAME_NUMBER){
                 strongLocalSelf->_decodeFrameIndex = 0;
             }
         }
         else
         {
             [self encounterBadFrame];
         }
         
     }];
    
}


@end
