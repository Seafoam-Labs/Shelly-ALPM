using PackageManager.Alpm;
using PackageManager.Alpm.Questions;
using Spectre.Console;

namespace Shelly_CLI.ConsoleLayouts;

public static class SplitOutputHelpers
{
    public static void UpdatePanel(Layout layout, string panelName, List<string> lines, int maxVisibleLines,
        object renderLock, LiveDisplayContext? ctx)
    {
        lock (renderLock)
        {
            var visible = lines.Skip(Math.Max(0, lines.Count - maxVisibleLines)).ToList();
            layout[panelName].Update(
                new Panel(new Markup(string.Join("\n", visible)))
                    .Header(panelName)
                    .Expand());
            ctx?.Refresh();
        }
    }

    public static void HandleYesNoInConsole(AlpmQuestionEventArgs e, List<string> consoleLines,
        int maxVisibleLines, Layout layout, LiveDisplayContext? ctx, object renderLock)
    {
        lock (renderLock)
        {
            consoleLines.Add($"[yellow bold]{e.QuestionText.EscapeMarkup()}[/]");
            consoleLines.Add("[green]Y[/] = Yes  |  [red]N[/] = No");
            UpdatePanelUnlocked(layout, "Console", consoleLines, maxVisibleLines, ctx);
        }

        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            if (key.Key == ConsoleKey.Y)
            {
                lock (renderLock)
                {
                    consoleLines.Add("[green]> Yes[/]");
                    UpdatePanelUnlocked(layout, "Console", consoleLines, maxVisibleLines, ctx);
                }

                e.SetResponse(new QuestionResponse(1,null));
                break;
            }

            if (key.Key == ConsoleKey.N)
            {
                lock (renderLock)
                {
                    consoleLines.Add("[red]> No[/]");
                    UpdatePanelUnlocked(layout, "Console", consoleLines, maxVisibleLines, ctx);
                }

                e.SetResponse(new QuestionResponse(0,null));
                break;
            }
        }
    }

    public static void HandleProviderInConsole(AlpmQuestionEventArgs question,
        List<string> consoleLines, int maxVisibleLines, Layout layout, LiveDisplayContext? ctx, object renderLock)
    {
        if (question.ProviderOptions is null)
        {
            return;
        }
        
        var selectedIndex = 0;
        consoleLines.Add($"[yellow bold]{question.QuestionText.EscapeMarkup()}[/]");
        var optionStartIndex = consoleLines.Count;

        RenderSelection();

        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            switch (key.Key)
            {
                case ConsoleKey.UpArrow:
                    selectedIndex = Math.Max(0, selectedIndex - 1);
                    RenderSelection();
                    break;
                case ConsoleKey.DownArrow:
                    selectedIndex = Math.Min(question.ProviderOptions.Count - 1, selectedIndex + 1);
                    RenderSelection();
                    break;
                case ConsoleKey.Enter:
                    consoleLines.RemoveRange(optionStartIndex, consoleLines.Count - optionStartIndex);
                    consoleLines.Add(
                        $"[green]Selected: {question.ProviderOptions[selectedIndex].Name.EscapeMarkup()}[/]");
                    question.SetResponse(new QuestionResponse(selectedIndex, question.ProviderOptions));

                    lock (renderLock)
                    {
                        UpdatePanelUnlocked(layout, "Console", consoleLines, maxVisibleLines, ctx);
                    }

                    return;
            }
        }

        void RenderSelection()
        {
            if (consoleLines.Count > optionStartIndex)
            {
                consoleLines.RemoveRange(optionStartIndex, consoleLines.Count - optionStartIndex);
            }

            for (var i = 0; i < question.ProviderOptions.Count; i++)
            {
                var prefix = i == selectedIndex ? "[green]> [/]" : "  ";
                var style = i == selectedIndex ? "[bold green]" : "[dim]";
                consoleLines.Add($"{prefix}{style}{question.ProviderOptions[i].Name.EscapeMarkup()}[/]");
            }

            lock (renderLock)
            {
                UpdatePanelUnlocked(layout, "Console", consoleLines, maxVisibleLines, ctx);
            }
        }
    }

    public static void HandleOptionalDepsInConsole(AlpmQuestionEventArgs question,
        List<string> consoleLines, int maxVisibleLines, Layout layout, LiveDisplayContext? ctx, object renderLock)
    {
        if (question.ProviderOptions is null || question.ProviderOptions.Count == 0)
        {
            question.SetResponse(new QuestionResponse(0, null));
            return;
        }

        var visible = question.ProviderOptions
            .Select((o, i) => (Option: o, OriginalIndex: i))
            .Where(t => !t.Option.IsInstalled)
            .ToList();

        if (visible.Count == 0)
        {
            var none = question.ProviderOptions
                .Select(o => o with { IsSelected = false })
                .ToList();
            question.SetResponse(new QuestionResponse(0, none));
            return;
        }

        var selectedIndex = 0;
        var selected = new HashSet<int>();
        consoleLines.Add($"[yellow bold]{question.QuestionText.EscapeMarkup()}[/]");
        consoleLines.Add("[dim]Space = toggle, A = all, N = none, Enter = confirm[/]");
        var optionStartIndex = consoleLines.Count;

        RenderSelection();

        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            switch (key.Key)
            {
                case ConsoleKey.UpArrow:
                    selectedIndex = Math.Max(0, selectedIndex - 1);
                    RenderSelection();
                    break;

                case ConsoleKey.DownArrow:
                    selectedIndex = Math.Min(visible.Count - 1, selectedIndex + 1);
                    RenderSelection();
                    break;

                case ConsoleKey.Spacebar:
                    if (!selected.Remove(selectedIndex))
                    {
                        selected.Add(selectedIndex);
                    }

                    RenderSelection();
                    break;
                case ConsoleKey.A:
                    for (var i = 0; i < visible.Count; i++)
                    {
                        selected.Add(i);
                    }

                    RenderSelection();
                    break;

                case ConsoleKey.N:
                    selected.Clear();
                    RenderSelection();
                    break;

                case ConsoleKey.Enter:
                    consoleLines.RemoveRange(optionStartIndex, consoleLines.Count - optionStartIndex);
                    if (selected.Count == 0)
                    {
                        consoleLines.Add("[dim]No optional dependencies selected.[/]");
                    }
                    else
                    {
                        var names = selected
                            .OrderBy(i => i)
                            .Select(i => visible[i].Option)
                            .ToList();
                        consoleLines.Add(
                            $"[green]Selected: {string.Join(", ", names.Select(n => n.Name.EscapeMarkup()))}[/]");
                    }

                    var selectedOriginal = selected.Select(v => visible[v].OriginalIndex).ToHashSet();
                    var selectedOptions = question.ProviderOptions
                        .Select((o, i) => o with { IsSelected = selectedOriginal.Contains(i) })
                        .ToList();
                    question.SetResponse(new QuestionResponse(0, selectedOptions));

                    lock (renderLock)
                    {
                        UpdatePanelUnlocked(layout, "Console", consoleLines, maxVisibleLines, ctx);
                    }

                    return;
            }
        }

        void RenderSelection()
        {
            if (consoleLines.Count > optionStartIndex)
                consoleLines.RemoveRange(optionStartIndex, consoleLines.Count - optionStartIndex);

            for (int i = 0; i < visible.Count; i++)
            {
                var cursor = i == selectedIndex ? ">" : " ";
                var check = selected.Contains(i) ? "[green]✓[/]" : "[dim]○[/]";
                var style = i == selectedIndex ? "[bold green]" : "[white]";
                consoleLines.Add(
                    $" {cursor} {check} {style}{visible[i].Option.Name.EscapeMarkup()}[/]");
            }

            lock (renderLock)
            {
                UpdatePanelUnlocked(layout, "Console", consoleLines, maxVisibleLines, ctx);
            }
        }
    }

    /// <summary>
    /// Updates a panel without acquiring the render lock. Caller must already hold the lock.
    /// </summary>
    private static void UpdatePanelUnlocked(Layout layout, string panelName, List<string> lines,
        int maxVisibleLines, LiveDisplayContext? ctx)
    {
        var visible = lines.Skip(Math.Max(0, lines.Count - maxVisibleLines)).ToList();
        layout[panelName].Update(
            new Panel(new Markup(string.Join("\n", visible)))
                .Header(panelName)
                .Expand());
        ctx?.Refresh();
    }
}