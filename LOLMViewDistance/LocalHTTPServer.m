//
//  LocalHTTPServer.m
//  LOLMViewDistance
//
//  用 CFSocket 实现微型 HTTP 服务器，仅绑定 127.0.0.1
//  路由：
//    GET  /            → index.html
//    POST /api         → JSON-RPC: {"method":"getProcList","params":{...}}
//    GET  /health      → {"ok":true}
//

#import "LocalHTTPServer.h"
#import "H5GGBridge.h"
#import <CFNetwork/CFNetwork.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface LocalHTTPServer ()
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) CFSocketRef socket;
@property (nonatomic, strong) NSThread *thread;
@property (nonatomic, assign) BOOL running;
@end

@implementation LocalHTTPServer

- (void)dealloc {
    [self stop];
}

- (BOOL)start {
    if (self.socket) return YES;

    CFSocketContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    CFSocketRef sock = CFSocketCreate(NULL, PF_INET, SOCK_STREAM,
                                      IPPROTO_TCP, kCFSocketAcceptCallBack,
                                      ServerAcceptCallBack, &ctx);
    if (!sock) return NO;

    int yes = 1;
    setsockopt(CFSocketGetNative(sock), SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr4;
    memset(&addr4, 0, sizeof(addr4));
    addr4.sin_len = sizeof(addr4);
    addr4.sin_family = AF_INET;
    // 固定端口 45678（localStorage/cookie 按 origin 持久化），占用则回退随机端口
    addr4.sin_port = htons(45678);
    addr4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    CFDataRef addr = CFDataCreate(NULL, (const UInt8 *)&addr4, sizeof(addr4));
    if (CFSocketSetAddress(sock, addr) != kCFSocketSuccess) {
        // 端口被占用，回退随机端口
        CFRelease(addr);
        addr4.sin_port = htons(0);
        addr = CFDataCreate(NULL, (const UInt8 *)&addr4, sizeof(addr4));
        if (CFSocketSetAddress(sock, addr) != kCFSocketSuccess) {
            CFRelease(addr);
            CFRelease(sock);
            return NO;
        }
    }
    CFRelease(addr);

    // 获取实际端口
    NSData *addrData = (__bridge_transfer NSData *)CFSocketCopyAddress(sock);
    if (addrData.length >= sizeof(struct sockaddr_in)) {
        struct sockaddr_in sin;
        [addrData getBytes:&sin length:sizeof(sin)];
        self.port = ntohs(sin.sin_port);
    }

    CFRunLoopSourceRef src = CFSocketCreateRunLoopSource(NULL, sock, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);

    self.socket = sock;
    self.running = YES;
    return YES;
}

- (void)stop {
    self.running = NO;
    if (self.socket) {
        CFSocketInvalidate(self.socket);
        CFRelease(self.socket);
        self.socket = NULL;
    }
}

#pragma mark - 设备 UUID

- (NSString *)deviceUUID {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *uuid = [defaults stringForKey:@"lolm_device_uuid"];
    if (!uuid || uuid.length == 0) {
        uuid = [[NSUUID UUID] UUIDString];
        [defaults setObject:uuid forKey:@"lolm_device_uuid"];
        [defaults synchronize];
    }
    return uuid;
}

#pragma mark - C 回调

static void ServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type,
                                 CFDataRef address, const void *data, void *info) {
    if (type != kCFSocketAcceptCallBack) return;
    LocalHTTPServer *server = (__bridge LocalHTTPServer *)info;
    if (!server || !server.running) return;

    CFSocketNativeHandle nativeHandle = *(CFSocketNativeHandle *)data;
    // 每个连接一个后台线程处理
    [NSThread detachNewThreadSelector:@selector(handleConnection:)
                             toTarget:server
                           withObject:@(nativeHandle)];
}

#pragma mark - 连接处理

- (void)handleConnection:(NSNumber *)fdNumber {
    @autoreleasepool {
        CFSocketNativeHandle fd = fdNumber.intValue;

        // 读请求（最多 1MB）
        NSMutableData *requestData = [NSMutableData data];
        char buf[8192];
        ssize_t n;
        // 简单解析：先读到 \r\n\r\n，再根据 Content-Length 读 body
        NSRange headerEnd = NSMakeRange(NSNotFound, 0);
        while (1) {
            n = read(fd, buf, sizeof(buf));
            if (n <= 0) break;
            [requestData appendBytes:buf length:n];
            NSData *d = requestData;
            const char *bytes = d.bytes;
            NSUInteger len = d.length;
            // 查找 \r\n\r\n
            for (NSUInteger i = 0; i + 3 < len; i++) {
                if (bytes[i] == '\r' && bytes[i+1] == '\n' &&
                    bytes[i+2] == '\r' && bytes[i+3] == '\n') {
                    headerEnd = NSMakeRange(0, i + 4);
                    break;
                }
            }
            if (headerEnd.location != NSNotFound) break;
            if (requestData.length > 1024 * 1024) break;
        }

        NSString *requestStr = [[NSString alloc] initWithData:requestData
                                                     encoding:NSUTF8StringEncoding];
        if (requestStr.length == 0) {
            close(fd);
            return;
        }

        // 解析请求行
        NSArray *lines = [requestStr componentsSeparatedByString:@"\r\n"];
        NSString *requestLine = lines.firstObject ?: @"";
        NSArray *parts = [requestLine componentsSeparatedByString:@" "];
        NSString *method = parts.count > 0 ? parts[0] : @"";
        NSString *path = parts.count > 1 ? parts[1] : @"/";

        // 提取 Content-Length
        NSUInteger contentLength = 0;
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = [[line substringFromIndex:15] integerValue];
                break;
            }
        }

        NSData *bodyData = nil;
        if (contentLength > 0 && requestData.length >= headerEnd.location + contentLength) {
            bodyData = [requestData subdataWithRange:NSMakeRange(headerEnd.location, contentLength)];
        }

        // 路由
        NSData *responseData = nil;
        NSString *contentType = @"application/json";

        if ([method isEqualToString:@"GET"] &&
            ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"])) {
            NSString *htmlPath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
            if (htmlPath) {
                responseData = [NSData dataWithContentsOfFile:htmlPath];
                contentType = @"text/html; charset=utf-8";
            } else {
                responseData = [@"<h1>index.html not found</h1>" dataUsingEncoding:NSUTF8StringEncoding];
                contentType = @"text/html; charset=utf-8";
            }
        } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/health"]) {
            responseData = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
        } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/native-uuid"]) {
            // 原生持久化 UUID（NSUserDefaults，与 WebKit 存储无关，永不丢失）
            NSDictionary *d = @{ @"uuid": [self deviceUUID] };
            NSError *jsonErr = nil;
            responseData = [NSJSONSerialization dataWithJSONObject:d options:0 error:&jsonErr];
            if (jsonErr || !responseData) {
                responseData = [@"{\"error\":\"uuid failed\"}" dataUsingEncoding:NSUTF8StringEncoding];
            }
        } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api"]) {
            responseData = [self handleAPI:bodyData];
        } else {
            responseData = [@"{\"error\":\"not found\"}" dataUsingEncoding:NSUTF8StringEncoding];
        }

        // 写响应
        NSMutableString *head = [NSMutableString string];
        [head appendString:@"HTTP/1.1 200 OK\r\n"];
        [head appendFormat:@"Content-Type: %@\r\n", contentType];
        [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)responseData.length];
        [head appendString:@"Connection: close\r\n"];
        [head appendString:@"Access-Control-Allow-Origin: *\r\n"];
        [head appendString:@"\r\n"];

        NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *outData = [NSMutableData dataWithCapacity:headData.length + responseData.length];
        [outData appendData:headData];
        [outData appendData:responseData];

        write(fd, outData.bytes, outData.length);
        close(fd);
    }
}

#pragma mark - API 处理

- (NSData *)handleAPI:(NSData *)bodyData {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    @try {
        if (bodyData.length == 0) {
            result[@"error"] = @"empty body";
            return [self jsonData:result];
        }
        NSDictionary *req = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
        if (![req isKindOfClass:[NSDictionary class]]) {
            result[@"error"] = @"bad json";
            return [self jsonData:result];
        }
        NSString *method = req[@"method"] ?: @"";
        NSDictionary *params = req[@"params"] ?: @{};
        H5GGBridge *bridge = [H5GGBridge shared];

        if ([method isEqualToString:@"getProcList"]) {
            NSString *name = params[@"name"] ?: @"";
            result[@"result"] = [bridge getProcList:name];
        } else if ([method isEqualToString:@"setTargetProc"]) {
            pid_t pid = (pid_t)[params[@"pid"] intValue];
            result[@"result"] = @([bridge setTargetProc:pid]);
        } else if ([method isEqualToString:@"getRangesList"]) {
            NSString *module = params[@"module"] ?: @"";
            result[@"result"] = [bridge getRangesList:module];
        } else if ([method isEqualToString:@"getValue"]) {
            uint64_t addr = [self parseAddr:params[@"addr"]];
            NSString *type = params[@"type"] ?: @"F32";
            NSNumber *v = [bridge getValue:addr type:type];
            result[@"result"] = v ?: [NSNull null];
        } else if ([method isEqualToString:@"setValue"]) {
            uint64_t addr = [self parseAddr:params[@"addr"]];
            NSString *type = params[@"type"] ?: @"F32";
            double value = [params[@"value"] doubleValue];
            result[@"result"] = @([bridge setValue:addr value:value type:type]);
        } else if ([method isEqualToString:@"clearResults"]) {
            result[@"result"] = @YES;
        } else if ([method isEqualToString:@"getValue2"]) {
            // 兼容：地址可能以字符串传入
            uint64_t addr = [self parseAddr:params[@"addr"]];
            NSString *type = params[@"type"] ?: @"F32";
            NSNumber *v = [bridge getValue:addr type:type];
            result[@"result"] = v ?: [NSNull null];
        } else {
            result[@"error"] = [NSString stringWithFormat:@"unknown method: %@", method];
        }
    } @catch (NSException *e) {
        result[@"error"] = e.reason ?: @"exception";
    }
    return [self jsonData:result];
}

- (uint64_t)parseAddr:(id)obj {
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
            return strtoull(s.UTF8String, NULL, 16);
        }
        return (uint64_t)strtoull(s.UTF8String, NULL, 10);
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)obj unsignedLongLongValue];
    }
    return 0;
}

- (NSData *)jsonData:(NSDictionary *)dict {
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    if (err || !d) {
        return [@"{\"error\":\"json encode failed\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return d;
}

@end
