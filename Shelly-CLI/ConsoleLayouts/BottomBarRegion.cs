using Shelly_CLI.Configuration;
using Spectre.Console;

namespace Shelly_CLI.ConsoleLayouts;

public sealed class BottomBarRegion : IDisposable
{
    public readonly record struct LineKey(string Source, string Package, string Action);

    public sealed class BarState
    {
        public string Name = "";
        public ulong Current;
        public ulong HowMany;
        public int Pct;
        public string ActionType = "";
    }

    private sealed class StickySlot
    {
        public LineKey Key;
        public string Text = "";
        public DateTime LastUpdate;
    }

    private readonly object _ioLock = new();
    private readonly Dictionary<string, BarState> _bars = new(StringComparer.Ordinal);
    private readonly List<string> _order = new();
    private readonly List<StickySlot> _stickies = new();
    private int _barRowsDrawn;
    private int _stickyDrawnCount;
    private int _frame;

    private readonly ProgressBarStyleKind _style;
    private readonly int _barWidth;
    private readonly int _maxStickies;
    private readonly bool _animate;
    private readonly bool _asciiOnly;

    private readonly CancellationTokenSource _frameCts = new();
    private readonly Task? _ticker;

    public BottomBarRegion(ProgressBarStyleKind style, int barWidth, int maxStickies)
    {
        _style = style;
        _barWidth = barWidth;
        _maxStickies = Math.Max(1, maxStickies);
        _animate = !Console.IsOutputRedirected
                   && AnsiConsole.Profile.Capabilities.Ansi;

        var noColor = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NO_COLOR"));
        var caps = AnsiConsole.Profile.Capabilities;
        Console.WriteLine(!Equals(Console.OutputEncoding, System.Text.Encoding.UTF8));
        var supportsColor = caps.Ansi && caps.ColorSystem != ColorSystem.NoColors;
        _asciiOnly = !supportsColor || noColor || Console.IsOutputRedirected;
                     //|| !Equals(Console.OutputEncoding, System.Text.Encoding.UTF8);

        if (_animate && ProgressBarRenderer.NeedsFrameTicker(_style))
        {
            _ticker = Task.Run(async () =>
            {
                try
                {
                    while (!_frameCts.IsCancellationRequested)
                    {
                        await Task.Delay(120, _frameCts.Token);
                        lock (_ioLock)
                        {
                            _frame++;
                            if (_bars.Count > 0)
                            {
                                ClearBars();
                                DrawBars();
                            }
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                }
            }, _frameCts.Token);
        }
    }

    public static BottomBarRegion CreateFromConfig(ShellyConfig cfg)
    {
        var style = ProgressBarRenderer.ParseStyle(cfg.ProgressBarStyle);
        return new BottomBarRegion(style, cfg.ProgressBarWidth, cfg.SinglePaneMaxStickies);
    }

    public void WriteLine(string markup)
    {
        lock (_ioLock)
        {
            ClearBars();
            EmitLine(markup);
            DrawBars();
        }
    }

    private void EmitLine(string markup)
    {
        if (_asciiOnly)
            Console.Out.WriteLine(Markup.Remove(markup));
        else
            AnsiConsole.MarkupLine(markup);
    }


    public void WritePlain(string text)
    {
        lock (_ioLock)
        {
            ClearBars();
            Console.Out.WriteLine(_asciiOnly ? Markup.Remove(text) : text);
            DrawBars();
        }
    }

    public void WriteEvent(LineKey key, string markup)
    {
        lock (_ioLock)
        {
            var slot = _stickies.FirstOrDefault(s => s.Key.Equals(key));
            if (slot is null)
            {
                if (_animate) ClearBars();
                EnsureCapacityForNewSticky();
                slot = new StickySlot { Key = key, Text = markup, LastUpdate = DateTime.UtcNow };
                _stickies.Add(slot);
                if (_animate) DrawBars();
                return;
            }

            slot.Text = markup;
            slot.LastUpdate = DateTime.UtcNow;
            if (_animate)
            {
                ClearBars();
                DrawBars();
            }
        }
    }


    private readonly HashSet<(string Name, string Action)> _finalizedBars = new();

    public void UpdateBar(string name, ulong current, ulong howMany, int pct, string actionType)
    {
        lock (_ioLock)
        {
            if (!_animate)
            {
                // Plain / redirected mode: suppress intermediates and emit at most
                // one finalized line per (name, action).
                if (pct < 100) return;
                var finKey = (name, actionType);
                if (!_finalizedBars.Add(finKey)) return;

                var rPlain = new BarState
                {
                    Name = name,
                    Current = current,
                    HowMany = howMany,
                    Pct = pct,
                    ActionType = actionType
                };
                Console.Out.WriteLine(Markup.Remove(RenderBarLine(rPlain)));
                return;
            }

            // Animated: dedupe unchanged events for the same key.
            if (_bars.TryGetValue(name, out var existing)
                && existing.Pct == pct
                && existing.Current == current
                && existing.ActionType == actionType)
                return;

            // If we've already finalized this (name, action) at 100%, drop it.
            var finKeyAnim = (name, actionType);
            if (pct >= 100 && _finalizedBars.Contains(finKeyAnim))
                return;

            if (!_bars.TryGetValue(name, out var r))
            {
                r = new BarState { Name = name };
                _bars[name] = r;
                _order.Add(name);
            }

            r.Current = current;
            r.HowMany = howMany;
            r.Pct = pct;
            r.ActionType = actionType;

            ClearBars();
            if (pct >= 100)
            {
                EmitLine(RenderBarLine(r));
                _bars.Remove(name);
                _order.Remove(name);
                _finalizedBars.Add(finKeyAnim);
            }

            DrawBars();
        }
    }


    public void PromoteBar(string name)
    {
        lock (_ioLock)
        {
            if (!_bars.TryGetValue(name, out var r)) return;
            if (_animate) ClearBars();
            EmitLine(RenderBarLine(r));
            _finalizedBars.Add((name, r.ActionType ?? ""));
            _bars.Remove(name);
            _order.Remove(name);
            if (_animate) DrawBars();
        }
    }

    public void FinalizeSticky(LineKey key)
    {
        lock (_ioLock)
        {
            var idx = _stickies.FindIndex(s => s.Key.Equals(key));
            if (idx < 0) return;
            var slot = _stickies[idx];
            _stickies.RemoveAt(idx);
            if (_animate)
            {
                ClearBars();
                EmitLine(slot.Text);
                DrawBars();
            }
            else
            {
                EmitLine(slot.Text);
            }
        }
    }

    public void FinalizeStickiesWhere(Func<LineKey, bool> predicate)
    {
        lock (_ioLock)
        {
            var matched = _stickies.Where(s => predicate(s.Key)).ToList();
            if (matched.Count == 0) return;
            if (_animate) ClearBars();
            foreach (var s in matched)
            {
                _stickies.Remove(s);
                EmitLine(s.Text);
            }

            if (_animate) DrawBars();
        }
    }

    public void FinalizeAllStickies()
    {
        lock (_ioLock)
        {
            if (_stickies.Count == 0) return;
            if (_animate) ClearBars();
            foreach (var s in _stickies)
            {
                EmitLine(s.Text);
            }

            _stickies.Clear();
            if (_animate) DrawBars();
        }
    }


    public void SuspendForPrompt()
    {
        lock (_ioLock)
        {
            FinalizeAllStickies();
            ClearBars();
        }
    }

    public void Resume()
    {
        lock (_ioLock)
        {
            DrawBars();
        }
    }

    public void Dispose()
    {
        try
        {
            _frameCts.Cancel();
        }
        catch
        {
        }

        if (_ticker != null)
        {
            try
            {
                _ticker.GetAwaiter().GetResult();
            }
            catch
            {
            }
        }

        lock (_ioLock)
        {
            FinalizeAllStickies();
            ClearBars();
            _bars.Clear();
            _order.Clear();
        }

        _frameCts.Dispose();
    }


    private void DrawBars()
    {
        if (!_animate) return;
        DrawStickies();
        foreach (var key in _order)
        {
            Console.Out.Write(RenderBarLine(_bars[key]));
            Console.Out.Write("\n");
            _barRowsDrawn++;
        }

        Console.Out.Flush();
    }

    private void ClearBars()
    {
        if (!_animate) return;
        if (_barRowsDrawn > 0)
        {
            for (var i = 0; i < _barRowsDrawn; i++)
            {
                Console.Out.Write("\x1b[1A\x1b[2K");
            }

            Console.Out.Write("\r");
            _barRowsDrawn = 0;
        }

        ClearStickies();
    }

    private void DrawStickies()
    {
        if (!_animate || _stickies.Count == 0 || _stickyDrawnCount > 0) return;
        foreach (var s in _stickies)
        {
            var t = TruncateStickyText(s.Text);
            if (_asciiOnly) Console.Out.WriteLine(Markup.Remove(t));
            else AnsiConsole.MarkupLine(t);
        }

        _stickyDrawnCount = _stickies.Count;
    }

    private void ClearStickies()
    {
        if (!_animate || _stickyDrawnCount == 0) return;
        for (var i = 0; i < _stickyDrawnCount; i++)
        {
            Console.Out.Write("\x1b[1A\x1b[2K");
        }

        Console.Out.Write("\r");
        _stickyDrawnCount = 0;
    }

    private void EnsureCapacityForNewSticky()
    {
        while (_stickies.Count >= _maxStickies)
        {
            var victimIdx = 0;
            var victimTime = _stickies[0].LastUpdate;
            for (var i = 1; i < _stickies.Count; i++)
            {
                if (_stickies[i].LastUpdate < victimTime)
                {
                    victimTime = _stickies[i].LastUpdate;
                    victimIdx = i;
                }
            }

            var victim = _stickies[victimIdx];
            _stickies.RemoveAt(victimIdx);
            EmitLine(victim.Text);
        }
    }

    private string RenderBarLine(BarState r)
    {
        var bar = _asciiOnly
            ? ProgressBarRenderer.RenderAscii(r.Pct, _frame, _style, _barWidth)
            : ProgressBarRenderer.Render(r.Pct, _frame, _style, _barWidth);
        var line = $"({r.Current}/{r.HowMany}) {r.ActionType} {r.Name} {bar} {r.Pct,3}%";
        var max = Math.Max(20, Console.WindowWidth - 1);
        if (Markup.Remove(line).Length > max)
        {
            line = Markup.Remove(line);
            if (line.Length > max) line = line[..max];
        }

        return line;
    }

    private static string TruncateStickyText(string text)
    {
        var max = Math.Max(20, Console.WindowWidth - 1);
        if (Markup.Remove(text).Length <= max) return text;
        var plain = Markup.Remove(text);
        if (plain.Length > max) plain = plain[..max];
        return plain.EscapeMarkup();
    }
}