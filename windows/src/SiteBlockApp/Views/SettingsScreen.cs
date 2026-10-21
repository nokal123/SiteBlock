using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>
/// The Settings screen inside the panel: a back button and title, the banners, the unblock delay form, the change-password form, the adult filter note, the version with "Check for updates", the uninstall form, and the contact note,
/// in a scroll area, with the service's version at the bottom.
/// </summary>
internal sealed class SettingsScreen : IScreenView
{
    /// <summary>The tallest the scrolling form area may grow.</summary>
    private const double MaxFormHeight = 440;

    private readonly ViewContext _context;
    private readonly BannersView _banners;
    private readonly MenuPicker<long> _delayPicker = new();
    private readonly TextBlock _delayHint = Ui.Caption();
    private readonly PasswordBox _delayPassword;
    private readonly FeedbackLine _delayFeedback = new(() => FeedbackScope.Delay);
    private readonly Button _changeDelay;
    private readonly PasswordBox _oldPassword;
    private readonly PasswordBox _newPassword;
    private readonly PasswordBox _confirmPassword;
    private readonly MessageLine _passwordProblem = new();
    private readonly FeedbackLine _passwordFeedback = new(() => FeedbackScope.Password);
    private readonly Button _changePassword;
    private readonly Border _adultFilter;
    private readonly Spinner _checking = new();
    private readonly Button _checkForUpdates;
    private readonly MessageLine _checkResult = new();
    private readonly TextBlock _uninstallText = Ui.Text("", ThemeKeys.TextSecondary);
    private readonly TextBlock _uninstallScheduled = Ui.Text(SettingsModel.UninstallScheduledText);
    private readonly Button _openUninstall;
    private readonly DockPanel _uninstallForm;
    private readonly PasswordBox _uninstallPassword;
    private readonly Button _startUninstall;
    private readonly FeedbackLine _uninstallFeedback = new(() => FeedbackScope.Uninstall);
    private readonly TextBlock _serviceVersion = Ui.Text("", ThemeKeys.TextTertiary, Ui.CaptionSize);

    /// <summary>Builds the Settings screen.</summary>
    public SettingsScreen(ViewContext context)
    {
        _context = context;
        SettingsModel settings = context.Panel.Settings;
        _banners = new BannersView(context);

        // Navigation: a back button on the left and the title in the middle.
        var navigation = new Grid { Margin = new Thickness(12, 10, 12, 10) };
        TextBlock title = Ui.Headline(SettingsModel.Title);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.VerticalAlignment = VerticalAlignment.Center;
        Button back = Ui.GlyphButton(Glyphs.Back, PanelModel.BackTitle, () =>
        {
            context.Panel.CloseSettings();
            context.RequestUpdate();
        });
        back.HorizontalAlignment = HorizontalAlignment.Left;
        navigation.Children.Add(title);
        navigation.Children.Add(back);

        // The delay form.
        _delayPicker.Picked += value =>
        {
            settings.PickedDelay = value;
            context.RequestUpdate();
        };
        var delayRow = new DockPanel { LastChildFill = false };
        TextBlock delayLabel = Ui.Text(SettingsModel.DelayLabel);
        delayLabel.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(delayLabel, Dock.Left);
        DockPanel.SetDock(_delayPicker, Dock.Right);
        delayRow.Children.Add(delayLabel);
        delayRow.Children.Add(_delayPicker);
        (Grid delayPasswordHost, _delayPassword) = Ui.PromptPasswordBox("Password");
        _delayPassword.PasswordChanged += (_, _) => settings.DelayPassword = _delayPassword.Password;
        OnEnter(_delayPassword, () => _ = RunAsync(settings.ApplyDelayAsync));
        _changeDelay = Ui.Button(SettingsModel.ChangeDelayTitle, ButtonKind.Accent, onClick: () => _ = RunAsync(settings.ApplyDelayAsync));
        Border delaySection = SectionCard.Create(SettingsModel.DelayTitle, delayRow, _delayHint, delayPasswordHost, _delayFeedback.Element, RightAligned(_changeDelay));

        // The change-password form.
        (Grid oldHost, _oldPassword) = Ui.PromptPasswordBox("Current password");
        (Grid newHost, _newPassword) = Ui.PromptPasswordBox("New password");
        (Grid confirmHost, _confirmPassword) = Ui.PromptPasswordBox("Confirm new password");
        _oldPassword.PasswordChanged += (_, _) => settings.OldPassword = _oldPassword.Password;
        _newPassword.PasswordChanged += (_, _) => settings.NewPassword = _newPassword.Password;
        _confirmPassword.PasswordChanged += (_, _) => settings.ConfirmPassword = _confirmPassword.Password;
        OnEnter(_confirmPassword, () => _ = RunAsync(settings.ChangePasswordAsync));
        _changePassword = Ui.Button(SettingsModel.ChangePasswordTitle, ButtonKind.Accent, onClick: () => _ = RunAsync(settings.ChangePasswordAsync));
        Border passwordSection = SectionCard.Create(SettingsModel.PasswordTitle, Ui.Stack(6).With(oldHost, newHost, confirmHost), Ui.Caption(SettingsModel.PasswordRuleText), _passwordProblem, _passwordFeedback.Element, RightAligned(_changePassword));

        // The adult filter note, which has no controls.
        _adultFilter = SectionCard.Create(SettingsModel.AdultFilterTitle, Ui.Text(SettingsModel.AdultFilterText, ThemeKeys.TextSecondary));

        // The version and the manual update check.
        _checkForUpdates = Ui.Button(SettingsModel.CheckForUpdatesTitle, small: true, onClick: () => _ = CheckForUpdatesAsync());
        var updatesRow = new DockPanel { LastChildFill = false };
        TextBlock version = Ui.Text(SettingsModel.VersionLine);
        version.VerticalAlignment = VerticalAlignment.Center;
        StackPanel checkRow = Ui.Row(8, _checking, _checkForUpdates);
        DockPanel.SetDock(version, Dock.Left);
        DockPanel.SetDock(checkRow, Dock.Right);
        updatesRow.Children.Add(version);
        updatesRow.Children.Add(checkRow);
        Border updatesSection = SectionCard.Create(SettingsModel.UpdatesTitle, updatesRow, _checkResult);

        // The uninstall form.
        _openUninstall = Ui.Button(SettingsModel.UninstallButtonTitle, ButtonKind.Destructive, onClick: () =>
        {
            settings.OpenUninstallForm();
            context.RequestUpdate();
        });
        _openUninstall.HorizontalAlignment = HorizontalAlignment.Left;
        (Grid uninstallHost, _uninstallPassword) = Ui.PromptPasswordBox("Password");
        _uninstallPassword.PasswordChanged += (_, _) => settings.UninstallPassword = _uninstallPassword.Password;
        OnEnter(_uninstallPassword, () => _ = RunAsync(settings.StartUninstallAsync));
        _startUninstall = Ui.Button(SettingsModel.StartUninstallTitle, ButtonKind.Blocked, small: true, () => _ = RunAsync(settings.StartUninstallAsync));
        StackPanel uninstallButtons = Ui.Row(6, Ui.Button("Cancel", small: true, onClick: () =>
        {
            settings.CancelUninstallForm();
            context.RequestUpdate();
        }), _startUninstall);
        uninstallButtons.Margin = new Thickness(6, 0, 0, 0);
        _uninstallForm = new DockPanel();
        DockPanel.SetDock(uninstallButtons, Dock.Right);
        _uninstallForm.Children.Add(uninstallButtons);
        _uninstallForm.Children.Add(uninstallHost);
        Border uninstallSection = SectionCard.Create(SettingsModel.UninstallTitle, _uninstallText, _uninstallScheduled, _uninstallForm, _openUninstall, _uninstallFeedback.Element);

        // The contact note, which has no controls.
        Border contactSection = SectionCard.Create(SettingsModel.ContactTitle, Ui.Text(SettingsModel.ContactText, ThemeKeys.TextSecondary));

        SpacedStack forms = Ui.Stack(12).With(_banners.Element, delaySection, passwordSection, _adultFilter, updatesSection, uninstallSection, contactSection);
        forms.Margin = new Thickness(16);
        var scroll = new OverlayScrollViewer(forms) { MaxHeight = MaxFormHeight };
        _serviceVersion.HorizontalAlignment = HorizontalAlignment.Center;
        _serviceVersion.Margin = new Thickness(0, 8, 0, 8);
        Root = Ui.Stack(0).With(navigation, Ui.Divider(), scroll, Ui.Divider(), _serviceVersion);
    }

    /// <summary>The screen's root element.</summary>
    public FrameworkElement Root { get; }

    /// <summary>Brings every form, line and button up to date.</summary>
    public void Update()
    {
        SettingsModel settings = _context.Panel.Settings;
        _banners.Update();

        _delayPicker.Set(settings.DelayOptions.Select(seconds => (seconds, SettingsModel.DelayLabelFor(seconds))).ToList(), settings.ShownDelay, SettingsModel.DelayLabelFor(settings.ShownDelay));
        _delayHint.Text = settings.DelayHint;
        Ui.Sync(_delayPassword, settings.DelayPassword);
        _delayFeedback.Update(_context.Status.Feedback);
        _changeDelay.IsEnabled = settings.CanChangeDelay;

        Ui.Sync(_oldPassword, settings.OldPassword);
        Ui.Sync(_newPassword, settings.NewPassword);
        Ui.Sync(_confirmPassword, settings.ConfirmPassword);
        _passwordProblem.Set(settings.PasswordProblem, true);
        _passwordFeedback.Update(_context.Status.Feedback);
        _changePassword.IsEnabled = settings.CanChangePassword;

        _adultFilter.Show(settings.ShowsAdultFilter);

        _checking.Show(settings.IsCheckingForUpdates);
        _checkForUpdates.IsEnabled = settings.CanCheckForUpdates;
        _checkResult.Set(settings.CheckResultText, settings.CheckResultIsError);

        _uninstallText.Text = settings.UninstallExplanation;
        _uninstallScheduled.Show(settings.UninstallScheduled);
        _uninstallForm.Show(!settings.UninstallScheduled && settings.ConfirmingUninstall);
        _openUninstall.Show(!settings.UninstallScheduled && !settings.ConfirmingUninstall);
        Ui.Sync(_uninstallPassword, settings.UninstallPassword);
        _startUninstall.IsEnabled = settings.CanStartUninstall;
        _uninstallFeedback.Update(_context.Status.Feedback);
        if (settings.FocusUninstallRequested)
        {
            settings.FocusUninstallRequested = false;
            Ui.FocusSoon(_uninstallPassword);
        }

        _serviceVersion.Text = settings.ServiceVersionLine;
    }

    /// <summary>Puts a button at the right edge of its row.</summary>
    private static FrameworkElement RightAligned(Button button)
    {
        button.HorizontalAlignment = HorizontalAlignment.Right;
        return button;
    }

    /// <summary>Runs an action when Enter is pressed in a field.</summary>
    private static void OnEnter(UIElement field, Action action) => field.KeyDown += (_, e) =>
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        action();
    };

    /// <summary>Runs one of the forms' commands and redraws when it ends.</summary>
    private async Task RunAsync(Func<Task<bool>> command)
    {
        await command();
        _context.RequestUpdate();
    }

    /// <summary>Runs a manual update check and redraws when it ends.</summary>
    private async Task CheckForUpdatesAsync()
    {
        await _context.Panel.Settings.CheckForUpdatesAsync();
        _context.RequestUpdate();
    }
}
