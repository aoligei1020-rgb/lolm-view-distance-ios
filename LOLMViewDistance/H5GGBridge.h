//
//  H5GGBridge.h
//  LOLMViewDistance
//
//  原生 h5gg 兼容层：进程绑定 + 模块基址 + 内存读写
//  TrollStore 签名自带 platform-application entitlement，
//  因此 task_for_pid 可绑定同机任意进程。
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

@interface H5GGBridge : NSObject

+ (instancetype)shared;

/// 通过进程名模糊搜索进程，返回 [{pid, name}]
- (NSArray<NSDictionary *> *)getProcList:(NSString *)name;

/// 绑定目标进程 (task_for_pid)
- (BOOL)setTargetProc:(pid_t)pid;

/// 获取模块基址，返回 [{start, end, name}]（地址为十进制字符串，避免精度丢失）
- (NSArray<NSDictionary *> *)getRangesList:(NSString *)moduleName;

/// 读内存，type: "F32" / "I64"，返回 NSNumber 或 nil
- (nullable NSNumber *)getValue:(uint64_t)addr type:(NSString *)type;

/// 写内存，type: "F32" / "I64"
- (BOOL)setValue:(uint64_t)addr value:(double)value type:(NSString *)type;

/// 诊断信息（含 libproc 枚举统计 + LOLM 扫描结果，/diag 路由使用）
- (NSDictionary *)diag;

@end

NS_ASSUME_NONNULL_END
