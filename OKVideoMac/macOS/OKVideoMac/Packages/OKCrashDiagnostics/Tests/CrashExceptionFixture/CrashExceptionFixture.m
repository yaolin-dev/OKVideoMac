#import <Foundation/Foundation.h>
#import "CrashExceptionFixture.h"

__attribute__((noinline)) void ok_fixture_original_throw(void) {
    @throw [NSException exceptionWithName:NSGenericException
        reason:@"The window has been marked as needing another Update Constraints in Window pass. URL=https://private.invalid/video?token=SECRET /Users/private/video.mov title='PRIVATE_TITLE'"
        userInfo:@{@"private": @"DO_NOT_SEND"}];
}

__attribute__((noinline)) void ok_fixture_rethrow(void) {
    @try { ok_fixture_original_throw(); }
    @catch (NSException *exception) { @throw; }
}
