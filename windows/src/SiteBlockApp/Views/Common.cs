using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>What every view needs: the panel model, and a way to ask for one redraw of the whole panel soon (many changes in a row cause only one redraw).</summary>
/// <param name="Panel">The panel's root model.</param>
/// <param name="RequestUpdate">Asks for a redraw.</param>
internal sealed record ViewContext(PanelModel Panel, Action RequestUpdate)
{
    /// <summary>The status model.</summary>
    public StatusModel Status => Panel.Status;
}

/// <summary>One of the panel's screens. <see cref="Update"/> brings every text, button and field on it up to date with the models; it is cheap when nothing changed.</summary>
internal interface IScreenView
{
    /// <summary>The screen's root element.</summary>
    FrameworkElement Root { get; }

    /// <summary>Brings the screen up to date.</summary>
    void Update();
}

/// <summary>A small spinning arrow, shown while something runs (connecting, checking for updates, an install step).</summary>
internal sealed class Spinner : TextBlock
{
    /// <summary>Creates the spinner; it turns once a second for as long as it is on screen.</summary>
    public Spinner(double size = 12)
    {
        Text = "";
        FontFamily = Theme.IconFont;
        FontSize = size;
        VerticalAlignment = VerticalAlignment.Center;
        SetResourceReference(ForegroundProperty, ThemeKeys.TextSecondary);
        RenderTransformOrigin = new Point(0.5, 0.5);
        var rotate = new RotateTransform();
        RenderTransform = rotate;
        rotate.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever });
    }
}

/// <summary>The title row at the top of the home, connecting and not-running screens: the shield, the app name, and the current unblock delay when it is known.</summary>
internal sealed class PanelHeader : DockPanel
{
    private readonly TextBlock _delay = Ui.Text("", ThemeKeys.TextSecondary, Ui.CaptionSize);
    private readonly StackPanel _delayRow;

    /// <summary>Creates the header.</summary>
    public PanelHeader()
    {
        Margin = new Thickness(16, 12, 16, 12);
        LastChildFill = false;
        _delay.TextWrapping = TextWrapping.NoWrap;
        _delay.VerticalAlignment = VerticalAlignment.Center;
        TextBlock name = Ui.Headline(PanelModel.AppName);
        name.VerticalAlignment = VerticalAlignment.Center;
        StackPanel left = Ui.Row(8, Ui.Glyph(Glyphs.Shield, ThemeKeys.Accent, 18), name);
        _delayRow = Ui.Row(5, Ui.Glyph(Glyphs.Timer, ThemeKeys.TextSecondary, 11), _delay);
        _delayRow.VerticalAlignment = VerticalAlignment.Center;
        SetDock(left, Dock.Left);
        SetDock(_delayRow, Dock.Right);
        Children.Add(left);
        Children.Add(_delayRow);
    }

    /// <summary>Shows the delay line and its tooltip, or hides it while the delay is unknown.</summary>
    public void Update(string? delayText, string? delayHelp)
    {
        _delayRow.Show(delayText is not null);
        if (delayText is null) return;
        if (_delay.Text != delayText) _delay.Text = delayText;
        _delayRow.ToolTip = delayHelp;
    }
}

/// <summary>A titled box that groups related controls in Settings.</summary>
internal static class SectionCard
{
    /// <summary>Builds the box with its title and the given content, one below the other.</summary>
    public static Border Create(string title, params UIElement[] content)
    {
        SpacedStack stack = Ui.Stack(8).With(Ui.Text(title, ThemeKeys.Text, 12.5, FontWeights.SemiBold));
        foreach (UIElement element in content) stack.Children.Add(element);
        return Ui.Card(stack);
    }
}

/// <summary>The lock in front of a row's name: a closed lock, a lock with a small clock while an unblock waits, or an open lock while a temporary unblock is open.</summary>
internal sealed class LockIconView : Grid
{
    private readonly TextBlock _lock = Ui.Glyph(Glyphs.Lock, ThemeKeys.TextSecondary, 14);
    private readonly TextBlock _clock = Ui.Glyph(Glyphs.Clock, ThemeKeys.TextSecondary, 8);
    private LockIcon? _shown;

    /// <summary>Creates the icon, 18 pixels wide.</summary>
    public LockIconView()
    {
        Width = 18;
        _clock.HorizontalAlignment = HorizontalAlignment.Right;
        _clock.VerticalAlignment = VerticalAlignment.Bottom;
        _clock.FontWeight = FontWeights.Bold;
        Children.Add(_lock);
        Children.Add(_clock);
    }

    /// <summary>Shows the lock for the row's state in the row tone's full-strength color.</summary>
    public void Set(LockIcon icon, SiteTone tone)
    {
        string colorKey = ThemeKeys.ToneAccent(tone);
        _lock.SetResourceReference(TextBlock.ForegroundProperty, colorKey);
        _clock.SetResourceReference(TextBlock.ForegroundProperty, colorKey);
        if (_shown == icon) return;
        _shown = icon;
        _lock.Text = icon == LockIcon.Open ? Glyphs.Unlock : Glyphs.Lock;
        _clock.Show(icon == LockIcon.Clock);
    }
}

/// <summary>Shows the model's current message, but only when it belongs to this part of the panel.</summary>
internal sealed class FeedbackLine
{
    private readonly Func<FeedbackScope> _scope;

    /// <summary>Creates the line for the place <paramref name="scope"/> names (asked again on every update, because a row's name can be read late).</summary>
    public FeedbackLine(Func<FeedbackScope> scope) => _scope = scope;

    /// <summary>The element to place.</summary>
    public MessageLine Element { get; } = new();

    /// <summary>Shows the message when its place matches, otherwise hides the line.</summary>
    public void Update(Feedback? feedback)
    {
        if (feedback is not null && feedback.Scope == _scope()) Element.Set(feedback.Text, feedback.IsError);
        else Element.Set(null, false);
    }
}
