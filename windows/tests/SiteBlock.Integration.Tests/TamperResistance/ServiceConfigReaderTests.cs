using SiteBlock.Service;

namespace SiteBlock.Integration.Tests.TamperResistance;

// ServiceConfigReader.FromValues turns a service's raw registry values into a ServiceConfig. It is pure, so it runs on the Mac.
// Expected values come from 06-windows.md § ServiceGuard (the registry value names, DeleteFlag, the start codes and the dependency merge).
public sealed class ServiceConfigReaderTests
{
    [Fact]
    public void FromValues_DeleteFlagSet_CountsAsMissing()
    {
        // A service marked for deletion counts as gone, whatever its other values say.
        var config = ServiceConfigReader.FromValues(2, 0x10, "\"C:\\x\\siteblockd.exe\" --daemon", "LocalSystem", null, null, 1);

        Assert.False(config.Exists);
        Assert.Equal(ServiceStartType.Unknown, config.StartType);
        Assert.Null(config.BinaryPath);
    }

    [Theory]
    [InlineData(2, ServiceStartType.Automatic)]
    [InlineData(3, ServiceStartType.Manual)]
    [InlineData(4, ServiceStartType.Disabled)]
    [InlineData(99, ServiceStartType.Unknown)]
    public void FromValues_StartCode_MapsToStartType(int code, ServiceStartType expected)
    {
        var config = ServiceConfigReader.FromValues(code, 0x10, "path", "LocalSystem", null, null, 0);

        Assert.True(config.Exists);
        Assert.Equal(expected, config.StartType);
    }

    [Fact]
    public void FromValues_MissingStartValue_IsUnknown()
    {
        var config = ServiceConfigReader.FromValues(null, null, null, null, null, null, null);

        Assert.True(config.Exists);
        Assert.Equal(ServiceStartType.Unknown, config.StartType);
    }

    [Fact]
    public void FromValues_MergesServiceAndGroupDependenciesAndDropsBlanks()
    {
        var config = ServiceConfigReader.FromValues(2, 0x10, "path", "LocalSystem", new[] { "Tcpip", "   " }, new[] { "NetBT", "" }, 0);

        Assert.NotNull(config.Dependencies);
        Assert.Equal(new[] { "Tcpip", "NetBT" }, config.Dependencies!);
    }

    [Fact]
    public void FromValues_NoDependencies_GivesEmptyList()
    {
        var config = ServiceConfigReader.FromValues(2, 0x10, "path", "LocalSystem", null, null, 0);

        Assert.NotNull(config.Dependencies);
        Assert.Empty(config.Dependencies!);
    }

    [Fact]
    public void FromValues_KeepsTypeCodeAccountAndImagePath()
    {
        var config = ServiceConfigReader.FromValues(2, 0x10, "\"C:\\x\\siteblockd.exe\" --daemon", "LocalSystem", null, null, 0);

        Assert.Equal(0x10, config.TypeCode);
        Assert.Equal("LocalSystem", config.Account);
        Assert.Equal("\"C:\\x\\siteblockd.exe\" --daemon", config.BinaryPath);
    }

    [Fact]
    public void FromValues_UnknownTypeAndAccount_AreNull()
    {
        var config = ServiceConfigReader.FromValues(2, null, null, null, null, null, 0);

        Assert.Null(config.TypeCode);
        Assert.Null(config.Account);
    }
}
