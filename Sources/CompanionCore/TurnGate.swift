import Foundation
/// Invalidates outputs across interruption, deletion and conversation boundaries.
public struct TurnGate {
    public private(set) var isOpen = false
    private var revision = 0
    public init() {}
    public mutating func open() { revision += 1; isOpen = true }
    public mutating func close() { revision += 1; isOpen = false }
    public mutating func invalidate() { revision += 1 }
    public mutating func beginTurn() -> Int? {
        guard isOpen else { return nil }
        revision += 1
        return revision
    }
    public func accepts(_ token: Int) -> Bool { isOpen && token == revision }
}
