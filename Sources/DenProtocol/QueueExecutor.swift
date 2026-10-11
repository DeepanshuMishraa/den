import Dispatch

/// Runs an actor's jobs on a serial dispatch queue, so dispatch sources
/// targeting that queue can `assumeIsolated` into the actor. Works where
/// `DispatchSerialQueue` doesn't exist (Linux).
public final class QueueExecutor: SerialExecutor, @unchecked Sendable {
    public let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Code already on the queue (a dispatch source handler) is isolated.
    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
