//
//  ViewController.m
//  LOLMViewDistance
//
//  WKWebView 加载本地 HTML，注入 h5gg polyfill（同步 XHR → 本地 API）
//

#import "ViewController.h"
#import "LocalHTTPServer.h"
#import <WebKit/WebKit.h>

@interface ViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) LocalHTTPServer *server;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // 启动本地服务器
    self.server = [[LocalHTTPServer alloc] init];
    BOOL started = [self.server start];
    NSLog(@"[ViewDist] HTTP server started: %d, port: %u", started, self.server.port);

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;

    // 注入 h5gg polyfill：把 window.h5gg 桥接到本地 HTTP API（同步 XHR）
    NSString *polyfill = [self h5ggPolyfill];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:polyfill
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES];
    [config.userContentController addUserScript:script];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.webView];

    NSString *urlStr = [NSString stringWithFormat:@"http://127.0.0.1:%u/", self.server.port];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSURLRequest *req = [NSURLRequest requestWithURL:url];
    [self.webView loadRequest:req];
}

/// h5gg 兼容层：JS 同步调用 → XHR POST /api → 原生内存操作
- (NSString *)h5ggPolyfill {
    return @";(function(){\n"
    @"var API = '/api';\n"
    @"function call(method, params){\n"
    @"  var xhr = new XMLHttpRequest();\n"
    @"  xhr.open('POST', API, false);\n"
    @"  xhr.setRequestHeader('Content-Type','application/json');\n"
    @"  xhr.send(JSON.stringify({method:method, params:params||{}}));\n"
    @"  if(xhr.status===200){\n"
    @"    try{ return JSON.parse(xhr.responseText); }catch(e){ return {error:'bad response'}; }\n"
    @"  }\n"
    @"  return {error:'http '+xhr.status};\n"
    @"}\n"
    @"function r(method, params){ var d=call(method, params); return d.error?null:d.result; }\n"
    @"window.h5gg = {\n"
    @"  getProcList: function(name){ return r('getProcList',{name:name}); },\n"
    @"  setTargetProc: function(pid){ return r('setTargetProc',{pid:pid}); },\n"
    @"  getRangesList: function(module){ return r('getRangesList',{module:module}); },\n"
    @"  getValue: function(addr,type){ return r('getValue',{addr:addr,type:type}); },\n"
    @"  setValue: function(addr,value,type){ return r('setValue',{addr:addr,value:value,type:type}); },\n"
    @"  clearResults: function(){ return r('clearResults',{}); }\n"
    @"};\n"
    @"console.log('[h5gg] polyfill ready');\n"
    @"})();";
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[ViewDist] navigation error: %@", error);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"[ViewDist] page loaded");
}

@end
