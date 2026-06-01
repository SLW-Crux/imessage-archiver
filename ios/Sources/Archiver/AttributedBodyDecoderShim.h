//
//  AttributedBodyDecoderShim.h
//
//  ObjC bridge that wraps NSUnarchiver in @try/@catch so a malformed
//  typedstream blob can't bubble an NSException up to Swift (which has
//  no way to catch it — the exception aborts the entire process).
//  Review finding MH1.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decode `data` as a legacy typedstream blob. Returns the decoded
/// top-level object (`NSAttributedString`, `NSString`, etc.), or nil if
/// the blob is not a valid typedstream OR the decoder raised an
/// NSException mid-parse.
///
/// The caller has already validated that `data` is non-nil and within
/// the 2 MiB size cap.
id _Nullable HonkDecodeLegacyTypedstream(NSData *data);

NS_ASSUME_NONNULL_END
