import Foundation

/// Cancels an in-flight download/start when the owner changes or the user stops.
public struct VPNAttempt {
    private var generation = UUID()
    public private(set) var ownerID: Int?
    public init() {}
    public mutating func changeOwner(_ ownerID: Int?) {
        if self.ownerID != ownerID { cancel(); self.ownerID = ownerID }
    }
    public mutating func begin() -> UUID { generation = UUID(); return generation }
    public mutating func cancel() { generation = UUID() }
    public func accepts(_ token: UUID, ownerID: Int) -> Bool {
        generation == token && self.ownerID == ownerID
    }
}
