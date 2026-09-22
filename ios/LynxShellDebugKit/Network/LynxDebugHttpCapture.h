#if DEBUG
#import <Foundation/Foundation.h>
#import <Lynx/LynxHttpRequest.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *_Nullable (^LynxDebugHTTPStartHandler)(
    LynxHttpRequest *request,
    BOOL streaming
);
typedef void (^LynxDebugHTTPFinishHandler)(
    NSString *identifier,
    LynxHttpRequest *request,
    LynxHttpResponse *response
);

FOUNDATION_EXPORT void LynxDebugInstallHttpCapture(
    LynxDebugHTTPStartHandler startHandler,
    LynxDebugHTTPFinishHandler finishHandler
);

NS_ASSUME_NONNULL_END
#endif
