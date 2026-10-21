using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>The "For a while" form inside a blocked row: the "How long?" and "Opens in" pickers, the gray line with the clock times, the password field, and the Cancel and "Schedule unblock" buttons.</summary>
internal sealed class TemporaryUnblockFormView
{
    private readonly ViewContext _context;
    private readonly BlockedRowModel _row;
    private readonly TemporaryUnblockFormModel _form;
    private readonly MenuPicker<int?> _window = new();
    private readonly MenuPicker<int> _start = new();
    private readonly TextBlock _schedule = Ui.Caption();
    private readonly PasswordBox _password;
    private readonly Button _submit;

    /// <summary>Creates the form for one row's open "For a while" form.</summary>
    public TemporaryUnblockFormView(ViewContext context, BlockedRowModel row, TemporaryUnblockFormModel form)
    {
        _context = context;
        _row = row;
        _form = form;
        _window.Picked += value => _form.WindowSeconds = value;
        _start.Picked += value => _form.PickedStart = value;
        (Grid passwordHost, _password) = Ui.PromptPasswordBox("Password");
        _password.PasswordChanged += (_, _) => _form.Password = _password.Password;
        _password.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            _ = SubmitAsync();
        };
        _submit = Ui.Button(TemporaryUnblockFormModel.SubmitTitle, ButtonKind.Accent, small: true, () => _ = SubmitAsync());
        StackPanel buttons = Ui.Row(8, Ui.Button("Cancel", small: true, onClick: () =>
        {
            _row.CloseForm();
            _context.RequestUpdate();
        }), _submit);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;

        Element = Ui.Stack(8).With(PickerRow(TemporaryUnblockFormModel.WindowTitle, _window), PickerRow(TemporaryUnblockFormModel.StartTitle, _start), _schedule, passwordHost, buttons);
    }

    /// <summary>The element to place.</summary>
    public SpacedStack Element { get; }

    /// <summary>The model this view shows.</summary>
    public TemporaryUnblockFormModel Form => _form;

    /// <summary>One labelled picker: the label on the left and the menu on the right.</summary>
    private static DockPanel PickerRow(string title, Button picker)
    {
        var row = new DockPanel { LastChildFill = false };
        TextBlock label = Ui.Text(title, ThemeKeys.Text, Ui.CaptionSize);
        label.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(label, Dock.Left);
        DockPanel.SetDock(picker, Dock.Right);
        row.Children.Add(label);
        row.Children.Add(picker);
        return row;
    }

    /// <summary>Brings the pickers, the clock-time line (worked out from the current time), the password and the button up to date.</summary>
    public void Update()
    {
        _window.Set(_form.WindowOptions.Select(option => (option.Value, option.Label)).ToList(), _form.WindowSeconds, _form.WindowLabel);
        _start.Set(_form.StartOptions.Select(option => (option.Value ?? 0, option.Label)).ToList(), _form.StartSeconds, _form.StartLabelText);
        string schedule = _form.ScheduleText(_context.Status.Clock.Now, TimeZoneInfo.Local, CultureInfo.CurrentCulture);
        if (_schedule.Text != schedule) _schedule.Text = schedule;
        Ui.Sync(_password, _form.Password);
        _submit.IsEnabled = _form.CanSubmit(_context.Status.IsBusy);
        if (_form.FocusPasswordRequested)
        {
            _form.FocusPasswordRequested = false;
            Ui.FocusSoon(_password);
        }
    }

    /// <summary>Sends the form through the row and redraws.</summary>
    private async Task SubmitAsync()
    {
        await _row.ScheduleTemporaryAsync();
        _context.RequestUpdate();
    }
}
