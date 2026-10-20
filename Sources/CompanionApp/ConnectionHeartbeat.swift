import Foundation

@MainActor final class ConnectionHeartbeat {
    typealias Probe = (@escaping @Sendable (Bool) -> Void) -> Void
    private let interval: UInt64, timeout: UInt64
    private var probe: Probe?, failure: (() -> Void)?
    private var next: Task<Void, Never>?, deadline: Task<Void, Never>?
    private var epoch = 0, sequence = 0
    private var pending: Int?

    init(interval: UInt64 = 10_000_000_000, timeout: UInt64 = 8_000_000_000) {
        self.interval = interval; self.timeout = timeout
    }
    deinit { next?.cancel(); deadline?.cancel() }
    func start(probe: @escaping Probe, onFailure: @escaping () -> Void) {
        stop(); self.probe = probe; failure = onFailure; schedule()
    }
    func stop() {
        epoch += 1; next?.cancel(); deadline?.cancel()
        next = nil; deadline = nil; pending = nil; probe = nil; failure = nil
    }
    private func schedule() {
        let token = epoch, delay = interval
        next = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.epoch == token else { return }
            self.next = nil; self.check()
        }
    }
    private func check() {
        guard pending == nil, let probe else { return }
        sequence += 1
        let request = sequence, token = epoch, delay = timeout
        pending = request
        // Independent deadline: a transport that never calls back must still terminate.
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.complete(false, request: request, epoch: token)
        }
        probe { [weak self] healthy in
            Task { @MainActor in self?.complete(healthy, request: request, epoch: token) }
        }
    }
    private func complete(_ healthy: Bool, request: Int, epoch token: Int) {
        guard epoch == token, pending == request else { return }
        deadline?.cancel(); deadline = nil; pending = nil
        if healthy { schedule() }
        else {
            let callback = failure
            stop()
            callback?()
        }
    }
}
