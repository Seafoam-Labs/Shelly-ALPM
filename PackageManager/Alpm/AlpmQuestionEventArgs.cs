using System;
using System.Collections.Generic;
using System.Threading;
using PackageManager.Alpm.Questions;

namespace PackageManager.Alpm;

public class AlpmQuestionEventArgs : EventArgs
{
    public AlpmQuestionEventArgs(
        AlpmQuestionType questionType,
        string questionText,
        List<ProviderOption>? providerOptions = null,
        string? dependencyName = null)
    {
        QuestionType = questionType;
        QuestionText = questionText;
        ProviderOptions = providerOptions;
        DependencyName = dependencyName;
    }

    /// <summary>
    /// The type of question being asked by libalpm
    /// </summary>
    public AlpmQuestionType QuestionType { get; }
    
    /// <summary>
    /// The question text to display to the user
    /// </summary>
    public string QuestionText { get; }
    
    /// <summary>
    /// For SelectProvider questions: the list of package names that can provide the dependency
    /// </summary>
    public List<ProviderOption>? ProviderOptions { get; }
    
    /// <summary>
    /// For SelectProvider questions: the name of the dependency being resolved
    /// </summary>
    public string? DependencyName { get; }
    
    /// <summary>
    /// The response to send back to libalpm.
    /// For yes/no questions: 1 = Yes, 0 = No
    /// For SelectProvider: the index of the selected provider (0-based)
    /// </summary>
    public QuestionResponse Response { get; set; } = new QuestionResponse(-1,null); // Default to No (-1)

    private volatile bool _responded;

    /// <summary>
    /// Sets the response value and signals the waiting callback thread.
    /// Call this from the GUI after the user has answered.
    /// </summary>
    public void SetResponse(QuestionResponse response)
    {
        Response = response;
        _responded = true;
    }

    /// <summary>
    /// Blocks the calling thread until <see cref="SetResponse"/> is called.
    /// Safe to call from the libalpm callback thread.
    /// </summary>
    public void WaitForResponse()
    {
        while (!_responded)
        {
            Thread.Sleep(50);
        }
    }
}
