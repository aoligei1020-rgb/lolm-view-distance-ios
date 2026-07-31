//
//  LocalHTTPServer.h
//  LOLMViewDistance
//
//  微型 HTTP 服务器：为 WKWebView 提供页面 + h5gg API（同步 XHR 桥）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LocalHTTPServer : NSObject

@property (nonatomic, readonly) uint16_t port;

- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
