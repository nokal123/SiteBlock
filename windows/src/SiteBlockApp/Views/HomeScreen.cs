using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>
/// The home screen: the header, the banners, the "Choose a new password" banner after a reset, the add field (with its caption, the part-or-whole choice and the first-block password form), the blocked list,
/// and, once a password exists, the footer with the Settings button. There is no Exit button: the app always stays in the tray.
/// </summary>
internal sealed class HomeScreen : IScreenView
{
    private readonly ViewContext _context;
    private readonly PanelHeader _header = new();
    private readonly BannersView _banners;
    private readonly Border _noPasswordBanner;
    private readonly Button _chooseNewPassword;
    private readonly SetupFormView _newPasswordForm;
    private readonly TextBox _addBox;
    private readonly Grid _addHost;
    private readonly Button _block;
    private readonly SpacedStack _choice;
    private readonly Button _onlyThisPart;
    private readonly Button _wholeSite;
    private readonly TextBlock _choiceCaption = Ui.Caption();
    private readonly FeedbackLine _addFeedback = new(() => FeedbackScope.Add);
    private readonly Border _firstBlockCard;
    private readonly SetupFormView _firstBlockForm;
    private readonly BlockedListView _list;
    private readonly Border _footerDivider = Ui.Divider();
    private readonly DockPanel _footer;
    private bool? _shownOnlyThisPart;

    /// <summary>Builds the home screen.</summary>
    public HomeScreen(ViewContext context)
    {
        _context = context;
        HomeModel home = context.Panel.Home;
        _banners = new BannersView(context);

        // The banner shown when a reset cleared the password while sites stay blocked.
        _chooseNewPassword = Ui.Button(HomeModel.ChooseNewPasswordTitle, small: true, onClick: () =>
        {
            home.OpenNewPasswordForm();
            context.RequestUpdate();
        });
        _chooseNewPassword.HorizontalAlignment = HorizontalAlignment.Left;
        _newPasswordForm = new SetupFormView(context, home.NewPasswordForm, () => null, () =>
        {
            home.CancelPasswordForm();
            context.RequestUpdate();
        });
        TextBlock keyIcon = Ui.Glyph(Glyphs.Key, ThemeKeys.BannerAccent(BannerTint.Orange), 14);
        keyIcon.VerticalAlignment = VerticalAlignment.Top;
        keyIcon.Width = 18;
        keyIcon.Margin = new Thickness(0, 1, 8, 0);
        var noPasswordGrid = new DockPanel();
        DockPanel.SetDock(keyIcon, Dock.Left);
        noPasswordGrid.Children.Add(keyIcon);
        noPasswordGrid.Children.Add(Ui.Stack(6).With(Ui.Text(HomeModel.NoPasswordText), _chooseNewPassword, _newPasswordForm.Element));
        _noPasswordBanner = Ui.Card(noPasswordGrid, ThemeKeys.BannerFill(BannerTint.Orange), ThemeKeys.BannerEdge(BannerTint.Orange), new Thickness(10));

        // The add field and the Block button. Enter in the field also blocks.
        (_addHost, _addBox) = Ui.PromptTextBox(HomeModel.AddPrompt);
        _addBox.TextChanged += (_, _) =>
        {
            home.AddText = _addBox.Text;
            context.RequestUpdate();
        };
        _addBox.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            _ = PressBlockAsync();
        };
        _block = Ui.Button(HomeModel.BlockTitle, ButtonKind.Accent, onClick: () => _ = PressBlockAsync());
        _block.Margin = new Thickness(8, 0, 0, 0);
        var addRow = new DockPanel();
        DockPanel.SetDock(_block, Dock.Right);
        addRow.Children.Add(_block);
        addRow.Children.Add(_addHost);

        // The two-choice control that appears when the text has a path; "Only this part" is selected first.
        _onlyThisPart = Ui.Button(HomeModel.OnlyThisPartTitle, small: true, onClick: () =>
        {
            home.OnlyThisPart = true;
            context.RequestUpdate();
        });
        _wholeSite = Ui.Button(HomeModel.WholeSiteTitle, small: true, onClick: () =>
        {
            home.OnlyThisPart = false;
            context.RequestUpdate();
        });
        _choice = Ui.Stack(4).With(Ui.Row(4, _onlyThisPart, _wholeSite), _choiceCaption);

        _firstBlockForm = new SetupFormView(context, home.FirstBlockForm, () => home.FirstBlockDetail, () =>
        {
            home.CancelPasswordForm();
            context.RequestUpdate();
        });
        _firstBlockCard = Ui.Card(_firstBlockForm.Element);

        SpacedStack addSection = Ui.Stack(6).With(Ui.Caption(HomeModel.AddCaption), addRow, _choice, _addFeedback.Element, _firstBlockCard);
        _list = new BlockedListView(context);

        _footer = new DockPanel { Margin = new Thickness(12, 6, 12, 6), LastChildFill = false };
        Button settings = Ui.GlyphButton(Glyphs.Settings, PanelModel.SettingsTitle, () =>
        {
            context.Panel.OpenSettings();
            context.RequestUpdate();
        });
        DockPanel.SetDock(settings, Dock.Left);
        _footer.Children.Add(settings);

        SpacedStack body = Ui.Stack(12).With(_banners.Element, _noPasswordBanner, addSection, _list.Element);
        body.Margin = new Thickness(16);
        Root = Ui.Stack(0).With(_header, Ui.Divider(), body, _footerDivider, _footer);
    }

    /// <summary>The screen's root element.</summary>
    public FrameworkElement Root { get; }

    /// <summary>Brings every part of the home screen up to date.</summary>
    public void Update()
    {
        PanelModel panel = _context.Panel;
        HomeModel home = panel.Home;
        StatusModel status = _context.Status;
        _header.Update(panel.HeaderDelayText, panel.HeaderDelayHelp);
        _banners.Update();

        _noPasswordBanner.Show(home.NeedsNewPassword);
        _chooseNewPassword.Show(!home.IsChoosingNewPassword);
        _chooseNewPassword.IsEnabled = !status.IsBusy;
        _newPasswordForm.Element.Show(home.IsChoosingNewPassword);
        if (home.IsChoosingNewPassword) _newPasswordForm.Update();

        Ui.Sync(_addBox, home.AddText);
        _addBox.IsEnabled = !home.AddFieldDisabled;
        _block.IsEnabled = home.CanPressBlock;
        _choice.Show(home.HasPath);
        _choice.IsEnabled = !home.AddFieldDisabled;
        if (_shownOnlyThisPart != home.OnlyThisPart)
        {
            _shownOnlyThisPart = home.OnlyThisPart;
            _onlyThisPart.Style = Ui.ButtonStyle(home.OnlyThisPart ? ButtonKind.Accent : ButtonKind.Standard, small: true);
            _wholeSite.Style = Ui.ButtonStyle(home.OnlyThisPart ? ButtonKind.Standard : ButtonKind.Accent, small: true);
        }
        _choiceCaption.Show(home.ChoiceCaption is not null);
        _choiceCaption.Text = home.ChoiceCaption ?? "";
        _addFeedback.Update(status.Feedback);
        _firstBlockCard.Show(home.IsChoosingFirstPassword);
        if (home.IsChoosingFirstPassword) _firstBlockForm.Update();

        _list.Update();

        _footerDivider.Show(panel.ShowsFooter);
        _footer.Show(panel.ShowsFooter);

        if (home.FocusAddFieldRequested && !home.AddFieldDisabled)
        {
            home.FocusAddFieldRequested = false;
            Ui.FocusSoon(_addBox);
        }
    }

    /// <summary>Block (or Enter): blocks the typed site or part, or opens the first-block password form, then redraws.</summary>
    private async Task PressBlockAsync()
    {
        await _context.Panel.Home.PressBlockAsync();
        _context.RequestUpdate();
    }
}
