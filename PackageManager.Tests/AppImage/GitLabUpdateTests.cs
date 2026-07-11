using PackageManager.AppImage.AppImageV2;

namespace PackageManager.Tests.AppImage;

public class GitLabUpdateTests
{
    [Test]
    public void NormalizeGitLabProject_Shorthand_UsesGitLabDotCom()
    {
        var project = AppImageManagerV2.NormalizeGitLabProject("gitlab-org/gitlab");

        Assert.That(project, Is.Not.Null);
        Assert.Multiple(() =>
        {
            Assert.That(project!.Value.Host, Is.EqualTo("gitlab.com"));
            Assert.That(project.Value.ProjectPath, Is.EqualTo("gitlab-org/gitlab"));
            Assert.That(project.Value.IsShorthand, Is.True);
        });
    }

    [Test]
    public void NormalizeGitLabProject_FullHttpsUrl_UsesUrlHostAndPath()
    {
        var project = AppImageManagerV2.NormalizeGitLabProject("https://gitlab.example.com/group/project");

        Assert.That(project, Is.Not.Null);
        Assert.Multiple(() =>
        {
            Assert.That(project!.Value.Host, Is.EqualTo("gitlab.example.com"));
            Assert.That(project.Value.ProjectPath, Is.EqualTo("group/project"));
            Assert.That(project.Value.IsShorthand, Is.False);
        });
    }

    [Test]
    public void NormalizeGitLabProject_NestedGroupUrl_IsAllowed()
    {
        var project = AppImageManagerV2.NormalizeGitLabProject("https://gitlab.example.com/group/subgroup/project");

        Assert.That(project, Is.Not.Null);
        Assert.That(project!.Value.ProjectPath, Is.EqualTo("group/subgroup/project"));
    }

    [Test]
    public void GitLabToReleasesApi_SelfHostedUrl_EncodesProjectPath()
    {
        var url = AppImageManagerV2.GitLabToReleasesApi("gitlab.example.com", "group/subgroup/project");

        Assert.That(url,
            Is.EqualTo("https://gitlab.example.com/api/v4/projects/group%2Fsubgroup%2Fproject/releases"));
    }

    [TestCase("http://gitlab.example.com/group/project")]
    [TestCase("https://gitlab.example.com/api/v4/projects/group%2Fproject/releases")]
    [TestCase("https://gitlab.example.com/group//project")]
    [TestCase("https://gitlab.example.com/project")]
    [TestCase("owner/repo/extra")]
    [TestCase("/owner/repo")]
    public void NormalizeGitLabProject_InvalidInputs_ReturnNull(string updateInfo)
    {
        var project = AppImageManagerV2.NormalizeGitLabProject(updateInfo);

        Assert.That(project, Is.Null);
    }
}
