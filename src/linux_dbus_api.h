/* The subset of the libdbus-1 C ABI that ztray uses, loaded at runtime.
 *
 * libdbus-1.so.3 is opened with dlopen when the first D-Bus call is made, so
 * building ztray needs no D-Bus headers, pkg-config or link-time library, and
 * a cross-compiled Linux application gets a working tray on any desktop that
 * ships libdbus (every major distribution does). Without the library,
 * ztray_dbus_load fails and the tray reports DBusUnavailable/TrayInstallFailed.
 *
 * Type layouts and constant values follow the stable libdbus-1 ABI
 * (dbus-errors.h, dbus-message.h, dbus-shared.h, dbus-protocol.h). Call sites
 * keep the libdbus names through the macros below. */
#ifndef ZTRAY_LINUX_DBUS_API_H
#define ZTRAY_LINUX_DBUS_API_H

#include <stdint.h>

typedef uint32_t dbus_uint32_t;
typedef int32_t dbus_int32_t;
typedef dbus_uint32_t dbus_bool_t;

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

typedef struct DBusConnection DBusConnection;
typedef struct DBusMessage DBusMessage;
typedef struct DBusPendingCall DBusPendingCall;

typedef struct DBusError {
    const char *name;
    const char *message;
    unsigned int dummy1 : 1;
    unsigned int dummy2 : 1;
    unsigned int dummy3 : 1;
    unsigned int dummy4 : 1;
    unsigned int dummy5 : 1;
    void *padding1;
} DBusError;

/* Stack-allocated by callers; the layout for pointers of at most 8 bytes. */
typedef struct DBusMessageIter {
    void *dummy1;
    void *dummy2;
    dbus_uint32_t dummy3;
    int dummy4;
    int dummy5;
    int dummy6;
    int dummy7;
    int dummy8;
    int dummy9;
    int dummy10;
    int dummy11;
    int pad1;
    void *pad2;
    void *pad3;
} DBusMessageIter;

typedef enum { DBUS_BUS_SESSION, DBUS_BUS_SYSTEM, DBUS_BUS_STARTER } DBusBusType;

typedef enum {
    DBUS_HANDLER_RESULT_HANDLED,
    DBUS_HANDLER_RESULT_NOT_YET_HANDLED,
    DBUS_HANDLER_RESULT_NEED_MEMORY
} DBusHandlerResult;

typedef DBusHandlerResult (*DBusHandleMessageFunction)(DBusConnection *connection, DBusMessage *message, void *user_data);
typedef void (*DBusFreeFunction)(void *memory);
typedef void (*DBusPendingCallNotifyFunction)(DBusPendingCall *pending, void *user_data);

#define DBUS_NAME_FLAG_DO_NOT_QUEUE 0x4

#define DBUS_TYPE_INVALID ((int)'\0')
#define DBUS_TYPE_BYTE ((int)'y')
#define DBUS_TYPE_BOOLEAN ((int)'b')
#define DBUS_TYPE_INT32 ((int)'i')
#define DBUS_TYPE_UINT32 ((int)'u')
#define DBUS_TYPE_STRING ((int)'s')
#define DBUS_TYPE_OBJECT_PATH ((int)'o')
#define DBUS_TYPE_ARRAY ((int)'a')
#define DBUS_TYPE_VARIANT ((int)'v')
#define DBUS_TYPE_STRUCT ((int)'r')
#define DBUS_TYPE_DICT_ENTRY ((int)'e')

#define DBUS_MESSAGE_TYPE_METHOD_CALL 1
#define DBUS_MESSAGE_TYPE_METHOD_RETURN 2

#define DBUS_ERROR_INVALID_ARGS "org.freedesktop.DBus.Error.InvalidArgs"

#define ZTRAY_DBUS_FUNCTIONS(X) \
    X(DBusConnection *, bus_get, (DBusBusType type, DBusError *error)) \
    X(int, bus_request_name, (DBusConnection *connection, const char *name, unsigned int flags, DBusError *error)) \
    X(dbus_bool_t, connection_add_filter, (DBusConnection *connection, DBusHandleMessageFunction function, void *user_data, DBusFreeFunction free_data_function)) \
    X(void, connection_flush, (DBusConnection *connection)) \
    X(dbus_bool_t, connection_read_write_dispatch, (DBusConnection *connection, int timeout_milliseconds)) \
    X(void, connection_remove_filter, (DBusConnection *connection, DBusHandleMessageFunction function, void *user_data)) \
    X(dbus_bool_t, connection_send, (DBusConnection *connection, DBusMessage *message, dbus_uint32_t *client_serial)) \
    X(dbus_bool_t, connection_send_with_reply, (DBusConnection *connection, DBusMessage *message, DBusPendingCall **pending_return, int timeout_milliseconds)) \
    X(void, connection_unref, (DBusConnection *connection)) \
    X(void, error_free, (DBusError *error)) \
    X(void, error_init, (DBusError *error)) \
    X(dbus_bool_t, message_append_args, (DBusMessage *message, int first_arg_type, ...)) \
    X(const char *, message_get_interface, (DBusMessage *message)) \
    X(const char *, message_get_member, (DBusMessage *message)) \
    X(const char *, message_get_path, (DBusMessage *message)) \
    X(int, message_get_type, (DBusMessage *message)) \
    X(dbus_bool_t, message_has_signature, (DBusMessage *message, const char *signature)) \
    X(dbus_bool_t, message_iter_append_basic, (DBusMessageIter *iter, int type, const void *value)) \
    X(dbus_bool_t, message_iter_append_fixed_array, (DBusMessageIter *iter, int element_type, const void *value, int n_elements)) \
    X(dbus_bool_t, message_iter_close_container, (DBusMessageIter *iter, DBusMessageIter *sub)) \
    X(void, message_iter_get_basic, (DBusMessageIter *iter, void *value)) \
    X(dbus_bool_t, message_iter_init, (DBusMessage *message, DBusMessageIter *iter)) \
    X(void, message_iter_init_append, (DBusMessage *message, DBusMessageIter *iter)) \
    X(dbus_bool_t, message_iter_next, (DBusMessageIter *iter)) \
    X(dbus_bool_t, message_iter_open_container, (DBusMessageIter *iter, int type, const char *contained_signature, DBusMessageIter *sub)) \
    X(DBusMessage *, message_new_error, (DBusMessage *reply_to, const char *error_name, const char *error_message)) \
    X(DBusMessage *, message_new_method_call, (const char *bus_name, const char *path, const char *iface, const char *method)) \
    X(DBusMessage *, message_new_method_return, (DBusMessage *method_call)) \
    X(DBusMessage *, message_new_signal, (const char *path, const char *iface, const char *name)) \
    X(void, message_unref, (DBusMessage *message)) \
    X(void, pending_call_cancel, (DBusPendingCall *pending)) \
    X(dbus_bool_t, pending_call_set_notify, (DBusPendingCall *pending, DBusPendingCallNotifyFunction function, void *user_data, DBusFreeFunction free_user_data)) \
    X(DBusMessage *, pending_call_steal_reply, (DBusPendingCall *pending)) \
    X(void, pending_call_unref, (DBusPendingCall *pending))

#define ZTRAY_DBUS_FIELD(ret, name, params) ret (*name) params;
typedef struct {
    ZTRAY_DBUS_FUNCTIONS(ZTRAY_DBUS_FIELD)
} ZTrayDBusApi;
#undef ZTRAY_DBUS_FIELD

extern ZTrayDBusApi ztray_dbus;

/* 1 once every function resolved from libdbus-1.so.3, 0 if it is missing. */
int ztray_dbus_load(void);

#define dbus_bus_get (ztray_dbus.bus_get)
#define dbus_bus_request_name (ztray_dbus.bus_request_name)
#define dbus_connection_add_filter (ztray_dbus.connection_add_filter)
#define dbus_connection_flush (ztray_dbus.connection_flush)
#define dbus_connection_read_write_dispatch (ztray_dbus.connection_read_write_dispatch)
#define dbus_connection_remove_filter (ztray_dbus.connection_remove_filter)
#define dbus_connection_send (ztray_dbus.connection_send)
#define dbus_connection_send_with_reply (ztray_dbus.connection_send_with_reply)
#define dbus_connection_unref (ztray_dbus.connection_unref)
#define dbus_error_free (ztray_dbus.error_free)
#define dbus_error_init (ztray_dbus.error_init)
#define dbus_message_append_args (ztray_dbus.message_append_args)
#define dbus_message_get_interface (ztray_dbus.message_get_interface)
#define dbus_message_get_member (ztray_dbus.message_get_member)
#define dbus_message_get_path (ztray_dbus.message_get_path)
#define dbus_message_get_type (ztray_dbus.message_get_type)
#define dbus_message_has_signature (ztray_dbus.message_has_signature)
#define dbus_message_iter_append_basic (ztray_dbus.message_iter_append_basic)
#define dbus_message_iter_append_fixed_array (ztray_dbus.message_iter_append_fixed_array)
#define dbus_message_iter_close_container (ztray_dbus.message_iter_close_container)
#define dbus_message_iter_get_basic (ztray_dbus.message_iter_get_basic)
#define dbus_message_iter_init (ztray_dbus.message_iter_init)
#define dbus_message_iter_init_append (ztray_dbus.message_iter_init_append)
#define dbus_message_iter_next (ztray_dbus.message_iter_next)
#define dbus_message_iter_open_container (ztray_dbus.message_iter_open_container)
#define dbus_message_new_error (ztray_dbus.message_new_error)
#define dbus_message_new_method_call (ztray_dbus.message_new_method_call)
#define dbus_message_new_method_return (ztray_dbus.message_new_method_return)
#define dbus_message_new_signal (ztray_dbus.message_new_signal)
#define dbus_message_unref (ztray_dbus.message_unref)
#define dbus_pending_call_cancel (ztray_dbus.pending_call_cancel)
#define dbus_pending_call_set_notify (ztray_dbus.pending_call_set_notify)
#define dbus_pending_call_steal_reply (ztray_dbus.pending_call_steal_reply)
#define dbus_pending_call_unref (ztray_dbus.pending_call_unref)

#endif
