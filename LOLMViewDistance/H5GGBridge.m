//
//  H5GGBridge.m
//  LOLMViewDistance
//
//  复用 LOLViewDistance.m 的成熟逻辑（sysctl 找进程 / task_for_pid /
//  task_dyld_info 读模块 / vm_read / vm_write）
//

#import "H5GGBridge.h"
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <mach-o/dyld_images.h>
#import <Security/Security.h>

// libproc 头文件在 iOS SDK 中不可靠（Xcode16/iOS18 SDK 无 libproc.h），
// 直接声明 libSystem 导出的函数（libproc 已合并入 libSystem）。
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif

// csops：检查/设置代码签名状态（libSystem 导出，iOS SDK 无头文件，手动声明）
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_PLATFORM_BINARY
#define CS_PLATFORM_BINARY 0x4000000
#endif

// task_for_pid 函数指针类型（避免依赖私有类型定义）
typedef kern_return_t (*task_for_pid_fn_t)(task_t, pid_t, task_t *);

@interface H5GGBridge ()
@property (nonatomic, assign) pid_t targetPID;
@property (nonatomic, assign) task_t targetTask;
@property (nonatomic, assign) BOOL attached;
@property (nonatomic, assign) pid_t scanPID;
@property (nonatomic, strong) NSDate *scanTime;
@property (nonatomic, assign) int scanCount;   // 本次扫描尝试 attach 的 pid 数
@property (nonatomic, assign) int scanTaskOK;  // 本次扫描 task_for_pid 成功数
@end

@implementation H5GGBridge

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _targetPID = 0;
        _targetTask = TASK_NULL;
        _attached = NO;
    }
    return self;
}

#pragma mark - 进程查找

// LOLM 进程名别名（安卓脚本写死 'lolm'，iOS 上可执行文件名可能不同）
static BOOL lolmNameMatch(NSString *haystack) {
    if (haystack.length == 0) return NO;
    NSString *lc = haystack.lowercaseString;
    if ([lc containsString:@"lolm"]) return YES;
    if ([lc containsString:@"wildrift"]) return YES;
    if ([lc containsString:@"wild"]) return YES;
    if ([lc containsString:@"league"]) return YES;
    if ([lc containsString:@"lolma"]) return YES;
    if ([lc containsString:@"tencent"]) return YES;
    if ([lc containsString:@"riot"]) return YES;
    return NO;
}

- (NSArray<NSDictionary *> *)getProcList:(NSString *)name {
    // 已绑定：直接返回目标（手动选择/扫描成功后，脚本下一轮才能拿到 LOLM 继续 getRangesList）
    if (_attached && _targetPID > 0) {
        return @[@{ @"pid": @(_targetPID), @"name": @"lolm" }];
    }
    NSMutableArray *result = [NSMutableArray array];
    NSString *lower = name ? name.lowercaseString : @"";

    // 通道1：sysctl KERN_PROC_ALL（H5GG 同款；越狱环境沙盒可能放宽，TrollStore 下通常被过滤）
    {
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        size_t size = 0;
        if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0) {
            struct kinfo_proc *pl = malloc(size);
            if (pl) {
                if (sysctl(mib, 4, pl, &size, NULL, 0) == 0) {
                    int cnt = (int)(size / sizeof(struct kinfo_proc));
                    for (int i = 0; i < cnt; i++) {
                        NSString *procName = [NSString stringWithUTF8String:pl[i].kp_proc.p_comm];
                        if (procName.length == 0) continue;
                        BOOL match = NO;
                        if (lower.length > 0 &&
                            ([procName.lowercaseString containsString:lower] ||
                             [lower containsString:procName.lowercaseString])) match = YES;
                        if (!match) match = lolmNameMatch(procName);
                        if (match) {
                            [result addObject:@{ @"pid": @(pl[i].kp_proc.p_pid), @"name": procName }];
                        }
                    }
                }
                free(pl);
            }
        }
    }

    // 通道2：libproc（完整可执行路径匹配）
    int maxPids = 4096;
    pid_t *pids = malloc(maxPids * sizeof(pid_t));
    if (!pids) return result;
    int count = proc_listallpids(pids, maxPids * sizeof(pid_t));
    if (count <= 0) { free(pids); return result; }

    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        // 完整可执行路径（如 /.../LOLM.app/lolm）
        char pathBuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int plen = proc_pidpath(pid, pathBuf, sizeof(pathBuf));
        if (plen <= 0) continue;
        NSString *path = [NSString stringWithUTF8String:pathBuf];
        if (!path || path.length == 0) continue;

        NSString *execName = path.lastPathComponent;                 // 可执行文件名
        NSString *appDirName = path.stringByDeletingLastPathComponent.lastPathComponent; // xxx.app

        // 匹配：① 请求名（lolm） ② LOLM 别名
        BOOL match = NO;
        if (lower.length > 0) {
            if ([execName.lowercaseString containsString:lower] ||
                [lower containsString:execName.lowercaseString]) match = YES;
            if (!match && [appDirName.lowercaseString containsString:lower]) match = YES;
        }
        if (!match) match = lolmNameMatch(execName) || lolmNameMatch(appDirName);
        if (!match) continue;

        // 去重（sysctl 通道可能已命中同一 pid）
        BOOL dup = NO;
        for (NSDictionary *r in result) {
            if ([r[@"pid"] intValue] == pid) { dup = YES; break; }
        }
        if (dup) continue;

        [result addObject:@{
            @"pid": @(pid),
            @"name": execName ?: @""
        }];
    }
    free(pids);

    // 兜底：枚举不到 LOLM 时，暴力扫描（task_for_pid + UnityFramework/LOLM 特征确认）
    BOOL lolmFound = NO;
    for (NSDictionary *p in result) {
        NSString *n = p[@"name"];
        if (n.length > 0) {
            NSString *lc = n.lowercaseString;
            if ([lc containsString:@"lolm"] || [lc containsString:@"wildrift"] ||
                [lc containsString:@"league"] || [lc containsString:@"lolma"]) {
                lolmFound = YES;
                break;
            }
        }
    }
    if (!lolmFound && [self shouldRescan]) {
        pid_t spid = [self scanForLOLM];
        if (spid > 0) {
            [result addObject:@{ @"pid": @(spid), @"name": @"lolm" }];
        }
    }

    // 仍找不到：返回占位项，触发 JS 手动选择（H5GG 交互模式：用户从进程列表选 LOLM）
    if (result.count == 0) {
        [result addObject:@{ @"pid": @(-1), @"name": @"__MANUAL_SELECT__" }];
    }
    return result;
}

// 全进程列表（供 JS 手动选择面板）：sysctl + libproc 合并，LOLM 关键词优先
- (NSArray<NSDictionary *> *)getAllProcs {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    // sysctl 通道
    {
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        size_t size = 0;
        if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0) {
            struct kinfo_proc *pl = malloc(size);
            if (pl) {
                if (sysctl(mib, 4, pl, &size, NULL, 0) == 0) {
                    int cnt = (int)(size / sizeof(struct kinfo_proc));
                    for (int i = 0; i < cnt; i++) {
                        pid_t pid = pl[i].kp_proc.p_pid;
                        if (pid <= 0 || pid == getpid()) continue;
                        NSString *n = [NSString stringWithUTF8String:pl[i].kp_proc.p_comm];
                        if (n.length == 0) continue;
                        map[@(pid)] = n;
                    }
                }
                free(pl);
            }
        }
    }

    // libproc 通道（路径更准，覆盖 sysctl 被过滤的情况）
    int maxPids = 4096;
    pid_t *pids = malloc(maxPids * sizeof(pid_t));
    if (pids) {
        int count = proc_listallpids(pids, maxPids * sizeof(pid_t));
        if (count > 0) {
            for (int i = 0; i < count; i++) {
                pid_t pid = pids[i];
                if (pid <= 0 || pid == getpid()) continue;
                char pathBuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
                int plen = proc_pidpath(pid, pathBuf, sizeof(pathBuf));
                if (plen <= 0) continue;
                NSString *path = [NSString stringWithUTF8String:pathBuf];
                if (path.length == 0) continue;
                map[@(pid)] = path.lastPathComponent;
            }
        }
        free(pids);
    }

    // 组装 + LOLM 关键词优先排序
    NSMutableArray *procs = [NSMutableArray array];
    [map enumerateKeysAndObjectsUsingBlock:^(NSNumber *pid, NSString *name, BOOL *stop) {
        [procs addObject:@{ @"pid": pid, @"name": name ?: @"" }];
    }];
    [procs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *na = a[@"name"] ?: @"";
        NSString *nb = b[@"name"] ?: @"";
        BOOL ka = lolmNameMatch(na);
        BOOL kb = lolmNameMatch(nb);
        if (ka != kb) return ka ? NSOrderedAscending : NSOrderedDescending;
        return [na compare:nb];
    }];
    if (procs.count > 300) {
        procs = [[procs subarrayWithRange:NSMakeRange(0, 300)] mutableCopy];
    }
    return procs;
}

#pragma mark - LOLM 暴力扫描（task_for_pid + 模块特征确认）

// task_for_pid 封装（TrollStore 签名自带 platform-application，可用）
- (kern_return_t)taskForPid:(pid_t)pid outTask:(task_t *)outTask {
    static task_for_pid_fn_t s_task_for_pid = NULL;
    if (!s_task_for_pid) {
        s_task_for_pid = (task_for_pid_fn_t)dlsym(RTLD_DEFAULT, "task_for_pid");
    }
    if (!s_task_for_pid) return KERN_FAILURE;
    return s_task_for_pid(mach_task_self(), pid, outTask);
}

// 检查某 task 的 dyld 镜像里是否有 LOLM/Unity 特征模块，返回模块名
- (NSString *)lolmModuleForTask:(task_t)task {
    struct task_dyld_info dyldInfo = {};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count);
    if (kr != KERN_SUCCESS) return nil;

    struct dyld_all_image_infos aiis = {};
    vm_size_t readSize = sizeof(aiis);
    if (vm_read_overwrite(task, dyldInfo.all_image_info_addr, sizeof(aiis),
                          (vm_address_t)&aiis, &readSize) != KERN_SUCCESS) return nil;

    uint32_t imgCount = aiis.infoArrayCount;
    if (imgCount == 0 || imgCount > 10000) return nil;

    struct dyld_image_info *images = malloc(imgCount * sizeof(struct dyld_image_info));
    if (!images) return nil;
    readSize = imgCount * sizeof(struct dyld_image_info);
    if (vm_read_overwrite(task, (vm_address_t)aiis.infoArray,
                          imgCount * sizeof(struct dyld_image_info),
                          (vm_address_t)images, &readSize) != KERN_SUCCESS) {
        free(images);
        return nil;
    }

    NSString *unityFound = nil;
    for (uint32_t i = 0; i < imgCount; i++) {
        char pathBuf[1024] = {0};
        vm_size_t ps = sizeof(pathBuf) - 1;
        vm_read_overwrite(task, (vm_address_t)images[i].imageFilePath,
                          sizeof(pathBuf) - 1, (vm_address_t)pathBuf, &ps);
        NSString *path = [NSString stringWithUTF8String:pathBuf];
        if (path.length == 0) continue;
        NSString *modName = path.lastPathComponent.stringByDeletingPathExtension;
        if (modName.length == 0) continue;
        NSString *lc = modName.lowercaseString;
        // LOLM 专属词 → 直接确认
        if ([lc containsString:@"lolm"] || [lc containsString:@"wildrift"] ||
            [lc containsString:@"league"] || [lc containsString:@"lolma"] ||
            [lc containsString:@"tencent"] || [lc containsString:@"riot"]) {
            free(images);
            return modName;
        }
        // Unity 引擎特征（LOLM 是 Unity 引擎）
        if ([lc containsString:@"unityframework"] || [lc isEqualToString:@"unity"]) {
            unityFound = modName;
        }
    }
    free(images);
    return unityFound;
}

// 暴力扫描：遍历 pid，task_for_pid + 特征确认，找到 LOLM 并保持 attach
- (pid_t)scanForLOLM {
    self.scanTime = [NSDate date];
    self.scanCount = 0;
    self.scanTaskOK = 0;
    for (pid_t pid = 2; pid < 10000; pid++) {
        if (pid == getpid()) continue;
        self.scanCount++;
        task_t task = TASK_NULL;
        kern_return_t kr = [self taskForPid:pid outTask:&task];
        if (kr != KERN_SUCCESS || task == TASK_NULL) continue;
        self.scanTaskOK++;
        NSString *mod = [self lolmModuleForTask:task];
        if (mod.length > 0) {
            // 找到！保持 attach（释放旧 task 端口）
            if (self.targetTask != TASK_NULL && self.targetTask != task) {
                mach_port_deallocate(mach_task_self(), self.targetTask);
            }
            self.targetTask = task;
            self.targetPID = pid;
            self.attached = YES;
            self.scanPID = pid;
            return pid;
        }
        mach_port_deallocate(mach_task_self(), task);
    }
    self.scanPID = 0;
    return 0;
}

// 扫描节流：找到后 30 秒内不重扫；失败 5 秒内不重扫
- (BOOL)shouldRescan {
    if (!self.scanTime) return YES;
    NSTimeInterval dt = -[self.scanTime timeIntervalSinceNow];
    if (self.scanPID > 0 && self.attached) return dt > 30;
    return dt > 5;
}

// 诊断信息（/diag 路由）
- (NSDictionary *)diag {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"selfPID"] = @(getpid());
    d[@"attached"] = @(self.attached);
    d[@"targetPID"] = @(self.targetPID);
    d[@"scanPID"] = @(self.scanPID);

    // 签名 entitlements 自检（关键）：TrollStore 对 unsigned IPA 默认只签最小集
    // （appid/get-task-allow，无 platform-application/no-sandbox → 沙盒过滤枚举 + AMFI 拒 task_for_pid）。
    // v3.3.7 起 App bundle 内置 entitlements.plist，TrollStore 签名时会采用它。
    // 注意：CS_PLATFORM_BINARY 位只有苹果签名的二进制才有，TrollStore 重签的 App 永远是 0，
    // 不能用它判断 platform 权限——必须读 entitlements 真值。
    int csflags = 0;
    int csr = csops(getpid(), CS_OPS_STATUS, &csflags, sizeof(csflags));
    d[@"csops"] = (csr == 0) ? [NSString stringWithFormat:@"0x%x", csflags]
                             : [NSString stringWithFormat:@"err:%d", csr];
    BOOL entPlatform = NO, entNoSandbox = NO, entGetTaskAllow = NO;
    SecTaskRef secTask = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (secTask) {
        CFTypeRef v = SecTaskCopyValueForEntitlement(secTask, CFSTR("platform-application"), NULL);
        if (v) { entPlatform = (CFGetTypeID(v) == CFBooleanGetTypeID()) && CFBooleanGetValue(v); CFRelease(v); }
        v = SecTaskCopyValueForEntitlement(secTask, CFSTR("com.apple.private.security.no-sandbox"), NULL);
        if (v) { entNoSandbox = (CFGetTypeID(v) == CFBooleanGetTypeID()) && CFBooleanGetValue(v); CFRelease(v); }
        v = SecTaskCopyValueForEntitlement(secTask, CFSTR("get-task-allow"), NULL);
        if (v) { entGetTaskAllow = (CFGetTypeID(v) == CFBooleanGetTypeID()) && CFBooleanGetValue(v); CFRelease(v); }
        CFRelease(secTask);
    }
    d[@"entPlatform"] = @(entPlatform);
    d[@"entNoSandbox"] = @(entNoSandbox);
    d[@"entGetTaskAllow"] = @(entGetTaskAllow);
    d[@"isPlatformBinary"] = @(entPlatform);  // 语义 = platform 权限是否生效（诊断条读此字段）

    // sysctl 枚举统计（对比 libproc，判断沙盒过滤）
    int sysctlCount = 0;
    NSMutableArray *sysctlProcs = [NSMutableArray array];
    {
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        size_t size = 0;
        if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0) {
            struct kinfo_proc *pl = malloc(size);
            if (pl) {
                if (sysctl(mib, 4, pl, &size, NULL, 0) == 0) {
                    sysctlCount = (int)(size / sizeof(struct kinfo_proc));
                    for (int i = 0; i < sysctlCount && i < 30; i++) {
                        NSString *n = [NSString stringWithUTF8String:pl[i].kp_proc.p_comm];
                        [sysctlProcs addObject:@{ @"pid": @(pl[i].kp_proc.p_pid), @"name": n ?: @"" }];
                    }
                }
                free(pl);
            }
        }
    }
    d[@"sysctlCount"] = @(sysctlCount);
    d[@"sysctlProcs"] = sysctlProcs;

    // libproc 枚举统计 + LOLM 候选
    int maxPids = 4096;
    pid_t *pids = malloc(maxPids * sizeof(pid_t));
    int count = proc_listallpids(pids, maxPids * sizeof(pid_t));
    d[@"procListAll"] = @(count);
    NSMutableArray *procs = [NSMutableArray array];
    NSMutableArray *lolmCands = [NSMutableArray array];
    for (int i = 0; i < count && i < 80; i++) {
        char pathBuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int plen = proc_pidpath(pids[i], pathBuf, sizeof(pathBuf));
        NSString *path = (plen > 0) ? [NSString stringWithUTF8String:pathBuf] : @"(path denied)";
        [procs addObject:@{ @"pid": @(pids[i]), @"path": path ?: @"" }];
        if (lolmNameMatch(path ?: @"")) {
            [lolmCands addObject:@{ @"pid": @(pids[i]), @"path": path ?: @"" }];
        }
    }
    free(pids);
    d[@"procs"] = procs;
    d[@"lolmCandidates"] = lolmCands;

    // 扫描详情（上次扫描缓存）
    d[@"scanDetail"] = @{ @"scanned": @(self.scanCount), @"taskOK": @(self.scanTaskOK) };

    // 未绑定则触发一次扫描（顺手修复）
    if (!self.attached) {
        pid_t spid = [self scanForLOLM];
        d[@"scanResult"] = spid > 0 ? @(spid) : @0;
    } else {
        d[@"scanResult"] = @(self.targetPID);
    }
    d[@"scanDetail"] = @{ @"scanned": @(self.scanCount), @"taskOK": @(self.scanTaskOK) };
    return d;
}

#pragma mark - 进程绑定

- (BOOL)setTargetProc:(pid_t)pid {
    if (pid <= 0) return NO;
    task_t task = TASK_NULL;
    kern_return_t kr = [self taskForPid:pid outTask:&task];
    if (kr != KERN_SUCCESS || task == TASK_NULL) return NO;

    if (self.targetTask != TASK_NULL && self.targetTask != task) {
        mach_port_deallocate(mach_task_self(), self.targetTask);
    }
    self.targetTask = task;
    self.targetPID = pid;
    self.attached = YES;
    return YES;
}

#pragma mark - 模块基址

- (NSArray<NSDictionary *> *)getRangesList:(NSString *)moduleName {
    NSMutableArray *result = [NSMutableArray array];
    if (!self.attached) return result;

    struct task_dyld_info dyldInfo = {};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(self.targetTask, TASK_DYLD_INFO,
                                 (task_info_t)&dyldInfo, &count);
    if (kr != KERN_SUCCESS) return result;

    // 读取 all_image_info
    struct dyld_all_image_infos aiis = {};
    if (![self readAddress:dyldInfo.all_image_info_addr
                    buffer:&aiis size:sizeof(aiis)]) return result;

    uint32_t imgCount = aiis.infoArrayCount;
    if (imgCount == 0 || imgCount > 10000) return result;

    struct dyld_image_info *images = malloc(imgCount * sizeof(struct dyld_image_info));
    if (!images) return result;

    if (![self readAddress:(uint64_t)aiis.infoArray
                    buffer:images size:imgCount * sizeof(struct dyld_image_info)]) {
        free(images);
        return result;
    }

    NSString *lower = moduleName.lowercaseString;
    for (uint32_t i = 0; i < imgCount; i++) {
        char pathBuf[1024] = {0};
        [self readAddress:(uint64_t)images[i].imageFilePath
                    buffer:pathBuf size:sizeof(pathBuf) - 1];

        NSString *path = [NSString stringWithUTF8String:pathBuf];
        if (path.length == 0) continue;
        NSString *modName = path.lastPathComponent.stringByDeletingPathExtension;

        if (modName.length > 0 &&
            ([modName.lowercaseString containsString:lower] ||
             [lower containsString:modName.lowercaseString])) {
            uint64_t start = (uint64_t)images[i].imageLoadAddress;
            [result addObject:@{
                @"start": [NSString stringWithFormat:@"%llu", start],
                @"end":   [NSString stringWithFormat:@"%llu", start + 0x4000000],
                @"name":  modName
            }];
            break;
        }
    }
    free(images);
    return result;
}

#pragma mark - 内存读写

- (BOOL)readAddress:(uint64_t)addr buffer:(void *)buf size:(size_t)size {
    if (!self.attached) return NO;
    vm_size_t readSize = size;
    return (vm_read_overwrite(self.targetTask, addr, size,
                              (vm_address_t)buf, &readSize) == KERN_SUCCESS);
}

- (BOOL)writeAddress:(uint64_t)addr buffer:(const void *)buf size:(size_t)size {
    if (!self.attached) return NO;
    return (vm_write(self.targetTask, addr, (vm_address_t)buf, size) == KERN_SUCCESS);
}

- (NSNumber *)getValue:(uint64_t)addr type:(NSString *)type {
    if ([type isEqualToString:@"F32"]) {
        float v = 0;
        if (![self readAddress:addr buffer:&v size:4]) return nil;
        return @(v);
    } else if ([type isEqualToString:@"I64"]) {
        uint64_t v = 0;
        if (![self readAddress:addr buffer:&v size:8]) return nil;
        return @((unsigned long long)v);
    } else if ([type isEqualToString:@"I32"]) {
        uint32_t v = 0;
        if (![self readAddress:addr buffer:&v size:4]) return nil;
        return @(v);
    }
    return nil;
}

- (BOOL)setValue:(uint64_t)addr value:(double)value type:(NSString *)type {
    if ([type isEqualToString:@"F32"]) {
        float v = (float)value;
        return [self writeAddress:addr buffer:&v size:4];
    } else if ([type isEqualToString:@"I64"]) {
        uint64_t v = (uint64_t)value;
        return [self writeAddress:addr buffer:&v size:8];
    } else if ([type isEqualToString:@"I32"]) {
        uint32_t v = (uint32_t)value;
        return [self writeAddress:addr buffer:&v size:4];
    }
    return NO;
}

@end
