using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>
/// The inline "Choose a SiteBlock password" form: the title, an optional sentence naming the site that will be blocked, the explanation, the two password fields, the minimum length, the warning, any complaint, and the Cancel and submit buttons.
/// </summary>
internal sealed class SetupFormView
{
    private readonly ViewContext _context;
    private readonly SetupFormModel _form;
    private readonly Func<string?> _detail;
    private readonly TextBlock _detailText = Ui.Text();
    private readonly PasswordBox _password;
    private readonly PasswordBox _confirmation;
    private readonly MessageLine _problem = new();
    private readonly FeedbackLine _feedback = new(() => FeedbackScope.Setup);
    private readonly Button _submit;

    /// <summary>Creates the form. <paramref name="detail"/> gives the sentence under the title (or null for none); <paramref name="cancel"/> runs on Cancel.</summary>
    public SetupFormView(ViewContext context, SetupFormModel form, Func<string?> detail, Action cancel)
    {
        _context = context;
        _form = form;
        _detail = detail;
        (Grid passwordHost, _password) = Ui.PromptPasswordBox(SetupFormModel.NewPrompt);
        (Grid confirmationHost, _confirmation) = Ui.PromptPasswordBox(SetupFormModel.ConfirmPrompt);
        _password.PasswordChanged += (_, _) => _form.Password = _password.Password;
        _confirmation.PasswordChanged += (_, _) => _form.Confirmation = _confirmation.Password;
        _confirmation.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            _ = SubmitAsync();
        };

        TextBlock warningIcon = Ui.Glyph(Glyphs.Warning, ThemeKeys.Warning, 12);
        warningIcon.VerticalAlignment = VerticalAlignment.Top;
        warningIcon.Margin = new Thickness(0, 1, 6, 0);
        var warning = new DockPanel();
        DockPanel.SetDock(warningIcon, Dock.Left);
        warning.Children.Add(warningIcon);
        warning.Children.Add(Ui.Text(SetupFormModel.Warning, ThemeKeys.Text, Ui.CaptionSize));

        _submit = Ui.Button(form.SubmitTitle, ButtonKind.Accent, onClick: () => _ = SubmitAsync());
        Button cancelButton = Ui.Button("Cancel", onClick: cancel);
        StackPanel buttons = Ui.Row(8, cancelButton, _submit);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;

        Element = Ui.Stack(10).With(
            Ui.Headline(SetupFormModel.Title),
            _detailText,
            Ui.Text(SetupFormModel.Explanation, ThemeKeys.TextSecondary),
            Ui.Stack(6).With(passwordHost, confirmationHost),
            Ui.Caption(SetupFormModel.MinimumText),
            warning,
            _problem,
            _feedback.Element,
            buttons);
    }

    /// <summary>The element to place.</summary>
    public SpacedStack Element { get; }

    /// <summary>Brings the fields, the complaint, the message and the button up to date, and moves the cursor when the model asks for it.</summary>
    public void Update()
    {
        string? detail = _detail();
        _detailText.Show(detail is not null);
        if (detail is not null && _detailText.Text != detail) _detailText.Text = detail;
        Ui.Sync(_password, _form.Password);
        Ui.Sync(_confirmation, _form.Confirmation);
        _problem.Set(_form.LocalProblem, true);
        _feedback.Update(_context.Status.Feedback);
        _submit.IsEnabled = _form.CanSubmit;
        if (_form.FocusPasswordRequested)
        {
            _form.FocusPasswordRequested = false;
            Ui.FocusSoon(_password);
        }
    }

    /// <summary>Submits the form and redraws.</summary>
    private async Task SubmitAsync()
    {
        await _form.SubmitAsync();
        _context.RequestUpdate();
    }
}
