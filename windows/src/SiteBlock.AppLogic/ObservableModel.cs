using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace SiteBlock.AppLogic;

/// <summary>The base of every model the panel watches: it raises <see cref="PropertyChanged"/> when a property gets a different value, so a window can redraw what changed.</summary>
public abstract class ObservableModel : INotifyPropertyChanged
{
    /// <summary>Raised after a property took a new value; the name is the property's name.</summary>
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Stores <paramref name="value"/> in <paramref name="field"/> and raises <see cref="PropertyChanged"/>, unless the field already holds an equal value. Returns true when it changed.</summary>
    protected bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    /// <summary>Raises <see cref="PropertyChanged"/> for one property (or for every property when the name is null or empty).</summary>
    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
