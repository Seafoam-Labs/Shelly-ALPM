using System.Collections.Generic;
using PackageManager.Aur;

namespace PackageManager.Tests.Aur;

public class VcsSourceParserTests
{
    [Test]
    public void ParseSource_GitPlusHttps_ReturnsEntry()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git");
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Url, Is.EqualTo("https://github.com/user/repo.git"));
        Assert.That(result.Branch, Is.EqualTo(string.Empty));
        Assert.That(result.Protocols, Does.Contain("https"));
        Assert.That(result.Protocols, Does.Not.Contain("git"));
    }

    [Test]
    public void ParseSource_WithNamePrefix_StripsName()
    {
        var result = VcsSourceParser.ParseSource("myrepo::git+https://github.com/user/repo.git");
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Url, Is.EqualTo("https://github.com/user/repo.git"));
    }

    [Test]
    public void ParseSource_WithBranchFragment_ParsesBranch()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git#branch=develop");
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Url, Is.EqualTo("https://github.com/user/repo.git"));
        Assert.That(result.Branch, Is.EqualTo("develop"));
    }

    [Test]
    public void ParseSource_WithCommitFragment_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git#commit=abc123");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_WithTagFragment_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git#tag=v1.0");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_NonGitSource_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource("https://example.com/archive.tar.gz");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_WithQueryParams_StripsQuery()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git?signed");
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Url, Is.EqualTo("https://github.com/user/repo.git"));
    }

    [Test]
    public void ParseSource_EmptyString_ReturnsNull()
    {
        Assert.That(VcsSourceParser.ParseSource(""), Is.Null);
        Assert.That(VcsSourceParser.ParseSource("   "), Is.Null);
    }

    [Test]
    public void ParseSources_MixedSources_ReturnsOnlyGit()
    {
        var sources = new[]
        {
            "git+https://github.com/user/repo.git",
            "https://example.com/archive.tar.gz",
            "git+https://github.com/user/repo2.git#commit=abc",
            "myname::git+https://github.com/user/repo3.git#branch=main"
        };

        var results = VcsSourceParser.ParseSources(sources);
        Assert.That(results, Has.Count.EqualTo(2));
        Assert.That(results[0].Url, Is.EqualTo("https://github.com/user/repo.git"));
        Assert.That(results[1].Url, Is.EqualTo("https://github.com/user/repo3.git"));
        Assert.That(results[1].Branch, Is.EqualTo("main"));
    }

    [Test]
    public void ParseSource_NamedWithColonColon_HandlesCorrectly()
    {
        var result = VcsSourceParser.ParseSource("pkg-name::git+https://gitlab.com/org/project.git");
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Url, Is.EqualTo("https://gitlab.com/org/project.git"));
    }

    [Test]
    public void ParseSource_NoFragment_BranchIsEmpty()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git");
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Branch, Is.EqualTo(string.Empty));
    }

    [Test]
    public void ParseSource_BranchWithBashBraceVariable_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource(
            "zfs::git+https://github.com/openzfs/zfs.git#branch=${_staging_branch}");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_BranchWithBashCommandSubstitution_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource(
            "git+https://github.com/user/repo.git#branch=$(echo main)");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_BranchWithBareDollarVariable_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource(
            "git+https://github.com/user/repo.git#branch=$mybranch");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_EmptyBranchFragment_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git#branch=");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_WhitespaceBranchFragment_ReturnsNull()
    {
        var result = VcsSourceParser.ParseSource("git+https://github.com/user/repo.git#branch=   ");
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_ZfsDkmsStagingGit_StaticPkgbuildLine_IsNotTrackable()
    {
        var sources = new[]
        {
            "zfs::git+https://github.com/openzfs/zfs.git#branch=${_staging_branch}"
        };

        var results = VcsSourceParser.ParseSources(sources);
        Assert.That(results, Is.Empty);
    }

    [Test]
    public void ParseSource_BranchWithBraceVariable_ResolvesFromVarsMap()
    {
        var vars = new Dictionary<string, string> { ["_staging_branch"] = "zfs-2.3.6-staging" };
        var result = VcsSourceParser.ParseSource(
            "zfs::git+https://github.com/openzfs/zfs.git#branch=${_staging_branch}", vars);
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Url, Is.EqualTo("https://github.com/openzfs/zfs.git"));
        Assert.That(result.Branch, Is.EqualTo("zfs-2.3.6-staging"));
    }

    [Test]
    public void ParseSource_BranchWithBareDollarVariable_ResolvesFromVarsMap()
    {
        var vars = new Dictionary<string, string> { ["_branch"] = "develop" };
        var result = VcsSourceParser.ParseSource(
            "git+https://github.com/user/repo.git#branch=$_branch", vars);
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Branch, Is.EqualTo("develop"));
    }

    [Test]
    public void ParseSource_NestedVariableExpansion_Resolves()
    {
        var vars = new Dictionary<string, string>
        {
            ["_prefix"] = "zfs-2.3.6",
            ["_branch"] = "${_prefix}-staging"
        };
        var result = VcsSourceParser.ParseSource(
            "git+https://github.com/openzfs/zfs.git#branch=${_branch}", vars);
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Branch, Is.EqualTo("zfs-2.3.6-staging"));
    }

    [Test]
    public void ParseSource_SelfReferentialVariable_DoesNotLoopAndReturnsNull()
    {
        var vars = new Dictionary<string, string> { ["_x"] = "${_x}" };
        var result = VcsSourceParser.ParseSource(
            "git+https://github.com/user/repo.git#branch=${_x}", vars);
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_BranchVariableNotInMap_ReturnsNull()
    {
        var vars = new Dictionary<string, string> { ["_other"] = "main" };
        var result = VcsSourceParser.ParseSource(
            "git+https://github.com/user/repo.git#branch=${_missing}", vars);
        Assert.That(result, Is.Null);
    }

    [Test]
    public void ParseSource_UrlWithVariable_ResolvesFromVarsMap()
    {
        var vars = new Dictionary<string, string>
        {
            ["_giturl"] = "git+https://github.com/user/repo.git",
            ["_branch"] = "main"
        };
        var result = VcsSourceParser.ParseSource("$_giturl#branch=$_branch", vars);
        Assert.That(result, Is.Not.Null);
        Assert.That(result!.Url, Is.EqualTo("https://github.com/user/repo.git"));
        Assert.That(result.Branch, Is.EqualTo("main"));
    }

    [Test]
    public void ParseSource_ZfsDkmsStagingGit_WithStagingVariable_ResolvesBranch()
    {
        var pkgbuild = "_staging_branch=zfs-2.3.6-staging\n" +
                       "source=(\"zfs::git+https://github.com/openzfs/zfs.git#branch=${_staging_branch}\")\n";
        var info = PackageManager.Utilities.PkgbuildParser.ParseContent(pkgbuild);
        var entries = VcsSourceParser.ParseSources(info.Source, info.Variables);

        Assert.That(entries, Has.Count.EqualTo(1));
        Assert.That(entries[0].Url, Is.EqualTo("https://github.com/openzfs/zfs.git"));
        Assert.That(entries[0].Branch, Is.EqualTo("zfs-2.3.6-staging"));
    }

    [Test]
    public void ParseSource_ZfsDkmsStagingGit_WithPrepareAssignment_ResolvesBranch()
    {
        var pkgbuild = "pkgname=zfs-dkms-staging-git\n" +
                       "source=(\"zfs::git+https://github.com/openzfs/zfs.git#branch=${_staging_branch}\")\n" +
                       "prepare() {\n" +
                       "  _staging_branch=zfs-2.3.6-staging\n" +
                       "  echo \"-> Staging branch set to branch=${_staging_branch}\"\n" +
                       "}\n";
        var info = PackageManager.Utilities.PkgbuildParser.ParseContent(pkgbuild);
        var entries = VcsSourceParser.ParseSources(info.Source, info.Variables);

        Assert.That(entries, Has.Count.EqualTo(1));
        Assert.That(entries[0].Url, Is.EqualTo("https://github.com/openzfs/zfs.git"));
        Assert.That(entries[0].Branch, Is.EqualTo("zfs-2.3.6-staging"));
    }
}
