#import "PrivatePiP.h"
int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL missing = argc > 1 && strcmp(argv[1], "--simulate-unavailable") == 0;
        NSDictionary *result = OKProbePiP(missing);
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
        return [result[@"requiredAPICompatible"] boolValue] != !missing;
    }
}
