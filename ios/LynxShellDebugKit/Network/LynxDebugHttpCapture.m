#if DEBUG
#import "LynxDebugHttpCapture.h"

#import <Lynx/LynxServiceHttpProtocol.h>
#import <LynxService/LynxHttpService.h>
#import <objc/runtime.h>

static LynxDebugHTTPStartHandler sStartHandler;
static LynxDebugHTTPFinishHandler sFinishHandler;

@interface LynxDebugStreamingDelegateProxy : LynxHttpStreamingDelegate
- (instancetype)initWithDelegate:(LynxHttpStreamingDelegate *)delegate
             errorBeforeResponse:(void (^)(NSString *error))errorBeforeResponse;
@end

@implementation LynxDebugStreamingDelegateProxy {
  LynxHttpStreamingDelegate *_delegate;
  void (^_errorBeforeResponse)(NSString *error);
}

- (instancetype)initWithDelegate:(LynxHttpStreamingDelegate *)delegate
             errorBeforeResponse:(void (^)(NSString *error))errorBeforeResponse {
  self = [super init];
  if (self) {
    _delegate = delegate;
    _errorBeforeResponse = [errorBeforeResponse copy];
  }
  return self;
}

- (void)processChunkedData:(NSMutableData *)buffer withData:(NSData *)data {
  [_delegate processChunkedData:buffer withData:data];
}

- (void)processSseData:(NSMutableData *)buffer withData:(NSData *)data {
  [_delegate processSseData:buffer withData:data];
}

- (void)processStreamingData:(NSData *)data {
  [_delegate processStreamingData:data];
}

- (void)onData:(NSData *)bytes {
  [_delegate onData:bytes];
}

- (void)onEnd {
  [_delegate onEnd];
}

- (void)onError:(NSString *)error {
  if (_errorBeforeResponse) {
    _errorBeforeResponse(error);
  }
  [_delegate onError:error];
}

@end

@interface LynxHttpService (LynxDebugCapture)
- (void)lynx_debug_invokeWithRequest:(LynxHttpRequest *)request
                            callback:(LynxHttpCallback)callback;
- (void)lynx_debug_invokeStreamingWithRequest:(LynxHttpRequest *)request
                                     callback:(LynxHttpCallback)callback
                                 withDelegate:(LynxHttpStreamingDelegate *)delegate;
@end

@implementation LynxHttpService (LynxDebugCapture)

- (void)lynx_debug_invokeWithRequest:(LynxHttpRequest *)request
                            callback:(LynxHttpCallback)callback {
  NSString *identifier = sStartHandler ? sStartHandler(request, NO) : nil;
  LynxHttpCallback wrapped = ^(LynxHttpResponse *response) {
    if (identifier && sFinishHandler) {
      sFinishHandler(identifier, request, response);
    }
    callback(response);
  };
  [self lynx_debug_invokeWithRequest:request callback:wrapped];
}

- (void)lynx_debug_invokeStreamingWithRequest:(LynxHttpRequest *)request
                                     callback:(LynxHttpCallback)callback
                                 withDelegate:(LynxHttpStreamingDelegate *)delegate {
  NSString *identifier = sStartHandler ? sStartHandler(request, YES) : nil;
  __block BOOL responseRecorded = NO;
  LynxHttpCallback wrapped = ^(LynxHttpResponse *response) {
    responseRecorded = YES;
    // Lynx 4.1 streaming callback 在响应头到达时触发；耗时表示 TTFB，不冒充流结束耗时。
    if (identifier && sFinishHandler) {
      sFinishHandler(identifier, request, response);
    }
    callback(response);
  };
  LynxDebugStreamingDelegateProxy *proxy = [[LynxDebugStreamingDelegateProxy alloc]
      initWithDelegate:delegate
      errorBeforeResponse:^(NSString *error) {
        if (!responseRecorded && identifier && sFinishHandler) {
          LynxHttpResponse *response = [[LynxHttpResponse alloc] init];
          response.url = request.url;
          response.statusCode = 499;
          response.statusText = error;
          sFinishHandler(identifier, request, response);
        }
      }];
  [self lynx_debug_invokeStreamingWithRequest:request
                                     callback:wrapped
                                 withDelegate:proxy];
}

@end

void LynxDebugInstallHttpCapture(
    LynxDebugHTTPStartHandler startHandler,
    LynxDebugHTTPFinishHandler finishHandler
) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // DebugTool 进程内只允许安装一次，避免请求进行中被替换到另一个 Store。
    sStartHandler = [startHandler copy];
    sFinishHandler = [finishHandler copy];
    Class cls = LynxHttpService.class;
    Method regular = class_getInstanceMethod(
        cls,
        @selector(invokeWithRequest:callback:)
    );
    Method debugRegular = class_getInstanceMethod(
        cls,
        @selector(lynx_debug_invokeWithRequest:callback:)
    );
    Method streaming = class_getInstanceMethod(
        cls,
        @selector(invokeStreamingWithRequest:callback:withDelegate:)
    );
    Method debugStreaming = class_getInstanceMethod(
        cls,
        @selector(lynx_debug_invokeStreamingWithRequest:callback:withDelegate:)
    );
    if (regular && debugRegular) {
      method_exchangeImplementations(regular, debugRegular);
    }
    if (streaming && debugStreaming) {
      method_exchangeImplementations(streaming, debugStreaming);
    }
  });
}
#endif
