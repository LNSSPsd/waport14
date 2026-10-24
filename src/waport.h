// Shared between the shim's source files (not exported).
#import <Foundation/Foundation.h>
#import <objc/message.h>

#ifndef WAPORT_BUILD
#define WAPORT_BUILD "dev"
#endif

#ifndef WAPORT_LOG
#define WAPORT_LOG 0
#endif

__attribute__((visibility("hidden"))) void waport_log(NSString *msg);
__attribute__((visibility("hidden"))) void waport_install_diagnostics(void);
__attribute__((visibility("hidden"))) int waport_memlimit(void);

#if WAPORT_LOG
#define shimlog(...) waport_log([NSString stringWithFormat:__VA_ARGS__])
#else
#define shimlog(...) ((void)0)
#endif

#define MSG(ret, ...) ((ret (*)(__VA_ARGS__))objc_msgSend)
