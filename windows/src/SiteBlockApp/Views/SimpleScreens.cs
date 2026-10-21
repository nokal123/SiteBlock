using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>The screen shown until the first answer from the service arrives: the header and "Connecting to SiteBlock…" with a spinner.</summary>
internal sealed class ConnectingScreen : IScreenView
{
    /// <summary>Builds the screen.</summary>
    public ConnectingScreen()
    {
        var header = new PanelHeader();
        header.Update(null, null);
        StackPanel row = Ui.Row(8, new Spinner(), Ui.Text(PanelModel.ConnectingText, ThemeKeys.TextSecondary));
        row.HorizontalAlignment = HorizontalAlignment.Center;
        row.Margin = new Thickness(0, 28, 0, 28);
        Root = Ui.Stack(0).With(header, Ui.Divider(), row);
    }

    /// <summary>The screen's root element.</summary>
    public FrameworkElement Root { get; }

    /// <summary>Nothing on this screen changes.</summary>
    public void Update() { }
}

/// <summary>
/// The screen shown when the service cannot be reached: a slashed shield, the reason, what stopping means, and the Windows repair step (run Install SiteBlock.cmd again), with a "Try again" button.
/// </summary>
internal sealed class NotRunningScreen : IScreenView
{
    private readonly ViewContext _context;
    private readonly TextBlock _message = Ui.Text("", ThemeKeys.Text, Ui.HeadlineSize, FontWeights.SemiBold);

    /// <summary>Builds the screen.</summary>
    public NotRunningScreen(ViewContext context)
    {
        _context = context;
        var header = new PanelHeader();
        header.Update(null, null);
        _message.TextAlignment = TextAlignment.Center;
        TextBlock explanation = Ui.Text(PanelModel.NotRunningExplanation, ThemeKeys.TextSecondary);
        explanation.TextAlignment = TextAlignment.Center;
        TextBlock repair = Ui.Text(PanelModel.NotRunningRepair);
        repair.TextAlignment = TextAlignment.Center;
        SpacedStack body = Ui.Stack(12).With(SlashedShield(), _message, explanation, repair);
        body.Margin = new Thickness(16);

        var footer = new DockPanel { Margin = new Thickness(12, 6, 12, 6), LastChildFill = false };
        Button tryAgain = Ui.Button(PanelModel.TryAgainTitle, ButtonKind.Borderless, small: true, () => _ = TryAgainAsync());
        DockPanel.SetDock(tryAgain, Dock.Left);
        footer.Children.Add(tryAgain);
        Root = Ui.Stack(0).With(header, Ui.Divider(), body, Ui.Divider(), footer);
    }

    /// <summary>The screen's root element.</summary>
    public FrameworkElement Root { get; }

    /// <summary>Shows the current reason.</summary>
    public void Update()
    {
        string message = _context.Panel.NotRunningMessage;
        if (_message.Text != message) _message.Text = message;
    }

    /// <summary>A large gray shield with a slash across it, like the tray icon when the service is down.</summary>
    private static Grid SlashedShield()
    {
        var grid = new Grid { Width = 40, Height = 40, HorizontalAlignment = HorizontalAlignment.Center };
        grid.Children.Add(Ui.Glyph(Glyphs.Shield, ThemeKeys.TextSecondary, 32));
        var slash = new Line { X1 = 6, Y1 = 6, X2 = 34, Y2 = 34, StrokeThickness = 2.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
        slash.SetResourceReference(Shape.StrokeProperty, ThemeKeys.TextSecondary);
        grid.Children.Add(slash);
        return grid;
    }

    /// <summary>"Try again": asks the service for its status at once and redraws.</summary>
    private async Task TryAgainAsync()
    {
        await _context.Status.RefreshAsync();
        _context.RequestUpdate();
    }
}
