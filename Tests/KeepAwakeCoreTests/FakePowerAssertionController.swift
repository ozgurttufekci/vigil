import Foundation
import PowerAssertions

/// Records every call so tests can assert on exact sequences, especially create/release ordering.
final class FakePowerAssertionController: PowerAssertionControlling, @unchecked Sendable {
    struct CreateCall: Equatable {
        let kind: AssertionKind
        let name: String
        let details: String?
        let timeout: TimeInterval
        let id: PowerAssertionID
    }

    enum Event: Equatable {
        case create(CreateCall)
        case release(PowerAssertionID)
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var _nextID: UInt32 = 1
    private var _live: Set<PowerAssertionID> = []
    private var _failNextCreate: PowerAssertionError?
    private var _failNextRelease: PowerAssertionError?
    private var _alwaysFailRelease = false

    var events: [Event] { lock.withLock { _events } }
    var liveIDs: Set<PowerAssertionID> { lock.withLock { _live } }

    var creates: [CreateCall] {
        events.compactMap { if case .create(let call) = $0 { call } else { nil } }
    }

    func failNextCreate(with error: PowerAssertionError) {
        lock.withLock { _failNextCreate = error }
    }

    func failNextRelease(with error: PowerAssertionError) {
        lock.withLock { _failNextRelease = error }
    }

    func alwaysFailRelease() {
        lock.withLock { _alwaysFailRelease = true }
    }

    func reset() {
        lock.withLock {
            _events = []
            _live = []
        }
    }

    func create(
        kind: AssertionKind,
        name: String,
        details: String?,
        timeout: TimeInterval
    ) throws -> PowerAssertionID {
        try lock.withLock {
            if let error = _failNextCreate {
                _failNextCreate = nil
                throw error
            }
            guard timeout > 0 else { throw InvalidTimeoutError(timeout: timeout) }
            let id = PowerAssertionID(rawValue: _nextID)
            _nextID += 1
            _live.insert(id)
            _events.append(
                .create(
                    CreateCall(kind: kind, name: name, details: details, timeout: timeout, id: id)
                )
            )
            return id
        }
    }

    func release(_ id: PowerAssertionID) throws {
        try lock.withLock {
            _events.append(.release(id))
            if _alwaysFailRelease {
                throw PowerAssertionError(code: -536_870_206, operation: "release")
            }
            if let error = _failNextRelease {
                _failNextRelease = nil
                // Deliberately left in `_live`: a failed release means the assertion is still held.
                throw error
            }
            _live.remove(id)
        }
    }
}
