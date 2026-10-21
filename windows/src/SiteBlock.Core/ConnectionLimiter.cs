namespace SiteBlock.Core;

/// <summary>
/// Decides whether the pipe server may take on one more connection, and keeps count of the open ones. It stops one account from holding every slot with idle connections and locking everyone else out,
/// and it keeps a few slots free for administrators so an administrator's command can always get through. It is safe to call from any thread.
/// </summary>
public sealed class ConnectionLimiter
{
    // The most connections one non-admin user ID may hold open at once.
    private readonly int _perUserLimit;
    // The most connections open at once, administrators and everyone else together.
    private readonly int _total;
    // Slots that only administrators may use: a non-admin connection is refused once the open count reaches total - adminReserved.
    private readonly int _adminReserved;
    // One lock guards the three counts below, which the accept loop and the connection handlers all touch.
    private readonly Lock _lock = new();
    private int _adminOpen;
    private int _nonAdminOpen;
    // Open connections per non-admin user ID (an ID with none open has no entry).
    private readonly Dictionary<string, int> _openByUser = new(StringComparer.Ordinal);

    /// <summary>Creates a limiter. The defaults are the service's real limits: 4 connections per non-admin user, 32 in total, and the last 4 slots kept for administrators.</summary>
    public ConnectionLimiter(int perUserLimit = 4, int total = 32, int rootReserved = 4)
    {
        _perUserLimit = perUserLimit;
        _total = total;
        _adminReserved = rootReserved;
    }

    /// <summary>
    /// Decides whether a new connection from this caller may be served, and counts it if so. An administrator is admitted while fewer than <c>total</c> connections are open.
    /// Anyone else is admitted while their user ID holds fewer than <c>perUserLimit</c> connections and fewer than <c>total - rootReserved</c> connections are open in all, so administrators can always take the last slots.
    /// <see cref="Peer.Unknown"/>, used when the caller's identity cannot be read, is an ordinary non-admin user here.
    /// </summary>
    public bool Admit(Peer peer)
    {
        ArgumentNullException.ThrowIfNull(peer);
        lock (_lock)
        {
            int open = _adminOpen + _nonAdminOpen;
            if (peer.IsAdmin)
            {
                if (open >= _total) return false;
                _adminOpen++;
            }
            else
            {
                int held = _openByUser.GetValueOrDefault(peer.UserId);
                if (open >= _total - _adminReserved || held >= _perUserLimit) return false;
                _openByUser[peer.UserId] = held + 1;
                _nonAdminOpen++;
            }
            return true;
        }
    }

    /// <summary>
    /// Gives back the slot taken by <see cref="Admit"/> when a connection has been served. A release with nothing to give back (the user holds no connection) changes nothing,
    /// so a count never goes below zero and one user can never free another's slot. Pass the same peer that was admitted.
    /// </summary>
    public void Release(Peer peer)
    {
        ArgumentNullException.ThrowIfNull(peer);
        lock (_lock)
        {
            if (peer.IsAdmin)
            {
                if (_adminOpen > 0) _adminOpen--;
                return;
            }
            if (!_openByUser.TryGetValue(peer.UserId, out int held) || held <= 0) return;
            if (held > 1) _openByUser[peer.UserId] = held - 1;
            else _openByUser.Remove(peer.UserId);
            _nonAdminOpen--;
        }
    }
}
