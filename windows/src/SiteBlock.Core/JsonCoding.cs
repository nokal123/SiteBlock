using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SiteBlock.Core;

/// <summary>
/// The shared JSON reading and writing for the pipe protocol and the state file. It reads and writes the same JSON the Swift version does:
/// camelCase field names, enums as their string names, keys written in sorted order at every level, absent optional fields left out, missing optional keys read as null,
/// unknown keys ignored, and a missing required key or a value of the wrong type refused. Every type's converter is attached with <see cref="JsonConverterAttribute"/>,
/// so plain <see cref="JsonSerializer"/> calls give the same results.
/// </summary>
public static class JsonCoding
{
    /// <summary>The serializer settings: one-line output, and non-ASCII text written as UTF-8 instead of <c>\u</c> escapes so the state file stays readable.</summary>
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    /// <summary>Builds the read-only settings object.</summary>
    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, WriteIndented = false };
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }

    /// <summary>Encodes a value as one line of UTF-8 JSON with sorted keys. Throws <see cref="JsonException"/> when a value cannot be written (for example a countdown holding NaN).</summary>
    public static byte[] Encode<T>(T value)
    {
        try
        {
            return JsonSerializer.SerializeToUtf8Bytes(value, Options);
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException)
        {
            throw new JsonException(error.Message, error);
        }
    }

    /// <summary>Encodes a value as one line of JSON text with sorted keys.</summary>
    public static string EncodeToString<T>(T value) => System.Text.Encoding.UTF8.GetString(Encode(value));

    /// <summary>
    /// Decodes UTF-8 JSON into a value, or throws <see cref="JsonException"/> for anything that is not a complete, valid value of that type (including the JSON literal null).
    /// A leading UTF-8 byte order mark, which some Windows editors add, is skipped.
    /// </summary>
    public static T Decode<T>(ReadOnlySpan<byte> utf8) where T : class
    {
        if (utf8.Length >= 3 && utf8[0] == 0xEF && utf8[1] == 0xBB && utf8[2] == 0xBF) utf8 = utf8[3..];
        try
        {
            return JsonSerializer.Deserialize<T>(utf8, Options) ?? throw new JsonException("The JSON value is null.");
        }
        catch (JsonException)
        {
            throw;
        }
        catch (Exception error) when (error is InvalidOperationException or FormatException or ArgumentException or NotSupportedException)
        {
            throw new JsonException(error.Message, error);
        }
    }

    /// <summary>Decodes JSON text into a value; see the byte overload.</summary>
    public static T Decode<T>(string json) where T : class => Decode<T>(System.Text.Encoding.UTF8.GetBytes(json ?? throw new ArgumentNullException(nameof(json))));

    /// <summary>Decodes UTF-8 JSON into a value, or returns null when it does not decode; it never throws.</summary>
    public static T? TryDecode<T>(ReadOnlySpan<byte> utf8) where T : class
    {
        try
        {
            return Decode<T>(utf8);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>Strict helpers for reading fields out of a parsed JSON object, matching what Swift's JSONDecoder accepts.</summary>
internal static class JsonRead
{
    /// <summary>Throws unless the value is a JSON object, as decoding a Swift struct requires.</summary>
    public static void RequireObject(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object) throw new JsonException($"Expected a JSON object but found {element.ValueKind}.");
    }

    /// <summary>The value of a required key; a missing key or a null value is refused, as Swift's <c>decode</c> refuses both.</summary>
    public static JsonElement Required(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out JsonElement value)) throw new JsonException($"The key '{key}' is missing.");
        if (value.ValueKind == JsonValueKind.Null) throw new JsonException($"The key '{key}' is null.");
        return value;
    }

    /// <summary>The value of an optional key, or null when the key is missing or holds null, as Swift's <c>decodeIfPresent</c> reads both as nil.</summary>
    public static JsonElement? Optional(JsonElement obj, string key) =>
        obj.TryGetProperty(key, out JsonElement value) && value.ValueKind != JsonValueKind.Null ? value : null;

    /// <summary>A JSON string; anything else is refused (Swift does not turn numbers into strings).</summary>
    public static string String(JsonElement element) =>
        element.ValueKind == JsonValueKind.String ? element.GetString()! : throw new JsonException($"Expected a string but found {element.ValueKind}.");

    /// <summary>
    /// A JSON number that is a whole number fitting in 64 bits. A number written with a fraction or exponent is accepted when its value is exactly whole (as Foundation's older decoder did); anything else is refused.
    /// </summary>
    public static long Integer(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Number) throw new JsonException($"Expected a number but found {element.ValueKind}.");
        if (element.TryGetInt64(out long value)) return value;
        if (element.TryGetDouble(out double number) && Math.Floor(number) == number && number >= -9.2233720368547758E18 && number < 9.2233720368547758E18) return (long)number;
        throw new JsonException("The number is not a whole number that fits in 64 bits.");
    }

    /// <summary>A JSON number read as a finite double; a value too large for a double is refused.</summary>
    public static double Double(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Number) throw new JsonException($"Expected a number but found {element.ValueKind}.");
        if (element.TryGetDouble(out double value) && double.IsFinite(value)) return value;
        throw new JsonException("The number does not fit in a double.");
    }

    /// <summary>A JSON true or false; numbers are not accepted as booleans.</summary>
    public static bool Bool(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new JsonException($"Expected true or false but found {element.ValueKind}."),
    };

    /// <summary>A JSON array whose every entry is read with <paramref name="read"/>; a null entry or one of the wrong type is refused.</summary>
    public static List<T> Array<T>(JsonElement element, Func<JsonElement, T> read)
    {
        if (element.ValueKind != JsonValueKind.Array) throw new JsonException($"Expected an array but found {element.ValueKind}.");
        var result = new List<T>(element.GetArrayLength());
        foreach (JsonElement item in element.EnumerateArray()) result.Add(read(item));
        return result;
    }

    /// <summary>A JSON array of strings.</summary>
    public static List<string> StringArray(JsonElement element) => Array(element, String);

    /// <summary>A JSON object whose every value is an array of strings, such as <c>savedDNS</c>. A repeated key keeps its last value.</summary>
    public static Dictionary<string, List<string>> StringArrayMap(JsonElement element)
    {
        RequireObject(element);
        var result = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject()) result[property.Name] = StringArray(property.Value);
        return result;
    }

    /// <summary>Parses the reader's current value and reads it with <paramref name="read"/>, turning any lower-level failure (such as an invalid escape in a string) into a <see cref="JsonException"/>.</summary>
    public static T Parse<T>(ref Utf8JsonReader reader, Func<JsonElement, T> read)
    {
        using JsonDocument document = JsonDocument.ParseValue(ref reader);
        try
        {
            return read(document.RootElement);
        }
        catch (Exception error) when (error is InvalidOperationException or FormatException or ArgumentException)
        {
            throw new JsonException(error.Message, error);
        }
    }
}

/// <summary>Strict helpers for writing JSON fields, refusing values the Swift encoder would also refuse.</summary>
internal static class JsonWrite
{
    /// <summary>Writes a finite number; NaN and infinity are refused, as Swift's encoder refuses them by default.</summary>
    public static void Number(Utf8JsonWriter writer, string name, double value)
    {
        if (!double.IsFinite(value)) throw new JsonException($"The value of '{name}' is not a finite number.");
        writer.WriteNumber(name, value);
    }

    /// <summary>Writes an optional whole number, leaving the key out when it is null.</summary>
    public static void OptionalInteger(Utf8JsonWriter writer, string name, long? value)
    {
        if (value is long number) writer.WriteNumber(name, number);
    }

    /// <summary>Writes an optional string, leaving the key out when it is null.</summary>
    public static void OptionalString(Utf8JsonWriter writer, string name, string? value)
    {
        if (value is not null) writer.WriteString(name, value);
    }

    /// <summary>Writes an array of strings in its own order.</summary>
    public static void StringArray(Utf8JsonWriter writer, string name, IEnumerable<string> values)
    {
        writer.WriteStartArray(name);
        foreach (string value in values) writer.WriteStringValue(value);
        writer.WriteEndArray();
    }

    /// <summary>Writes an optional nested object with <paramref name="write"/>, leaving the key out when it is null.</summary>
    public static void OptionalObject<T>(Utf8JsonWriter writer, string name, T? value, Action<Utf8JsonWriter, T> write) where T : class
    {
        if (value is null) return;
        writer.WritePropertyName(name);
        write(writer, value);
    }

    /// <summary>Writes a nested object with <paramref name="write"/>.</summary>
    public static void Object<T>(Utf8JsonWriter writer, string name, T value, Action<Utf8JsonWriter, T> write)
    {
        writer.WritePropertyName(name);
        write(writer, value);
    }
}

/// <summary>Reads and writes <see cref="Countdown"/>.</summary>
internal sealed class CountdownJsonConverter : JsonConverter<Countdown>
{
    /// <summary>Reads a countdown object; both fields are required.</summary>
    public static Countdown FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new Countdown(JsonRead.Double(JsonRead.Required(e, "remainingSeconds")), JsonRead.Double(JsonRead.Required(e, "totalSeconds")));
    }

    /// <summary>Writes a countdown object with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, Countdown v)
    {
        w.WriteStartObject();
        JsonWrite.Number(w, "remainingSeconds", v.RemainingSeconds);
        JsonWrite.Number(w, "totalSeconds", v.TotalSeconds);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override Countdown Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, Countdown value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="PasswordHash"/>.</summary>
internal sealed class PasswordHashJsonConverter : JsonConverter<PasswordHash>
{
    /// <summary>Reads a password hash object; all four fields are required.</summary>
    public static PasswordHash FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new PasswordHash(JsonRead.String(JsonRead.Required(e, "algorithm")), JsonRead.Integer(JsonRead.Required(e, "iterations")), JsonRead.String(JsonRead.Required(e, "salt")), JsonRead.String(JsonRead.Required(e, "hash")));
    }

    /// <summary>Writes a password hash object with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, PasswordHash v)
    {
        w.WriteStartObject();
        w.WriteString("algorithm", v.Algorithm);
        w.WriteString("hash", v.Hash);
        w.WriteNumber("iterations", v.Iterations);
        w.WriteString("salt", v.Salt);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override PasswordHash Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, PasswordHash value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="TemporaryUnblock"/>.</summary>
internal sealed class TemporaryUnblockJsonConverter : JsonConverter<TemporaryUnblock>
{
    /// <summary>Reads a temporary unblock object; both countdowns are required.</summary>
    public static TemporaryUnblock FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new TemporaryUnblock(CountdownJsonConverter.FromJson(JsonRead.Required(e, "startsIn")), CountdownJsonConverter.FromJson(JsonRead.Required(e, "window")));
    }

    /// <summary>
    /// Reads the optional <c>temporaryUnblock</c> key of a site or path rule the way Swift's <c>try? decodeIfPresent</c> does: a missing or null key, and a record that cannot be read, all give null,
    /// so a damaged record only means the site stays blocked while the rest of the file still loads.
    /// </summary>
    public static TemporaryUnblock? FromJsonOrDrop(JsonElement owner, string key)
    {
        if (JsonRead.Optional(owner, key) is not JsonElement value) return null;
        try
        {
            return FromJson(value);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    /// <summary>Writes a temporary unblock object with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, TemporaryUnblock v)
    {
        w.WriteStartObject();
        JsonWrite.Object(w, "startsIn", v.StartsIn, CountdownJsonConverter.ToJson);
        JsonWrite.Object(w, "window", v.Window, CountdownJsonConverter.ToJson);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override TemporaryUnblock Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, TemporaryUnblock value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="BlockedSite"/>.</summary>
internal sealed class BlockedSiteJsonConverter : JsonConverter<BlockedSite>
{
    /// <summary>Reads a site; <c>domain</c> and <c>hosts</c> are required, and an unreadable <c>temporaryUnblock</c> is dropped.</summary>
    public static BlockedSite FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        string domain = JsonRead.String(JsonRead.Required(e, "domain"));
        List<string> hosts = JsonRead.StringArray(JsonRead.Required(e, "hosts"));
        Countdown? pending = JsonRead.Optional(e, "pendingUnblock") is JsonElement p ? CountdownJsonConverter.FromJson(p) : null;
        return new BlockedSite(domain, hosts, pending, TemporaryUnblockJsonConverter.FromJsonOrDrop(e, "temporaryUnblock"));
    }

    /// <summary>Writes a site with sorted keys, leaving out absent unblocks.</summary>
    public static void ToJson(Utf8JsonWriter w, BlockedSite v)
    {
        w.WriteStartObject();
        w.WriteString("domain", v.Domain);
        JsonWrite.StringArray(w, "hosts", v.Hosts);
        JsonWrite.OptionalObject(w, "pendingUnblock", v.PendingUnblock, CountdownJsonConverter.ToJson);
        JsonWrite.OptionalObject(w, "temporaryUnblock", v.TemporaryUnblock, TemporaryUnblockJsonConverter.ToJson);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override BlockedSite Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, BlockedSite value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="BlockedPath"/>.</summary>
internal sealed class BlockedPathJsonConverter : JsonConverter<BlockedPath>
{
    /// <summary>Reads a path rule; <c>domain</c> and <c>path</c> are required, and an unreadable <c>temporaryUnblock</c> is dropped.</summary>
    public static BlockedPath FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        string domain = JsonRead.String(JsonRead.Required(e, "domain"));
        string path = JsonRead.String(JsonRead.Required(e, "path"));
        Countdown? pending = JsonRead.Optional(e, "pendingUnblock") is JsonElement p ? CountdownJsonConverter.FromJson(p) : null;
        return new BlockedPath(domain, path, pending, TemporaryUnblockJsonConverter.FromJsonOrDrop(e, "temporaryUnblock"));
    }

    /// <summary>Writes a path rule with sorted keys, leaving out absent unblocks.</summary>
    public static void ToJson(Utf8JsonWriter w, BlockedPath v)
    {
        w.WriteStartObject();
        w.WriteString("domain", v.Domain);
        w.WriteString("path", v.Path);
        JsonWrite.OptionalObject(w, "pendingUnblock", v.PendingUnblock, CountdownJsonConverter.ToJson);
        JsonWrite.OptionalObject(w, "temporaryUnblock", v.TemporaryUnblock, TemporaryUnblockJsonConverter.ToJson);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override BlockedPath Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, BlockedPath value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="PendingDelayChange"/>.</summary>
internal sealed class PendingDelayChangeJsonConverter : JsonConverter<PendingDelayChange>
{
    /// <summary>Reads a pending delay change; both fields are required.</summary>
    public static PendingDelayChange FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new PendingDelayChange(JsonRead.Integer(JsonRead.Required(e, "newDelaySeconds")), CountdownJsonConverter.FromJson(JsonRead.Required(e, "countdown")));
    }

    /// <summary>Writes a pending delay change with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, PendingDelayChange v)
    {
        w.WriteStartObject();
        JsonWrite.Object(w, "countdown", v.Countdown, CountdownJsonConverter.ToJson);
        w.WriteNumber("newDelaySeconds", v.NewDelaySeconds);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override PendingDelayChange Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, PendingDelayChange value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="PersistedState"/>, the whole of <c>state.json</c>.</summary>
internal sealed class PersistedStateJsonConverter : JsonConverter<PersistedState>
{
    /// <summary>
    /// Reads a state. The fields of the first release (<c>version</c>, <c>blocked</c>, <c>delaySeconds</c>, <c>failedAttempts</c>, <c>uninstalling</c>) are required, so <c>{}</c> fails;
    /// every other field may be missing or null.
    /// </summary>
    public static PersistedState FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        long version = JsonRead.Integer(JsonRead.Required(e, "version"));
        PasswordHash? passwordHash = JsonRead.Optional(e, "passwordHash") is JsonElement ph ? PasswordHashJsonConverter.FromJson(ph) : null;
        List<BlockedSite> blocked = JsonRead.Array(JsonRead.Required(e, "blocked"), BlockedSiteJsonConverter.FromJson);
        long delaySeconds = JsonRead.Integer(JsonRead.Required(e, "delaySeconds"));
        PendingDelayChange? pendingDelayChange = JsonRead.Optional(e, "pendingDelayChange") is JsonElement pd ? PendingDelayChangeJsonConverter.FromJson(pd) : null;
        Countdown? pendingUninstall = JsonRead.Optional(e, "pendingUninstall") is JsonElement pu ? CountdownJsonConverter.FromJson(pu) : null;
        Countdown? recovery = JsonRead.Optional(e, "recovery") is JsonElement r ? CountdownJsonConverter.FromJson(r) : null;
        long failedAttempts = JsonRead.Integer(JsonRead.Required(e, "failedAttempts"));
        Countdown? lockout = JsonRead.Optional(e, "lockout") is JsonElement l ? CountdownJsonConverter.FromJson(l) : null;
        bool uninstalling = JsonRead.Bool(JsonRead.Required(e, "uninstalling"));
        Dictionary<string, List<string>>? savedDNS = JsonRead.Optional(e, "savedDNS") is JsonElement s ? JsonRead.StringArrayMap(s) : null;
        List<BlockedPath>? blockedPaths = JsonRead.Optional(e, "blockedPaths") is JsonElement bp ? JsonRead.Array(bp, BlockedPathJsonConverter.FromJson) : null;
        return new PersistedState(delaySeconds, version, passwordHash, blocked, pendingDelayChange, pendingUninstall, recovery, failedAttempts, lockout, uninstalling, savedDNS, blockedPaths);
    }

    /// <summary>Writes a state with sorted keys at every level, leaving out absent optional fields.</summary>
    public static void ToJson(Utf8JsonWriter w, PersistedState v)
    {
        w.WriteStartObject();
        w.WriteStartArray("blocked");
        foreach (BlockedSite site in v.Blocked) BlockedSiteJsonConverter.ToJson(w, site);
        w.WriteEndArray();
        if (v.BlockedPaths is { } rules)
        {
            w.WriteStartArray("blockedPaths");
            foreach (BlockedPath rule in rules) BlockedPathJsonConverter.ToJson(w, rule);
            w.WriteEndArray();
        }
        w.WriteNumber("delaySeconds", v.DelaySeconds);
        w.WriteNumber("failedAttempts", v.FailedAttempts);
        JsonWrite.OptionalObject(w, "lockout", v.Lockout, CountdownJsonConverter.ToJson);
        JsonWrite.OptionalObject(w, "passwordHash", v.PasswordHash, PasswordHashJsonConverter.ToJson);
        JsonWrite.OptionalObject(w, "pendingDelayChange", v.PendingDelayChange, PendingDelayChangeJsonConverter.ToJson);
        JsonWrite.OptionalObject(w, "pendingUninstall", v.PendingUninstall, CountdownJsonConverter.ToJson);
        JsonWrite.OptionalObject(w, "recovery", v.Recovery, CountdownJsonConverter.ToJson);
        if (v.SavedDNS is { } saved)
        {
            w.WriteStartObject("savedDNS");
            foreach (string key in saved.Keys.Order(StringComparer.Ordinal)) JsonWrite.StringArray(w, key, saved[key]);
            w.WriteEndObject();
        }
        w.WriteBoolean("uninstalling", v.Uninstalling);
        w.WriteNumber("version", v.Version);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override PersistedState Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, PersistedState value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="Command"/> as its exact wire name.</summary>
internal sealed class CommandJsonConverter : JsonConverter<Command>
{
    /// <summary>Reads a command name; an unknown name (or a different letter case) is refused.</summary>
    public static Command FromJson(JsonElement e) =>
        WireNames.TryParseCommand(JsonRead.String(e), out Command command) ? command : throw new JsonException($"Unknown command '{e.GetString()}'.");

    /// <inheritdoc />
    public override Command Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, Command value, JsonSerializerOptions options) => writer.WriteStringValue(value.WireName());
}

/// <summary>Reads and writes <see cref="ErrorCode"/> as its exact wire name.</summary>
internal sealed class ErrorCodeJsonConverter : JsonConverter<ErrorCode>
{
    /// <summary>Reads an error code name; an unknown name is refused, so a reply with a code this version does not know does not decode (as in Swift).</summary>
    public static ErrorCode FromJson(JsonElement e) =>
        WireNames.TryParseErrorCode(JsonRead.String(e), out ErrorCode code) ? code : throw new JsonException($"Unknown error code '{e.GetString()}'.");

    /// <inheritdoc />
    public override ErrorCode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, ErrorCode value, JsonSerializerOptions options) => writer.WriteStringValue(value.WireName());
}

/// <summary>Reads and writes <see cref="Request"/>.</summary>
internal sealed class RequestJsonConverter : JsonConverter<Request>
{
    /// <summary>Reads a request; only <c>command</c> is required.</summary>
    public static Request FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new Request(
            CommandJsonConverter.FromJson(JsonRead.Required(e, "command")),
            JsonRead.Optional(e, "domain") is JsonElement d ? JsonRead.String(d) : null,
            JsonRead.Optional(e, "password") is JsonElement p ? JsonRead.String(p) : null,
            JsonRead.Optional(e, "newPassword") is JsonElement np ? JsonRead.String(np) : null,
            JsonRead.Optional(e, "seconds") is JsonElement s ? JsonRead.Integer(s) : null,
            JsonRead.Optional(e, "startSeconds") is JsonElement ss ? JsonRead.Integer(ss) : null);
    }

    /// <summary>Writes a request with sorted keys, leaving out absent arguments.</summary>
    public static void ToJson(Utf8JsonWriter w, Request v)
    {
        w.WriteStartObject();
        w.WriteString("command", v.Command.WireName());
        JsonWrite.OptionalString(w, "domain", v.Domain);
        JsonWrite.OptionalString(w, "newPassword", v.NewPassword);
        JsonWrite.OptionalString(w, "password", v.Password);
        JsonWrite.OptionalInteger(w, "seconds", v.Seconds);
        JsonWrite.OptionalInteger(w, "startSeconds", v.StartSeconds);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override Request Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, Request value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="TemporaryUnblockStatus"/>.</summary>
internal sealed class TemporaryUnblockStatusJsonConverter : JsonConverter<TemporaryUnblockStatus>
{
    /// <summary>Reads a temporary unblock status; only <c>opensInSeconds</c> may be missing.</summary>
    public static TemporaryUnblockStatus FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new TemporaryUnblockStatus(
            JsonRead.Optional(e, "opensInSeconds") is JsonElement o ? JsonRead.Integer(o) : null,
            JsonRead.Integer(JsonRead.Required(e, "secondsRemaining")),
            JsonRead.Integer(JsonRead.Required(e, "windowSeconds")),
            JsonRead.Bool(JsonRead.Required(e, "isOpen")));
    }

    /// <summary>Writes a temporary unblock status with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, TemporaryUnblockStatus v)
    {
        w.WriteStartObject();
        w.WriteBoolean("isOpen", v.IsOpen);
        JsonWrite.OptionalInteger(w, "opensInSeconds", v.OpensInSeconds);
        w.WriteNumber("secondsRemaining", v.SecondsRemaining);
        w.WriteNumber("windowSeconds", v.WindowSeconds);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override TemporaryUnblockStatus Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, TemporaryUnblockStatus value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="BlockedSiteStatus"/>.</summary>
internal sealed class BlockedSiteStatusJsonConverter : JsonConverter<BlockedSiteStatus>
{
    /// <summary>Reads a site status; <c>unblockSecondsRemaining</c> and <c>temporaryUnblock</c> may be missing. Unlike the state file, an unreadable temporary unblock here fails the whole reply, as in Swift.</summary>
    public static BlockedSiteStatus FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new BlockedSiteStatus(
            JsonRead.String(JsonRead.Required(e, "domain")),
            JsonRead.StringArray(JsonRead.Required(e, "hosts")),
            JsonRead.Optional(e, "unblockSecondsRemaining") is JsonElement u ? JsonRead.Integer(u) : null,
            JsonRead.Optional(e, "temporaryUnblock") is JsonElement t ? TemporaryUnblockStatusJsonConverter.FromJson(t) : null);
    }

    /// <summary>Writes a site status with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, BlockedSiteStatus v)
    {
        w.WriteStartObject();
        w.WriteString("domain", v.Domain);
        JsonWrite.StringArray(w, "hosts", v.Hosts);
        JsonWrite.OptionalObject(w, "temporaryUnblock", v.TemporaryUnblock, TemporaryUnblockStatusJsonConverter.ToJson);
        JsonWrite.OptionalInteger(w, "unblockSecondsRemaining", v.UnblockSecondsRemaining);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override BlockedSiteStatus Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, BlockedSiteStatus value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="BlockedPathStatus"/>.</summary>
internal sealed class BlockedPathStatusJsonConverter : JsonConverter<BlockedPathStatus>
{
    /// <summary>Reads a path rule status; <c>unblockSecondsRemaining</c> and <c>temporaryUnblock</c> may be missing.</summary>
    public static BlockedPathStatus FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new BlockedPathStatus(
            JsonRead.String(JsonRead.Required(e, "domain")),
            JsonRead.String(JsonRead.Required(e, "path")),
            JsonRead.String(JsonRead.Required(e, "rule")),
            JsonRead.Optional(e, "unblockSecondsRemaining") is JsonElement u ? JsonRead.Integer(u) : null,
            JsonRead.Optional(e, "temporaryUnblock") is JsonElement t ? TemporaryUnblockStatusJsonConverter.FromJson(t) : null);
    }

    /// <summary>Writes a path rule status with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, BlockedPathStatus v)
    {
        w.WriteStartObject();
        w.WriteString("domain", v.Domain);
        w.WriteString("path", v.Path);
        w.WriteString("rule", v.Rule);
        JsonWrite.OptionalObject(w, "temporaryUnblock", v.TemporaryUnblock, TemporaryUnblockStatusJsonConverter.ToJson);
        JsonWrite.OptionalInteger(w, "unblockSecondsRemaining", v.UnblockSecondsRemaining);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override BlockedPathStatus Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, BlockedPathStatus value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="PendingDelayStatus"/>.</summary>
internal sealed class PendingDelayStatusJsonConverter : JsonConverter<PendingDelayStatus>
{
    /// <summary>Reads a pending delay status; both fields are required.</summary>
    public static PendingDelayStatus FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new PendingDelayStatus(JsonRead.Integer(JsonRead.Required(e, "newDelaySeconds")), JsonRead.Integer(JsonRead.Required(e, "secondsRemaining")));
    }

    /// <summary>Writes a pending delay status with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, PendingDelayStatus v)
    {
        w.WriteStartObject();
        w.WriteNumber("newDelaySeconds", v.NewDelaySeconds);
        w.WriteNumber("secondsRemaining", v.SecondsRemaining);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override PendingDelayStatus Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, PendingDelayStatus value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="StatusSnapshot"/>.</summary>
internal sealed class StatusSnapshotJsonConverter : JsonConverter<StatusSnapshot>
{
    /// <summary>Reads a snapshot. A missing <c>adultFilterEnabled</c> reads as false and a missing <c>blockedPaths</c> as an empty list, so an older service and a newer client still work together.</summary>
    public static StatusSnapshot FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new StatusSnapshot(
            JsonRead.String(JsonRead.Required(e, "version")),
            JsonRead.Bool(JsonRead.Required(e, "passwordSet")),
            JsonRead.Array(JsonRead.Required(e, "blocked"), BlockedSiteStatusJsonConverter.FromJson),
            JsonRead.Integer(JsonRead.Required(e, "delaySeconds")),
            JsonRead.Optional(e, "pendingDelay") is JsonElement pd ? PendingDelayStatusJsonConverter.FromJson(pd) : null,
            JsonRead.Optional(e, "uninstallSecondsRemaining") is JsonElement u ? JsonRead.Integer(u) : null,
            JsonRead.Optional(e, "recoverySecondsRemaining") is JsonElement r ? JsonRead.Integer(r) : null,
            JsonRead.Optional(e, "lockoutSecondsRemaining") is JsonElement l ? JsonRead.Integer(l) : null,
            JsonRead.Bool(JsonRead.Required(e, "hostsFileHealthy")),
            JsonRead.Optional(e, "adultFilterEnabled") is JsonElement a ? JsonRead.Bool(a) : false,
            JsonRead.Optional(e, "blockedPaths") is JsonElement bp ? JsonRead.Array(bp, BlockedPathStatusJsonConverter.FromJson) : []);
    }

    /// <summary>Writes a snapshot with sorted keys.</summary>
    public static void ToJson(Utf8JsonWriter w, StatusSnapshot v)
    {
        w.WriteStartObject();
        if (v.AdultFilterEnabled is bool adult) w.WriteBoolean("adultFilterEnabled", adult);
        w.WriteStartArray("blocked");
        foreach (BlockedSiteStatus site in v.Blocked) BlockedSiteStatusJsonConverter.ToJson(w, site);
        w.WriteEndArray();
        if (v.BlockedPaths is { } rules)
        {
            w.WriteStartArray("blockedPaths");
            foreach (BlockedPathStatus rule in rules) BlockedPathStatusJsonConverter.ToJson(w, rule);
            w.WriteEndArray();
        }
        w.WriteNumber("delaySeconds", v.DelaySeconds);
        w.WriteBoolean("hostsFileHealthy", v.HostsFileHealthy);
        JsonWrite.OptionalInteger(w, "lockoutSecondsRemaining", v.LockoutSecondsRemaining);
        w.WriteBoolean("passwordSet", v.PasswordSet);
        JsonWrite.OptionalObject(w, "pendingDelay", v.PendingDelay, PendingDelayStatusJsonConverter.ToJson);
        JsonWrite.OptionalInteger(w, "recoverySecondsRemaining", v.RecoverySecondsRemaining);
        JsonWrite.OptionalInteger(w, "uninstallSecondsRemaining", v.UninstallSecondsRemaining);
        w.WriteString("version", v.Version);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override StatusSnapshot Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, StatusSnapshot value, JsonSerializerOptions options) => ToJson(writer, value);
}

/// <summary>Reads and writes <see cref="Response"/>.</summary>
internal sealed class ResponseJsonConverter : JsonConverter<Response>
{
    /// <summary>Reads a response; only <c>ok</c> is required.</summary>
    public static Response FromJson(JsonElement e)
    {
        JsonRead.RequireObject(e);
        return new Response(
            JsonRead.Bool(JsonRead.Required(e, "ok")),
            JsonRead.Optional(e, "error") is JsonElement er ? JsonRead.String(er) : null,
            JsonRead.Optional(e, "errorCode") is JsonElement c ? ErrorCodeJsonConverter.FromJson(c) : null,
            JsonRead.Optional(e, "status") is JsonElement s ? StatusSnapshotJsonConverter.FromJson(s) : null,
            JsonRead.Optional(e, "message") is JsonElement m ? JsonRead.String(m) : null);
    }

    /// <summary>Writes a response with sorted keys, leaving out absent fields.</summary>
    public static void ToJson(Utf8JsonWriter w, Response v)
    {
        w.WriteStartObject();
        JsonWrite.OptionalString(w, "error", v.Error);
        if (v.ErrorCode is ErrorCode code) w.WriteString("errorCode", code.WireName());
        JsonWrite.OptionalString(w, "message", v.Message);
        w.WriteBoolean("ok", v.Ok);
        JsonWrite.OptionalObject(w, "status", v.Status, StatusSnapshotJsonConverter.ToJson);
        w.WriteEndObject();
    }

    /// <inheritdoc />
    public override Response Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => JsonRead.Parse(ref reader, FromJson);

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, Response value, JsonSerializerOptions options) => ToJson(writer, value);
}
