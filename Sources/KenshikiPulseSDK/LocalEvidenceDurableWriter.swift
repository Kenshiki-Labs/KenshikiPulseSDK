import Foundation

struct LocalEvidenceDurableWriteHealth: Equatable, Sendable {
    public let attemptedAt: Date
    public let success: Bool
    public let attemptedRowCount: Int
    public let pendingRowCount: Int
    public let droppedRowCount: Int
    public let error: String?

    public init(
        attemptedAt: Date,
        success: Bool,
        attemptedRowCount: Int,
        pendingRowCount: Int,
        droppedRowCount: Int,
        error: String?
    ) {
        self.attemptedAt = attemptedAt
        self.success = success
        self.attemptedRowCount = attemptedRowCount
        self.pendingRowCount = pendingRowCount
        self.droppedRowCount = droppedRowCount
        self.error = error
    }
}

/// Small durable write buffer for sensor-boundary lake writes. It preserves bounded windows across
/// transient SQLite failures and reports backlog/drop health instead of silently losing evidence.
actor LocalEvidenceDurableWriter {
    private let store: LocalEvidenceLakeStoring
    private let maxPendingRows: Int
    private var pending: [LocalEvidenceWindow] = []
    private var droppedRows = 0
    private var isFlushing = false

    public init(store: LocalEvidenceLakeStoring, maxPendingRows: Int = 500) {
        self.store = store
        self.maxPendingRows = max(1, maxPendingRows)
    }

    @discardableResult
    public func append(_ window: LocalEvidenceWindow, now: Date = Date()) async -> LocalEvidenceDurableWriteHealth {
        pending.append(window)
        trimOverflow()
        return await flush(now: now)
    }

    @discardableResult
    public func flush(now: Date = Date()) async -> LocalEvidenceDurableWriteHealth {
        guard !pending.isEmpty else {
            return LocalEvidenceDurableWriteHealth(
                attemptedAt: now,
                success: true,
                attemptedRowCount: 0,
                pendingRowCount: 0,
                droppedRowCount: droppedRows,
                error: nil
            )
        }
        guard !isFlushing else {
            return LocalEvidenceDurableWriteHealth(
                attemptedAt: now,
                success: true,
                attemptedRowCount: 0,
                pendingRowCount: pending.count,
                droppedRowCount: droppedRows,
                error: nil
            )
        }

        isFlushing = true
        defer { isFlushing = false }

        var attemptedRows = 0
        while !pending.isEmpty {
            let batch = pending
            pending.removeAll(keepingCapacity: true)

            do {
                try await store.append(contentsOf: batch)
                attemptedRows += batch.count
            } catch {
                pending = batch + pending
                trimOverflow()
                return LocalEvidenceDurableWriteHealth(
                    attemptedAt: now,
                    success: false,
                    attemptedRowCount: attemptedRows + batch.count,
                    pendingRowCount: pending.count,
                    droppedRowCount: droppedRows,
                    error: error.localizedDescription
                )
            }
        }

        return LocalEvidenceDurableWriteHealth(
            attemptedAt: now,
            success: true,
            attemptedRowCount: attemptedRows,
            pendingRowCount: pending.count,
            droppedRowCount: droppedRows,
            error: nil
        )
    }

    public func pendingCount() -> Int { pending.count }

    private func trimOverflow() {
        guard pending.count > maxPendingRows else { return }
        let overflow = pending.count - maxPendingRows
        pending.removeFirst(overflow)
        droppedRows += overflow
    }
}
