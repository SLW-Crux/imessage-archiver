//
//  AttributedBodyDecoderShim.m
//
//  See header for rationale. This file is Mac-only; the iOS target
//  excludes it (project.yml sources excludes block).
//

#import "AttributedBodyDecoderShim.h"

#if TARGET_OS_OSX

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wobjc-method-access"

id HonkDecodeLegacyTypedstream(NSData *data) {
    @try {
        NSUnarchiver *unarchiver = [[NSUnarchiver alloc] initForReadingWithData:data];
        if (unarchiver == nil) {
            return nil;
        }
        return [unarchiver decodeObject];
    } @catch (NSException *e) {
        // Malformed typedstream — common on truncated or corrupted
        // chat.db rows. Swallow and return nil so the caller treats
        // the message as having no decodable text.
        return nil;
    }
}

#pragma clang diagnostic pop

#else  // !TARGET_OS_OSX

id HonkDecodeLegacyTypedstream(NSData *data) {
    return nil;  // iOS doesn't run the archiver — never called.
}

#endif
