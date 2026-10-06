import Foundation

/// Decides whether the socket server may take on one more connection, and keeps count of the open ones. It stops one account from holding every slot with idle connections and locking everyone else out, and it keeps a few slots free for root so a root command can always get through. It is safe to call from any thread.
public final class ConnectionLimiter: @unchecked Sendable {
    // The most connections one non-root user ID may hold open at once.
    private let perUserLimit: Int
    // The most connections open at once, root and everyone else together.
    private let total: Int
    // Slots that only root may use: a non-root connection is refused once the open count reaches `total - rootReserved`.
    private let rootReserved: Int
    // One lock guards the three counts below, which the accept thread and the client threads all touch.
    private let lock = NSLock()
    private var rootOpen = 0
    private var nonRootOpen = 0
    // Open connections per non-root user ID (an ID with none open has no entry).
    private var openByUser: [uid_t: Int] = [:]

    /// Creates a limiter. The defaults are the daemon's real limits: 4 connections per non-root user ID, 32 in total, and the last 4 slots kept for root.
    public init(perUserLimit: Int = 4, total: Int = 32, rootReserved: Int = 4) {
        self.perUserLimit = perUserLimit
        self.total = total
        self.rootReserved = rootReserved
    }

    /// Decides whether a new connection from this user ID may be served, and counts it if so. Root is admitted while fewer than `total` connections are open. A non-root user ID is admitted while it holds fewer than `perUserLimit` connections and fewer than `total - rootReserved` connections are open in all, so root can always take the last slots. The ID `UInt32.max`, which the server uses when it cannot read the caller's ID, is an ordinary non-root user here.
    public func admit(uid: uid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let open = rootOpen + nonRootOpen
        if uid == 0 {
            guard open < total else { return false }
            rootOpen += 1
        } else {
            guard open < total - rootReserved, openByUser[uid, default: 0] < perUserLimit else { return false }
            openByUser[uid, default: 0] += 1
            nonRootOpen += 1
        }
        return true
    }

    /// Gives back the slot taken by `admit` when a connection has been served. A release with nothing to give back (the user ID holds no connection) changes nothing, so a count never goes below zero and one user ID can never free another's slot.
    public func release(uid: uid_t) {
        lock.lock()
        defer { lock.unlock() }
        if uid == 0 {
            if rootOpen > 0 { rootOpen -= 1 }
            return
        }
        guard let held = openByUser[uid], held > 0 else { return }
        openByUser[uid] = held > 1 ? held - 1 : nil
        nonRootOpen -= 1
    }
}
