using System.Runtime.CompilerServices;

namespace SiteBlock.Integration.Tests.Support;

// Raises the thread pool's minimum before any test runs. The test helpers wait on pool threads (RawConnection.ReadLine and DaemonClient.Send both block on async
// work), and with every test class running in parallel on a small machine the pool runs out; .NET then adds about one thread per half second, so a request's
// reply can sit in the queue until some other test's wait ends. That made timing tests measure the test process instead of the server: on GitHub's runner a status
// reply was picked up 10 ms after a silent client's 2-second timeout freed a thread. With enough threads ready, no helper waits behind another.
internal static class ThreadPoolWarmup
{
    // Runs once when the test assembly loads, before the first test.
    [ModuleInitializer]
    internal static void Raise()
    {
        ThreadPool.GetMinThreads(out int workers, out int io);
        ThreadPool.SetMinThreads(Math.Max(workers, 64), Math.Max(io, 64));
    }
}
