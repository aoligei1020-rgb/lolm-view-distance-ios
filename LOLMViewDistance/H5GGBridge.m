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

@interface H5GGBridge ()
@property (nonatomic, assign) pid_t targetPID;
@property (nonatomic, assign) task_t targetTask;
@property (nonatomic, assign) BOOL attached;
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

- (NSArray<NSDictionary *> *)getProcList:(NSString *)name {
    NSMutableArray *result = [NSMutableArray array];
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return result;

    struct kinfo_proc *procList = malloc(size);
    if (!procList) return result;
    if (sysctl(mib, 4, procList, &size, NULL, 0) != 0) {
        free(procList);
        return result;
    }

    int count = (int)(size / sizeof(struct kinfo_proc));
    NSString *lower = name.lowercaseString;
    for (int i = 0; i < count; i++) {
        NSString *procName = [NSString stringWithUTF8String:procList[i].kp_proc.p_comm];
        if (procName.length == 0) continue;
        // p_comm 最多 16 字符，lolm 进程名可能是 lolm 或类似
        if ([procName.lowercaseString containsString:lower] ||
            [lower containsString:procName.lowercaseString]) {
            [result addObject:@{
                @"pid": @(procList[i].kp_proc.p_pid),
                @"name": procName
            }];
        }
    }
    free(procList);
    return result;
}

#pragma mark - 进程绑定

- (BOOL)setTargetProc:(pid_t)pid {
    if (pid <= 0) return NO;
    static task_for_pid_t s_task_for_pid = NULL;
    if (!s_task_for_pid) {
        s_task_for_pid = (task_for_pid_t)dlsym(RTLD_DEFAULT, "task_for_pid");
    }
    if (!s_task_for_pid) return NO;

    task_t task = TASK_NULL;
    kern_return_t kr = s_task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return NO;

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
