import Foundation

/// What to do after a delegated agent turn fails. Pure decision — the coordinator
/// applies the side effects (pause the runtime, requeue with a future attempt time,
/// move to Needs Review as completion-uncertain, or give up).
public enum AgentRetryAction: Equatable, Sendable {
    /// Authentication is required; pause the whole runtime without consuming the task.
    case pauseRuntime
    /// Safe to retry after a bounded delay.
    case retryAfter(seconds: TimeInterval)
    /// The turn touched an external artifact and it is unknown whether it completed;
    /// send to Needs Review rather than silently retrying (avoids duplicate creation).
    case completionUncertain
    /// No more automatic retries — surface the failure for review.
    case fail
}

public enum AgentRetryPolicy {
    /// Bounded backoff schedule for safe local retries; index is the retry count so far.
    static let backoffSeconds: [TimeInterval] = [60, 300, 900]

    /// Decide the recovery action for a failed turn.
    ///
    /// - `retryCount`: how many automatic retries have already been spent on this run.
    public static func action(
        for failure: AgentRuntimeFailure,
        action: RecommendationAction?,
        retryCount: Int = 0
    ) -> AgentRetryAction {
        switch failure {
        case .authenticationRequired:
            return .pauseRuntime

        case .timedOut, .process:
            // Timeout / process death is ambiguous: the external artifact may or may not
            // have been created. For outward-facing (gated) actions we must not retry
            // blindly — hand it to review. Safe local work backs off and retries.
            if action?.isGated == true { return .completionUncertain }
            return backoff(retryCount)

        case .rateLimited, .malformedOutput, .sessionMissing:
            // No committed external side effect (rate limit is pre-run; malformed/lost
            // session are recoverable), so a bounded retry is safe even for gated actions.
            return backoff(retryCount)

        case .cancelled:
            // Cancellation is deliberate (user take-back or runtime cancel) — never an
            // automatic retry. The coordinator handles it as a cancelled outcome directly.
            return .fail
        }
    }

    private static func backoff(_ retryCount: Int) -> AgentRetryAction {
        guard retryCount >= 0, retryCount < backoffSeconds.count else { return .fail }
        return .retryAfter(seconds: backoffSeconds[retryCount])
    }
}
