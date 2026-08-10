#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception it raises and returning
/// it (nil when the block completes normally).
///
/// Exists because some Apple frameworks signal runtime misconfiguration by
/// raising NSExceptions — AVFAudio's `installTapOnBus:` raises when handed a
/// stale device format — and Swift cannot catch those. Worse, an NSException
/// unwinding through Swift-concurrency frames skips the runtime's executor-
/// tracking pop, leaving the thread poisoned: observed 2026-08-11 as a
/// delayed SIGSEGV in `MainActor.assumeIsolated` on the next button click.
/// Wrap any exception-prone framework call made from async code in this.
FOUNDATION_EXPORT NSException * _Nullable MSTDCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
