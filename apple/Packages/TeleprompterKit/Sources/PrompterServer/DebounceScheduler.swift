import Foundation

/// Retrasa una tarea, con una regla: **un aviso urgente ya pendiente no se
/// retrasa por uno perezoso posterior**.
///
/// Sin esa regla, mover el dedo por el guion —que pide guardar con calma— iría
/// aplazando indefinidamente el guardado del texto que acabas de escribir.
@MainActor
public final class DebounceScheduler {
    private var task: Task<Void, Never>?
    private var dueAt: ContinuousClock.Instant?
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        task?.cancel()
    }

    public func schedule(after delay: Duration) {
        let candidate = ContinuousClock.now + delay
        if let dueAt, candidate >= dueAt, task != nil { return }

        task?.cancel()
        dueAt = candidate
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    /// Ejecuta ya lo que estuviera pendiente. Se usa al cerrar la app: la
    /// posición espera cinco segundos y no vale la pena perderla por eso.
    public func flush() {
        guard task != nil else { return }
        task?.cancel()
        fire()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        dueAt = nil
    }

    private func fire() {
        task = nil
        dueAt = nil
        action()
    }

    public var isPending: Bool { task != nil }
}
