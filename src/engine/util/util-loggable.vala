/*
 * Copyright 2018 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * Mixin interface for objects that support structured logging.
 *
 * Loggable objects provide both a standard means to obtain a string
 * representation of the object for display to humans, and keep a weak
 * reference to some parent loggable, enabling this context to be
 * automatically added to logging calls. For example, if a Foo object
 * is the loggable parent of a Bar object, log calls made by Bar will
 * automatically be decorated with Foo.
 */
public interface Geary.Loggable : GLib.Object {

    protected struct Context {

        // 8 fields ought to be enough for anybody...
        private const uint8 FIELD_COUNT = 8;

        public GLib.LogField[] fields;
        public uint8 len;
        public uint8 count;

        Context(string domain,
                Logging.Flag flags,
                GLib.LogLevelFlags levels,
                string message,
                va_list args) {
            this.fields = new GLib.LogField[FIELD_COUNT];
            this.len = FIELD_COUNT;
            this.count = 0;
            append("PRIORITY", levels);
            append("GLIB_DOMAIN", domain);
            append("GEARY_FLAGS", flags);
            append("MESSAGE", message.vprintf(args));

            GLib.debug("XXX context: %s", message.vprintf(args));
        }

        public void append<T>(string key, T value) {
            uint8 count = this.count;
            if (count + 1 >= this.len) {
                this.fields.resize(this.len + FIELD_COUNT);
            }

            this.fields[count].key = key;
            this.fields[count].value = value;
            this.fields[count].length = (typeof(T) == typeof(string)) ? -1 : 0;

            this.count++;
        }

        public inline void append_instance<T>(T value) {
            this.append(typeof(T).name(), value);
        }

        public GLib.LogField[] to_array() {
            return this.fields[0:this.count];
        }

    }


    /**
     * Default flags to use for this loggable when logging messages.
     */
    public abstract Logging.Flag loggable_flags { get; protected set; }

    /**
     * The parent of this loggable.
     *
     * If not null, the parent and its ancestors recursively will be
     * added to to log message context.
     */
    public abstract Loggable? loggable_parent { get; }

    /**
     * Returns a string representation of the service, for debugging.
     */
    public abstract string to_string();


    /**
     * Logs a debug-level log message with this object as context.
     */
    [PrintfFormat]
    public inline void debug(string fmt, ...) {
        log_structured(
            this.loggable_flags, LogLevelFlags.LEVEL_DEBUG, fmt, va_list()
        );
    }

    /**
     * Logs a message-level log message with this object as context.
     */
    [PrintfFormat]
    public inline void message(string fmt, ...) {
        log_structured(
            this.loggable_flags, LogLevelFlags.LEVEL_MESSAGE, fmt, va_list()
        );
    }

    /**
     * Logs a warning-level log message with this object as context.
     */
    [PrintfFormat]
    public inline void warning(string fmt, ...) {
        log_structured(
            this.loggable_flags, LogLevelFlags.LEVEL_WARNING, fmt, va_list()
        );
    }

    /**
     * Logs a error-level log message with this object as context.
     */
    [PrintfFormat]
    [NoReturn]
    public inline void error(string fmt, ...) {
        log_structured(
            this.loggable_flags, LogLevelFlags.LEVEL_ERROR, fmt, va_list()
        );
    }

    /**
     * Logs a critical-level log message with this object as context.
     */
    [PrintfFormat]
    public inline void critical(string fmt, ...) {
        log_structured(
            this.loggable_flags, LogLevelFlags.LEVEL_CRITICAL, fmt, va_list()
        );
    }

    private inline void log_structured(Logging.Flag flags,
                                       GLib.LogLevelFlags levels,
                                       string fmt,
                                       va_list args) {
        GLib.debug("XXX log call: %s", fmt.vprintf(args));
        Context context = Context(Logging.DOMAIN, flags, levels, fmt, va_list.copy(args));
        Loggable? decorated = this;
        while (decorated != null) {
            context.append_instance(decorated);
            decorated = decorated.loggable_parent;
        }

        GLib.log_structured_array(levels, context.to_array());
    }

}
