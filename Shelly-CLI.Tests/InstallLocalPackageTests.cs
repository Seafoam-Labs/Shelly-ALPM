using Shelly_CLI.Commands.Standard;
using Spectre.Console.Cli;

namespace Shelly_CLI.Tests;

[TestFixture]
public class InstallLocalPackageTests
{
    private string _tempDir = null!;
    private InstallLocalPackageCommand _command = null!;

    [SetUp]
    public void SetUp()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "shelly-cli-tests-" + Guid.NewGuid());
        Directory.CreateDirectory(_tempDir);
        _command = new InstallLocalPackageCommand();
    }

    [TearDown]
    public void TearDown()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, true);
    }

    private static CommandContext CreateCommandContext()
    {
        return new CommandContext([], new EmptyRemainingArguments(), "install-local", null);
    }

    private class EmptyRemainingArguments : IRemainingArguments
    {
        public ILookup<string, string?> Parsed => Array.Empty<string>().ToLookup(_ => "", _ => (string?)null);
        public IReadOnlyList<string> Raw => Array.Empty<string>();
    }

    #region ExecuteAsync - Validation Tests

    [Test]
    public async Task ExecuteAsync_EmptyPackageLocation_Returns1()
    {
        var settings = new InstallLocalPackageSettings { PackageLocation = string.Empty };
        var result = await _command.ExecuteAsync(CreateCommandContext(), settings);
        Assert.That(result, Is.EqualTo(1));
    }

    [Test]
    public async Task ExecuteAsync_NonExistentFile_Returns1()
    {
        var settings = new InstallLocalPackageSettings
        {
            PackageLocation = Path.Combine(_tempDir, "nonexistent.pkg.tar.gz")
        };
        var result = await _command.ExecuteAsync(CreateCommandContext(), settings);
        Assert.That(result, Is.EqualTo(1));
    }

    #endregion
}
