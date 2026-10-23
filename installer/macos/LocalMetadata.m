// Native metadata only. No account credentials, network client, or remote fallback.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <sys/sysctl.h>

static NSString *systemValue(const char *key) {
    char value[256] = {0}; size_t size = sizeof(value);
    if (sysctlbyname(key, value, &size, NULL, 0) != 0) return nil;
    return [NSString stringWithUTF8String:value];
}

int main(void) {
    @autoreleasepool {
        @try {
            NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AOSKit.framework"];
            if (![bundle load]) return 2;
            Class utilities = NSClassFromString(@"AOSUtilities");
            SEL selector = NSSelectorFromString(@"retrieveOTPHeadersForDSID:");
            if (!utilities || ![utilities respondsToSelector:selector]) return 2;
            id headers = ((id (*)(id, SEL, id))objc_msgSend)(utilities, selector, @"-2");
            if (![headers isKindOfClass:[NSDictionary class]]) return 3;
            id otp = headers[@"X-Apple-MD"], machine = headers[@"X-Apple-MD-M"];
            if (![otp isKindOfClass:[NSString class]] || ![otp length] ||
                ![machine isKindOfClass:[NSString class]] || ![machine length]) return 3;
            // Use the identity supplied by the same framework as the OTP.
            // An IORegistry UUID and a hash are not a substitute for this pair.
            SEL identitySelector = NSSelectorFromString(@"machineUDID");
            if (![utilities respondsToSelector:identitySelector]) return 4;
            id identifier = ((id (*)(id, SEL))objc_msgSend)(utilities, identitySelector);
            NSString *model = systemValue("hw.model"), *build = systemValue("kern.osversion");
            if (![identifier isKindOfClass:[NSString class]] || ![[NSUUID alloc] initWithUUIDString:identifier] || !model || !build) return 4;
            NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
            NSString *client = [NSString stringWithFormat:@"<%@> <macOS;%ld.%ld.%ld;%@> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", model, (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion, build];
            NSString *kernel = systemValue("kern.osrelease");
            if (!kernel) return 4;
            NSString *agent = [NSString stringWithFormat:@"akd/1.0 Darwin/%@", kernel];
            NSDictionary *result = @{@"otp":otp, @"machine":machine, @"identifier":identifier, @"client":client, @"user_agent":agent};
            NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            if (!data || data.length > 65536) return 5;
            return fwrite(data.bytes, 1, data.length, stdout) == data.length ? 0 : 5;
        } @catch (NSException *exception) {
            // Native exception text can contain private metadata. Do not emit it.
            return 6;
        }
    }
}
