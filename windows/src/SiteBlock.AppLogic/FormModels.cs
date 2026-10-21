using System.Globalization;
using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>One entry of a menu picker: the value it stands for (null for "nothing chosen") and the words shown.</summary>
/// <param name="Value">The value, in seconds, or null for the "Choose…" entry.</param>
/// <param name="Label">The words in the menu.</param>
public sealed record PickerOption(int? Value, string Label);

/// <summary>
/// The "For a while" form inside a blocked row: how long the site stays open (nothing is picked at first, so the picker reads "Choose…"), when it opens (the soonest the unblock delay allows, marked "(soonest)", unless a later choice is picked), the password, and the gray line with the clock times.
/// "Schedule unblock" is allowed only with a window and a password. Call its members on the screen's thread.
/// </summary>
public sealed class TemporaryUnblockFormModel : ObservableModel
{
    /// <summary>The words of the window picker while nothing is picked.</summary>
    public const string ChooseLabel = "Choose…";
    /// <summary>The label of the window picker.</summary>
    public const string WindowTitle = "How long?";
    /// <summary>The label of the start picker.</summary>
    public const string StartTitle = "Opens in";
    /// <summary>The main button.</summary>
    public const string SubmitTitle = "Schedule unblock";

    private int _delaySeconds;
    private int? _windowSeconds;
    private int? _pickedStart;
    private string _password = "";
    private bool _focusPassword;

    /// <summary>Creates the form for an unblock delay of <paramref name="delaySeconds"/>, which is the soonest the site can open.</summary>
    public TemporaryUnblockFormModel(int delaySeconds) => _delaySeconds = Math.Max(0, delaySeconds);

    /// <summary>The current unblock delay. It can grow while the form is open; a picked start that is no longer offered then falls back to the soonest.</summary>
    public int DelaySeconds
    {
        get => _delaySeconds;
        set
        {
            if (SetField(ref _delaySeconds, Math.Max(0, value))) RaiseDerived();
        }
    }

    /// <summary>The window picked, in seconds, or null while nothing is picked.</summary>
    public int? WindowSeconds
    {
        get => _windowSeconds;
        set
        {
            if (SetField(ref _windowSeconds, value)) RaiseDerived();
        }
    }

    /// <summary>The start wait the person picked, or null while they have not touched the picker (which means the soonest).</summary>
    public int? PickedStart
    {
        get => _pickedStart;
        set
        {
            if (SetField(ref _pickedStart, value)) RaiseDerived();
        }
    }

    /// <summary>The typed password.</summary>
    public string Password
    {
        get => _password;
        set
        {
            if (SetField(ref _password, value ?? "")) OnPropertyChanged(nameof(HasPassword));
        }
    }

    /// <summary>True when a password is typed.</summary>
    public bool HasPassword => Password.Length > 0;

    /// <summary>Set to true when the password field should take the cursor (after a refusal); the view sets it back to false once it has.</summary>
    public bool FocusPasswordRequested { get => _focusPassword; set => SetField(ref _focusPassword, value); }

    /// <summary>The window picker's entries: "Choose…" first, then 15 minutes, 30 minutes, 1 hour, 2 hours and 4 hours.</summary>
    public IReadOnlyList<PickerOption> WindowOptions =>
        [new PickerOption(null, ChooseLabel), .. TemporaryUnblockOptions.WindowChoices.Select(seconds => new PickerOption(seconds, TemporaryUnblockOptions.Label(seconds)))];

    /// <summary>The start picker's entries: the delay itself marked "(soonest)", then each longer wait from the fixed list.</summary>
    public IReadOnlyList<PickerOption> StartOptions => TemporaryUnblockOptions.StartChoices(DelaySeconds).Select(seconds => new PickerOption(seconds, StartLabel(seconds))).ToList();

    /// <summary>The start wait in force: the picked one, or the soonest when none is picked or the picked one is no longer offered.</summary>
    public int StartSeconds => PickedStart is { } picked && TemporaryUnblockOptions.StartChoices(DelaySeconds).Contains(picked) ? picked : DelaySeconds;

    /// <summary>What the window picker reads now: "Choose…" or the picked length.</summary>
    public string WindowLabel => WindowSeconds is { } seconds ? TemporaryUnblockOptions.Label(seconds) : ChooseLabel;

    /// <summary>What the start picker reads now.</summary>
    public string StartLabelText => StartLabel(StartSeconds);

    /// <summary>The menu words for a start wait; the delay itself gets " (soonest)".</summary>
    public string StartLabel(int seconds)
    {
        string text = TemporaryUnblockOptions.Label(seconds);
        return seconds == DelaySeconds ? $"{text} (soonest)" : text;
    }

    /// <summary>True when "Schedule unblock" may be pressed: a window is picked, a password is typed and no command is waiting.</summary>
    public bool CanSubmit(bool busy) => WindowSeconds is not null && Password.Length > 0 && !busy;

    /// <summary>The gray line, such as "Opens at 3:42 PM, blocks again at 4:42 PM.", or only the opening time while no window is picked. The view works it out again when a picker changes and once a minute.</summary>
    public string ScheduleText(DateTimeOffset now, TimeZoneInfo zone, CultureInfo culture) => TemporaryUnblockOptions.ScheduleText(StartSeconds, WindowSeconds, now, zone, culture);

    /// <summary>When the form may be submitted, returns what it collected and empties the password at once, so it never stays on screen; otherwise returns null and changes nothing.</summary>
    public TemporaryUnblockChoice? TakeChoice(bool busy)
    {
        if (!CanSubmit(busy) || WindowSeconds is not { } window) return null;
        var choice = new TemporaryUnblockChoice(window, StartSeconds, Password);
        Password = "";
        return choice;
    }

    /// <summary>Raises the properties computed from the picks.</summary>
    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(StartSeconds));
        OnPropertyChanged(nameof(StartOptions));
        OnPropertyChanged(nameof(WindowLabel));
        OnPropertyChanged(nameof(StartLabelText));
    }
}

/// <summary>
/// The inline "Choose a SiteBlock password" form: a new-password field and a confirm field, the minimum length, a warning that the password cannot be shown again, and two buttons.
/// The home panel shows it under the add field when Block is pressed before any password exists, and inside the "Choose a new password" banner after a reset. It checks that the two entries match and are long enough before anything is sent. Call its members on the screen's thread.
/// </summary>
public sealed class SetupFormModel : ObservableModel
{
    /// <summary>The form's title.</summary>
    public const string Title = "Choose a SiteBlock password";
    /// <summary>The gray sentence under the title.</summary>
    public const string Explanation = "Blocking needs a password so every block can be undone later. It is separate from your Windows sign-in password.";
    /// <summary>The warning next to the triangle.</summary>
    public const string Warning = "SiteBlock cannot show this password again, and you need it to unblock a site, shorten the delay or uninstall. If you forget it, the only way back is a reset started from PowerShell with \"Run as administrator\", followed by a 48 hour wait.";
    /// <summary>The complaint when the two entries differ.</summary>
    public const string MismatchText = "The two passwords are not the same.";
    /// <summary>The placeholder of the first field.</summary>
    public const string NewPrompt = "New password";
    /// <summary>The placeholder of the second field.</summary>
    public const string ConfirmPrompt = "Confirm password";

    private readonly StatusModel _status;
    private readonly Func<string, Task<bool>> _onSubmit;
    private string _password = "";
    private string _confirmation = "";
    private string? _localProblem;
    private bool _focusPassword;

    /// <summary>Creates the form. <paramref name="onSubmit"/> gets the chosen password once the local checks pass and returns true when the form has done its job.</summary>
    public SetupFormModel(StatusModel status, string submitTitle, Func<string, Task<bool>> onSubmit)
    {
        _status = status ?? throw new ArgumentNullException(nameof(status));
        SubmitTitle = submitTitle ?? throw new ArgumentNullException(nameof(submitTitle));
        _onSubmit = onSubmit ?? throw new ArgumentNullException(nameof(onSubmit));
    }

    /// <summary>The main button's words, such as "Set password and block".</summary>
    public string SubmitTitle { get; }

    /// <summary>The minimum length line, "At least 6 characters.".</summary>
    public static string MinimumText => $"At least {PasswordHasher.MinimumLength.ToString(CultureInfo.InvariantCulture)} characters.";

    /// <summary>The first field. Typing something after a complaint removes the complaint.</summary>
    public string Password
    {
        get => _password;
        set
        {
            if (SetField(ref _password, value ?? "") && _password.Length > 0) LocalProblem = null;
        }
    }

    /// <summary>The second field. Typing something after a complaint removes the complaint.</summary>
    public string Confirmation
    {
        get => _confirmation;
        set
        {
            if (SetField(ref _confirmation, value ?? "") && _confirmation.Length > 0) LocalProblem = null;
        }
    }

    /// <summary>A problem found without asking the service (the entries differ, or the password is too short), shown in red.</summary>
    public string? LocalProblem { get => _localProblem; private set => SetField(ref _localProblem, value); }

    /// <summary>Set to true when the first field should take the cursor; the view sets it back to false once it has.</summary>
    public bool FocusPasswordRequested { get => _focusPassword; set => SetField(ref _focusPassword, value); }

    /// <summary>True when the main button may be pressed: both fields hold text and no command is waiting.</summary>
    public bool CanSubmit => Password.Length > 0 && Confirmation.Length > 0 && !_status.IsBusy;

    /// <summary>
    /// Empties both fields, checks that the entries match and pass the same length rule the service applies, and only then hands the password on. A mismatch or a weak password shows inline and nothing is sent.
    /// Returns true when the form has done its job and can go away.
    /// </summary>
    public async Task<bool> SubmitAsync()
    {
        if (!CanSubmit) return false;
        string chosen = Password;
        bool matches = Password == Confirmation;
        // Both fields are emptied whatever happens next, so the password never sits on screen while the service works or after a complaint.
        Password = "";
        Confirmation = "";
        if (!matches)
        {
            LocalProblem = MismatchText;
            FocusPasswordRequested = true;
            return false;
        }
        try
        {
            PasswordHasher.ValidateNew(chosen);
        }
        catch (PasswordException e)
        {
            // The same rule and the same sentence the service would have sent.
            LocalProblem = e.Message;
            FocusPasswordRequested = true;
            return false;
        }
        bool done = await _onSubmit(chosen);
        if (!done) FocusPasswordRequested = true;
        return done;
    }

    /// <summary>Empties the fields and the complaint.</summary>
    public void Reset()
    {
        Password = "";
        Confirmation = "";
        LocalProblem = null;
    }
}
