/*
 * Session D-Bus: com.canonical.dbusmenu for menubar + tray, and org.kde.StatusNotifierItem for Linux tray.
 * libdbus-1 is loaded at runtime (linux_dbus_api.h), so any glibc Linux target builds it.
 */
#include "linux_dbus_api.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void ztray_linux_tray_shutdown(void);
int ztray_linux_dbus_init(void);
int ztray_linux_icon_pixmap_from_png(const unsigned char *data, int len, int *out_width, int *out_height, unsigned char **out_argb);

#define ZTRAY_MENU_PATH "/org/ztray/app/Menu"
#define ZTRAY_TRAY_MENU_PATH "/org/ztray/app/TrayMenu"
#define ZTRAY_SNI_PATH "/org/ztray/app/SNI"
#define ZTRAY_MAX_ITEMS 512

typedef struct {
    int32_t id;
    int32_t parent_id;
    int32_t action_id;
    uint32_t flags;
    uint8_t shortcut_modifiers;
    uint8_t shortcut_key;
    char *label;
} ZTrayItem;

static ZTrayItem g_menubar_items[ZTRAY_MAX_ITEMS];
static int g_n_menubar;
static dbus_uint32_t g_menubar_revision;
static atomic_int g_pending_menubar_action = -1;

static ZTrayItem g_tray_items[ZTRAY_MAX_ITEMS];
static int g_n_tray;
static dbus_uint32_t g_tray_revision;
static atomic_int g_pending_tray_action = -1;

static DBusConnection *g_conn;
static char *g_tray_tooltip = NULL;
static char *g_tray_icon_name = NULL;
static unsigned char *g_tray_icon_argb = NULL;
static int g_tray_icon_width;
static int g_tray_icon_height;
static int g_tray_sni_active;
static atomic_int g_appmenu_registrar_has_owner = -1;
static int g_appmenu_registrar_query_in_flight;
static atomic_int g_tray_host_has_owner = -1;
static int g_tray_host_query_in_flight;

enum { FLAG_SEPARATOR = 1u, FLAG_SUBMENU = 2u, FLAG_DISABLED = 4u };

static void free_menubar_items(void) {
    for (int i = 0; i < g_n_menubar; i++) {
        free(g_menubar_items[i].label);
        g_menubar_items[i].label = NULL;
    }
    g_n_menubar = 0;
}

static void free_tray_items(void) {
    for (int i = 0; i < g_n_tray; i++) {
        free(g_tray_items[i].label);
        g_tray_items[i].label = NULL;
    }
    g_n_tray = 0;
}

static ZTrayItem *find_in(ZTrayItem *arr, int n, int32_t id) {
    for (int i = 0; i < n; i++) {
        if (arr[i].id == id) return &arr[i];
    }
    return NULL;
}

static int append_dict_string(DBusMessageIter *dict, const char *key, const char *val) {
    DBusMessageIter entry, variant;
    if (!dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry)) return 0;
    char *k = (char *)key;
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &k)) return 0;
    if (!dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant)) return 0;
    char *v = (char *)val;
    if (!dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &v)) return 0;
    if (!dbus_message_iter_close_container(&entry, &variant)) return 0;
    if (!dbus_message_iter_close_container(dict, &entry)) return 0;
    return 1;
}

static int append_dict_bool(DBusMessageIter *dict, const char *key, dbus_bool_t val) {
    DBusMessageIter entry, variant;
    if (!dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry)) return 0;
    char *k = (char *)key;
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &k)) return 0;
    if (!dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "b", &variant)) return 0;
    if (!dbus_message_iter_append_basic(&variant, DBUS_TYPE_BOOLEAN, &val)) return 0;
    if (!dbus_message_iter_close_container(&entry, &variant)) return 0;
    if (!dbus_message_iter_close_container(dict, &entry)) return 0;
    return 1;
}

static int append_dict_shortcut(DBusMessageIter *dict, uint8_t modifiers, uint8_t key) {
    static const char *const modifier_names[] = { "Control", "Shift", "Alt", "Super" };
    const uint8_t modifier_masks[] = { (1u << 0) | (1u << 3), 1u << 1, 1u << 2, 1u << 4 };
    DBusMessageIter entry, variant, shortcuts, shortcut;
    if (!dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry)) return 0;
    char *name = "shortcut";
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &name)) return 0;
    if (!dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "aas", &variant)) return 0;
    if (!dbus_message_iter_open_container(&variant, DBUS_TYPE_ARRAY, "as", &shortcuts)) return 0;
    if (!dbus_message_iter_open_container(&shortcuts, DBUS_TYPE_ARRAY, "s", &shortcut)) return 0;
    for (int i = 0; i < 4; i++) {
        if ((modifiers & modifier_masks[i]) == 0) continue;
        char *modifier = (char *)modifier_names[i];
        if (!dbus_message_iter_append_basic(&shortcut, DBUS_TYPE_STRING, &modifier)) return 0;
    }
    char key_string[2] = { (char)key, '\0' };
    char *key_value = key_string;
    if (!dbus_message_iter_append_basic(&shortcut, DBUS_TYPE_STRING, &key_value)) return 0;
    if (!dbus_message_iter_close_container(&shortcuts, &shortcut)) return 0;
    if (!dbus_message_iter_close_container(&variant, &shortcuts)) return 0;
    if (!dbus_message_iter_close_container(&entry, &variant)) return 0;
    if (!dbus_message_iter_close_container(dict, &entry)) return 0;
    return 1;
}

static int append_properties(DBusMessageIter *dict, ZTrayItem *node) {
    const char *empty = "";
    if (node->flags & FLAG_SEPARATOR) {
        if (!append_dict_string(dict, "type", "separator")) return 0;
        if (!append_dict_string(dict, "label", empty)) return 0;
        return 1;
    }
    if (!append_dict_string(dict, "type", "standard")) return 0;
    const char *lab = node->label ? node->label : empty;
    if (!append_dict_string(dict, "label", lab)) return 0;
    dbus_bool_t en = (node->flags & FLAG_DISABLED) ? FALSE : TRUE;
    if (!append_dict_bool(dict, "enabled", en)) return 0;
    if (node->shortcut_key != 0 && !append_dict_shortcut(dict, node->shortcut_modifiers, node->shortcut_key)) return 0;
    if (node->flags & FLAG_SUBMENU) {
        if (!append_dict_string(dict, "children-display", "submenu")) return 0;
    }
    return 1;
}

static int append_layout_recursive(DBusMessageIter *arr, ZTrayItem *items, int n, int32_t node_id, int32_t depth);

static int append_one_child_variant(DBusMessageIter *arr, ZTrayItem *items, int n, int32_t child_id, int32_t depth) {
    ZTrayItem *ch = find_in(items, n, child_id);
    if (!ch) return 1;

    DBusMessageIter var, st, dict, ch_arr;
    if (!dbus_message_iter_open_container(arr, DBUS_TYPE_VARIANT, "(ia{sv}av)", &var)) return 0;
    if (!dbus_message_iter_open_container(&var, DBUS_TYPE_STRUCT, NULL, &st)) return 0;

    if (!dbus_message_iter_append_basic(&st, DBUS_TYPE_INT32, &ch->id)) return 0;

    if (!dbus_message_iter_open_container(&st, DBUS_TYPE_ARRAY, "{sv}", &dict)) return 0;
    if (!append_properties(&dict, ch)) return 0;
    if (!dbus_message_iter_close_container(&st, &dict)) return 0;

    if (!dbus_message_iter_open_container(&st, DBUS_TYPE_ARRAY, "v", &ch_arr)) return 0;
    if (depth != 0 && (ch->flags & FLAG_SUBMENU)) {
        int32_t next_depth = (depth > 0) ? (depth - 1) : depth;
        if (!append_layout_recursive(&ch_arr, items, n, ch->id, next_depth)) return 0;
    }
    if (!dbus_message_iter_close_container(&st, &ch_arr)) return 0;

    if (!dbus_message_iter_close_container(&var, &st)) return 0;
    if (!dbus_message_iter_close_container(arr, &var)) return 0;
    return 1;
}

static int append_layout_recursive(DBusMessageIter *arr, ZTrayItem *items, int n, int32_t node_id, int32_t depth) {
    for (int i = 0; i < n; i++) {
        if (items[i].parent_id != node_id) continue;
        if (!append_one_child_variant(arr, items, n, items[i].id, depth)) return 0;
    }
    return 1;
}

static DBusHandlerResult reply_introspect_menu(DBusMessage *msg) {
    static const char *const intro =
        "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
        "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
        "<node>\n"
        " <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
        "  <method name=\"Introspect\">\n"
        "   <arg name=\"data\" type=\"s\" direction=\"out\"/>\n"
        "  </method>\n"
        " </interface>\n"
        " <interface name=\"org.freedesktop.DBus.Properties\">\n"
        "  <method name=\"Get\">\n"
        "   <arg name=\"interface\" type=\"s\" direction=\"in\"/>\n"
        "   <arg name=\"property\" type=\"s\" direction=\"in\"/>\n"
        "   <arg name=\"value\" type=\"v\" direction=\"out\"/>\n"
        "  </method>\n"
        " </interface>\n"
        " <interface name=\"com.canonical.dbusmenu\">\n"
        "  <method name=\"GetLayout\">\n"
        "   <arg name=\"parentId\" type=\"i\" direction=\"in\"/>\n"
        "   <arg name=\"recursionDepth\" type=\"i\" direction=\"in\"/>\n"
        "   <arg name=\"propertyNames\" type=\"as\" direction=\"in\"/>\n"
        "   <arg name=\"revision\" type=\"u\" direction=\"out\"/>\n"
        "   <arg name=\"layout\" type=\"(ia{sv}av)\" direction=\"out\"/>\n"
        "  </method>\n"
        "  <method name=\"GetGroupProperties\">\n"
        "   <arg name=\"ids\" type=\"ai\" direction=\"in\"/>\n"
        "   <arg name=\"propertyNames\" type=\"as\" direction=\"in\"/>\n"
        "   <arg name=\"properties\" type=\"a(ia{sv})\" direction=\"out\"/>\n"
        "  </method>\n"
        "  <method name=\"Event\">\n"
        "   <arg name=\"id\" type=\"i\" direction=\"in\"/>\n"
        "   <arg name=\"eventId\" type=\"s\" direction=\"in\"/>\n"
        "   <arg name=\"data\" type=\"v\" direction=\"in\"/>\n"
        "   <arg name=\"timestamp\" type=\"u\" direction=\"in\"/>\n"
        "  </method>\n"
        "  <method name=\"AboutToShow\">\n"
        "   <arg name=\"id\" type=\"i\" direction=\"in\"/>\n"
        "  </method>\n"
        "  <signal name=\"LayoutUpdated\">\n"
        "   <arg name=\"revision\" type=\"u\"/>\n"
        "   <arg name=\"parent\" type=\"i\"/>\n"
        "  </signal>\n"
        " </interface>\n"
        "</node>\n";

    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter;
    dbus_message_iter_init_append(reply, &iter);
    char *s = (char *)intro;
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &s);
    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusHandlerResult reply_introspect_sni(DBusMessage *msg) {
    static const char *const intro =
        "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n"
        "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
        "<node>\n"
        " <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
        "  <method name=\"Introspect\"><arg name=\"data\" type=\"s\" direction=\"out\"/></method>\n"
        " </interface>\n"
        " <interface name=\"org.freedesktop.DBus.Properties\">\n"
        "  <method name=\"Get\">\n"
        "   <arg name=\"interface\" type=\"s\" direction=\"in\"/>\n"
        "   <arg name=\"property\" type=\"s\" direction=\"in\"/>\n"
        "   <arg name=\"value\" type=\"v\" direction=\"out\"/>\n"
        "  </method>\n"
        " </interface>\n"
        " <interface name=\"org.kde.StatusNotifierItem\">\n"
        "  <property name=\"Category\" type=\"s\" access=\"read\"/>\n"
        "  <property name=\"Id\" type=\"s\" access=\"read\"/>\n"
        "  <property name=\"Title\" type=\"s\" access=\"read\"/>\n"
        "  <property name=\"Status\" type=\"s\" access=\"read\"/>\n"
        "  <property name=\"IconName\" type=\"s\" access=\"read\"/>\n"
        "  <property name=\"IconPixmap\" type=\"a(iiay)\" access=\"read\"/>\n"
        "  <property name=\"ItemIsMenu\" type=\"b\" access=\"read\"/>\n"
        "  <signal name=\"NewIcon\"/>\n"
        "  <property name=\"Menu\" type=\"o\" access=\"read\"/>\n"
        " </interface>\n"
        "</node>\n";

    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter;
    dbus_message_iter_init_append(reply, &iter);
    char *s = (char *)intro;
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &s);
    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusHandlerResult reply_properties_dbusmenu_version(DBusMessage *msg) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, variant;
    dbus_uint32_t ver = 4;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "u", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &ver);
    dbus_message_iter_close_container(&iter, &variant);
    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

static int append_tray_icon_pixmap(DBusMessageIter *iter) {
    DBusMessageIter array, entry, bytes;
    if (!dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY, "(iiay)", &array)) return 0;
    if (g_tray_icon_argb == NULL) return dbus_message_iter_close_container(iter, &array);
    if (!dbus_message_iter_open_container(&array, DBUS_TYPE_STRUCT, NULL, &entry)) return 0;
    dbus_int32_t width = g_tray_icon_width;
    dbus_int32_t height = g_tray_icon_height;
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_INT32, &width)) return 0;
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_INT32, &height)) return 0;
    /* The pixels are the struct's "ay" member: a fixed array needs its own
     * array container; libdbus aborts when it is appended to the struct. */
    if (!dbus_message_iter_open_container(&entry, DBUS_TYPE_ARRAY, "y", &bytes)) return 0;
    if (!dbus_message_iter_append_fixed_array(&bytes, DBUS_TYPE_BYTE, &g_tray_icon_argb,
                                              g_tray_icon_width * g_tray_icon_height * 4)) return 0;
    if (!dbus_message_iter_close_container(&entry, &bytes)) return 0;
    if (!dbus_message_iter_close_container(&array, &entry)) return 0;
    if (!dbus_message_iter_close_container(iter, &array)) return 0;
    return 1;
}

/* StatusNotifierItem properties, as answered by Get and GetAll. */
static const char *const g_sni_properties[] = {"Category", "Id", "Title", "Status", "IconName", "IconPixmap", "ItemIsMenu", "Menu"};

static int append_variant_string(DBusMessageIter *iter, const char *value) {
    DBusMessageIter variant;
    if (!dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant)) return 0;
    if (!dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &value)) return 0;
    return dbus_message_iter_close_container(iter, &variant);
}

/* Appends the variant value of `prop` to `iter`: 1 when appended, 0 when the
 * property is unknown, -1 when the message could not be built. */
static int append_sni_property(DBusMessageIter *iter, const char *prop) {
    DBusMessageIter variant;
    if (strcmp(prop, "Category") == 0) return append_variant_string(iter, "ApplicationStatus") ? 1 : -1;
    if (strcmp(prop, "Id") == 0) return append_variant_string(iter, "ztray") ? 1 : -1;
    if (strcmp(prop, "Title") == 0) return append_variant_string(iter, g_tray_tooltip ? g_tray_tooltip : "ztray") ? 1 : -1;
    if (strcmp(prop, "Status") == 0) return append_variant_string(iter, g_tray_sni_active ? "Active" : "Passive") ? 1 : -1;
    /* Hosts prefer a non-empty IconName over IconPixmap, so the fallback
     * name applies only when there is no pixmap either. */
    if (strcmp(prop, "IconName") == 0)
        return append_variant_string(iter, g_tray_icon_name ? g_tray_icon_name : g_tray_icon_argb ? "" : "application-x-executable") ? 1 : -1;
    if (strcmp(prop, "IconPixmap") == 0) {
        if (!dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "a(iiay)", &variant)) return -1;
        if (!append_tray_icon_pixmap(&variant)) return -1;
        return dbus_message_iter_close_container(iter, &variant) ? 1 : -1;
    }
    if (strcmp(prop, "ItemIsMenu") == 0) {
        dbus_bool_t value = FALSE;
        if (!dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "b", &variant)) return -1;
        if (!dbus_message_iter_append_basic(&variant, DBUS_TYPE_BOOLEAN, &value)) return -1;
        return dbus_message_iter_close_container(iter, &variant) ? 1 : -1;
    }
    if (strcmp(prop, "Menu") == 0) {
        const char *menu_obj_path = ZTRAY_TRAY_MENU_PATH;
        if (!dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "o", &variant)) return -1;
        if (!dbus_message_iter_append_basic(&variant, DBUS_TYPE_OBJECT_PATH, &menu_obj_path)) return -1;
        return dbus_message_iter_close_container(iter, &variant) ? 1 : -1;
    }
    return 0;
}

static DBusHandlerResult reply_sni_property(DBusMessage *msg, const char *prop) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter;
    dbus_message_iter_init_append(reply, &iter);
    if (append_sni_property(&iter, prop) != 1) {
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }
    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

/* Properties.GetAll: GNOME's AppIndicator extension reads the item only this
 * way and unregisters items that do not answer it. */
static DBusHandlerResult reply_sni_all_properties(DBusMessage *msg) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, dict, entry;
    dbus_message_iter_init_append(reply, &iter);
    int ok = dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
    for (size_t i = 0; ok && i < sizeof g_sni_properties / sizeof g_sni_properties[0]; i++) {
        const char *name = g_sni_properties[i];
        ok = dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry) &&
             dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &name) &&
             append_sni_property(&entry, name) == 1 &&
             dbus_message_iter_close_container(&dict, &entry);
    }
    if (!ok || !dbus_message_iter_close_container(&iter, &dict)) {
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_NEED_MEMORY;
    }
    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

/* Properties.GetAll on a dbusmenu object: its only property is Version. */
static DBusHandlerResult reply_dbusmenu_all_properties(DBusMessage *msg) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, dict, entry, variant;
    const char *name = "Version";
    dbus_uint32_t version = 4;
    dbus_message_iter_init_append(reply, &iter);
    int ok = dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict) &&
             dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry) &&
             dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &name) &&
             dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "u", &variant) &&
             dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version) &&
             dbus_message_iter_close_container(&entry, &variant) &&
             dbus_message_iter_close_container(&dict, &entry) &&
             dbus_message_iter_close_container(&iter, &dict);
    if (!ok) {
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_NEED_MEMORY;
    }
    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusHandlerResult reply_invalid_args(DBusMessage *msg);

static DBusHandlerResult handle_properties_get_all(const char *path, DBusMessage *msg) {
    if (!dbus_message_has_signature(msg, "s")) return reply_invalid_args(msg);
    DBusMessageIter args;
    if (!dbus_message_iter_init(msg, &args)) return reply_invalid_args(msg);
    const char *iface = NULL;
    dbus_message_iter_get_basic(&args, &iface);
    if (strcmp(path, ZTRAY_SNI_PATH) == 0 && strcmp(iface, "org.kde.StatusNotifierItem") == 0)
        return reply_sni_all_properties(msg);
    if ((strcmp(path, ZTRAY_MENU_PATH) == 0 || strcmp(path, ZTRAY_TRAY_MENU_PATH) == 0) &&
        strcmp(iface, "com.canonical.dbusmenu") == 0)
        return reply_dbusmenu_all_properties(msg);
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static DBusHandlerResult reply_empty(DBusMessage *msg) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (reply) {
        dbus_connection_send(g_conn, reply, NULL);
        dbus_message_unref(reply);
    }
    return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusHandlerResult reply_invalid_args(DBusMessage *msg) {
    DBusMessage *reply = dbus_message_new_error(msg, DBUS_ERROR_INVALID_ARGS, "Invalid method arguments");
    if (reply) {
        dbus_connection_send(g_conn, reply, NULL);
        dbus_message_unref(reply);
    }
    return DBUS_HANDLER_RESULT_HANDLED;
}

/* Properties.Get: args are (interface_name, property_name) per spec */
static DBusHandlerResult handle_properties_get_v2(const char *path, DBusMessage *msg) {
    if (!dbus_message_has_signature(msg, "ss")) return reply_invalid_args(msg);
    DBusMessageIter args;
    if (!dbus_message_iter_init(msg, &args)) return reply_invalid_args(msg);
    const char *iface = NULL;
    dbus_message_iter_get_basic(&args, &iface);
    dbus_message_iter_next(&args);
    const char *prop = NULL;
    dbus_message_iter_get_basic(&args, &prop);

    if ((strcmp(path, ZTRAY_MENU_PATH) == 0 || strcmp(path, ZTRAY_TRAY_MENU_PATH) == 0) &&
        strcmp(iface, "com.canonical.dbusmenu") == 0 && strcmp(prop, "Version") == 0)
        return reply_properties_dbusmenu_version(msg);

    if (strcmp(path, ZTRAY_SNI_PATH) == 0 && strcmp(iface, "org.kde.StatusNotifierItem") == 0)
        return reply_sni_property(msg, prop);

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static int append_root_properties(DBusMessageIter *dict) {
    if (!append_dict_string(dict, "type", "standard")) return 0;
    if (!append_dict_string(dict, "label", "")) return 0;
    if (!append_dict_bool(dict, "enabled", TRUE)) return 0;
    return append_dict_string(dict, "children-display", "submenu");
}

static int append_group_entry(DBusMessageIter *array, int32_t id, ZTrayItem *node) {
    DBusMessageIter entry, dict;
    if (!dbus_message_iter_open_container(array, DBUS_TYPE_STRUCT, NULL, &entry)) return 0;
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_INT32, &id)) return 0;
    if (!dbus_message_iter_open_container(&entry, DBUS_TYPE_ARRAY, "{sv}", &dict)) return 0;
    if (!(node ? append_properties(&dict, node) : append_root_properties(&dict))) return 0;
    if (!dbus_message_iter_close_container(&entry, &dict)) return 0;
    return dbus_message_iter_close_container(array, &entry);
}

/* GetGroupProperties(ai ids, as names) -> a(ia{sv}): the properties of the
 * requested items, or of every item when ids is empty. Unknown ids are left
 * out; property names are not filtered. */
static DBusHandlerResult handle_get_group_properties(const char *path, DBusMessage *msg) {
    ZTrayItem *items = strcmp(path, ZTRAY_MENU_PATH) == 0 ? g_menubar_items : g_tray_items;
    int n = strcmp(path, ZTRAY_MENU_PATH) == 0 ? g_n_menubar : g_n_tray;
    if (!dbus_message_has_signature(msg, "aias")) return reply_invalid_args(msg);
    DBusMessageIter args, ids;
    if (!dbus_message_iter_init(msg, &args)) return reply_invalid_args(msg);
    dbus_message_iter_recurse(&args, &ids);

    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, array;
    dbus_message_iter_init_append(reply, &iter);
    int ok = dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "(ia{sv})", &array);
    if (ok && dbus_message_iter_get_arg_type(&ids) == DBUS_TYPE_INVALID) {
        ok = append_group_entry(&array, 0, NULL);
        for (int i = 0; ok && i < n; i++) ok = append_group_entry(&array, items[i].id, &items[i]);
    }
    while (ok && dbus_message_iter_get_arg_type(&ids) == DBUS_TYPE_INT32) {
        int32_t id = 0;
        dbus_message_iter_get_basic(&ids, &id);
        ZTrayItem *node = find_in(items, n, id);
        if (node || id == 0) ok = append_group_entry(&array, id, node);
        dbus_message_iter_next(&ids);
    }
    if (!ok || !dbus_message_iter_close_container(&iter, &array)) {
        dbus_message_unref(reply);
        return DBUS_HANDLER_RESULT_NEED_MEMORY;
    }
    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusHandlerResult handle_get_layout(const char *path, DBusMessage *msg) {
    ZTrayItem *items;
    int n;
    dbus_uint32_t *revision;
    if (strcmp(path, ZTRAY_MENU_PATH) == 0) {
        items = g_menubar_items;
        n = g_n_menubar;
        revision = &g_menubar_revision;
    } else {
        items = g_tray_items;
        n = g_n_tray;
        revision = &g_tray_revision;
    }

    if (!dbus_message_has_signature(msg, "iias")) return reply_invalid_args(msg);
    DBusMessageIter args;
    int32_t parent_id = 0;
    int32_t depth = -1;
    if (!dbus_message_iter_init(msg, &args)) return reply_invalid_args(msg);
    dbus_message_iter_get_basic(&args, &parent_id);
    dbus_message_iter_next(&args);
    dbus_message_iter_get_basic(&args, &depth);

    ZTrayItem *node = find_in(items, n, parent_id);
    if (!node && parent_id != 0) return reply_empty(msg);
    int32_t nid = node ? node->id : 0;

    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return DBUS_HANDLER_RESULT_HANDLED;

    /* The reply is two values, "u(ia{sv}av)": the revision and the layout.
     * Wrapping them in one struct gives "(u(ia{sv}av))", which GDBus clients
     * such as GNOME's AppIndicator extension reject. */
    DBusMessageIter iter, layout_struct, dict, av;
    dbus_message_iter_init_append(reply, &iter);
    dbus_uint32_t rev_copy = *revision;
    if (!dbus_message_iter_append_basic(&iter, DBUS_TYPE_UINT32, &rev_copy)) goto fail;

    if (!dbus_message_iter_open_container(&iter, DBUS_TYPE_STRUCT, NULL, &layout_struct)) goto fail;
    if (!dbus_message_iter_append_basic(&layout_struct, DBUS_TYPE_INT32, &nid)) goto fail;

    if (!dbus_message_iter_open_container(&layout_struct, DBUS_TYPE_ARRAY, "{sv}", &dict)) goto fail;
    if (node) {
        if (!append_properties(&dict, node)) goto fail;
    } else {
        const char *empty = "";
        if (!append_dict_string(&dict, "type", "standard")) goto fail;
        if (!append_dict_string(&dict, "label", empty)) goto fail;
        dbus_bool_t t = TRUE;
        if (!append_dict_bool(&dict, "enabled", t)) goto fail;
        if (!append_dict_string(&dict, "children-display", "submenu")) goto fail;
    }
    if (!dbus_message_iter_close_container(&layout_struct, &dict)) goto fail;

    if (!dbus_message_iter_open_container(&layout_struct, DBUS_TYPE_ARRAY, "v", &av)) goto fail;
    if (depth != 0) {
        if (!append_layout_recursive(&av, items, n, parent_id, depth)) goto fail;
    }
    if (!dbus_message_iter_close_container(&layout_struct, &av)) goto fail;
    if (!dbus_message_iter_close_container(&iter, &layout_struct)) goto fail;

    dbus_connection_send(g_conn, reply, NULL);
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
fail:
    dbus_message_unref(reply);
    return DBUS_HANDLER_RESULT_HANDLED;
}

static DBusHandlerResult handle_event(const char *path, DBusMessage *msg) {
    ZTrayItem *items;
    int n;
    atomic_int *pending;
    if (strcmp(path, ZTRAY_MENU_PATH) == 0) {
        items = g_menubar_items;
        n = g_n_menubar;
        pending = &g_pending_menubar_action;
    } else {
        items = g_tray_items;
        n = g_n_tray;
        pending = &g_pending_tray_action;
    }

    if (!dbus_message_has_signature(msg, "isvu")) return reply_invalid_args(msg);
    DBusMessageIter args;
    if (!dbus_message_iter_init(msg, &args)) return reply_invalid_args(msg);
    int32_t id = 0;
    dbus_message_iter_get_basic(&args, &id);
    dbus_message_iter_next(&args);
    const char *ev = NULL;
    dbus_message_iter_get_basic(&args, &ev);
    if (ev && strcmp(ev, "clicked") == 0) {
        ZTrayItem *it = find_in(items, n, id);
        if (it && it->action_id >= 0) atomic_store(pending, it->action_id);
    }
    return reply_empty(msg);
}

static DBusHandlerResult handle_about_to_show(DBusMessage *msg) {
    if (!dbus_message_has_signature(msg, "i")) return reply_invalid_args(msg);
    return reply_empty(msg);
}

static DBusHandlerResult handle_event_group(DBusMessage *msg) {
    if (!dbus_message_has_signature(msg, "a(isvu)")) return reply_invalid_args(msg);
    return reply_empty(msg);
}

static void emit_new_icon(void) {
    if (!g_conn) return;
    DBusMessage *sig = dbus_message_new_signal(ZTRAY_SNI_PATH, "org.kde.StatusNotifierItem", "NewIcon");
    if (!sig) return;
    dbus_connection_send(g_conn, sig, NULL);
    dbus_message_unref(sig);
}

static void emit_layout_updated(const char *path, dbus_uint32_t rev) {
    if (!g_conn) return;
    DBusMessage *sig = dbus_message_new_signal(path, "com.canonical.dbusmenu", "LayoutUpdated");
    if (!sig) return;
    DBusMessageIter iter;
    dbus_message_iter_init_append(sig, &iter);
    dbus_uint32_t r = rev;
    dbus_int32_t root = 0;
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_UINT32, &r);
    dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &root);
    dbus_connection_send(g_conn, sig, NULL);
    dbus_message_unref(sig);
}

static int register_sni_watcher(void) {
    DBusMessage *msg = dbus_message_new_method_call(
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher",
        "RegisterStatusNotifierItem");
    if (!msg) return 0;
    DBusMessageIter iter;
    dbus_message_iter_init_append(msg, &iter);
    const char *item_path = ZTRAY_SNI_PATH;
    if (!dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &item_path)) {
        dbus_message_unref(msg);
        return 0;
    }
    dbus_uint32_t serial = 0;
    dbus_bool_t sent = dbus_connection_send(g_conn, msg, &serial);
    dbus_message_unref(msg);
    if (!sent) return 0;
    dbus_connection_flush(g_conn);
    return 1;
}

static DBusHandlerResult filter_message(DBusConnection *connection, DBusMessage *message, void *user_data) {
    (void)connection;
    (void)user_data;
    if (dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_METHOD_CALL) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const char *path = dbus_message_get_path(message);
    if (!path) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    const char *iface = dbus_message_get_interface(message);
    const char *member = dbus_message_get_member(message);
    if (!iface || !member) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (strcmp(path, ZTRAY_MENU_PATH) == 0 || strcmp(path, ZTRAY_TRAY_MENU_PATH) == 0) {
        if (strcmp(iface, "org.freedesktop.DBus.Introspectable") == 0 && strcmp(member, "Introspect") == 0)
            return reply_introspect_menu(message);
        if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 && strcmp(member, "Get") == 0)
            return handle_properties_get_v2(path, message);
        if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 && strcmp(member, "GetAll") == 0)
            return handle_properties_get_all(path, message);
        if (strcmp(iface, "com.canonical.dbusmenu") == 0) {
            if (strcmp(member, "GetLayout") == 0) return handle_get_layout(path, message);
            if (strcmp(member, "GetGroupProperties") == 0) return handle_get_group_properties(path, message);
            if (strcmp(member, "Event") == 0) return handle_event(path, message);
            if (strcmp(member, "AboutToShow") == 0) return handle_about_to_show(message);
            if (strcmp(member, "EventGroup") == 0) return handle_event_group(message);
        }
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    if (strcmp(path, ZTRAY_SNI_PATH) == 0) {
        if (strcmp(iface, "org.freedesktop.DBus.Introspectable") == 0 && strcmp(member, "Introspect") == 0)
            return reply_introspect_sni(message);
        if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 && strcmp(member, "Get") == 0)
            return handle_properties_get_v2(path, message);
        if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 && strcmp(member, "GetAll") == 0)
            return handle_properties_get_all(path, message);
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

static void appmenu_registrar_query_notify(DBusPendingCall *pending, void *user_data) {
    (void)user_data;
    DBusMessage *reply = dbus_pending_call_steal_reply(pending);
    dbus_pending_call_unref(pending);
    g_appmenu_registrar_query_in_flight = 0;
    atomic_store(&g_appmenu_registrar_has_owner, -1);

    if (!reply) return;
    if (dbus_message_get_type(reply) == DBUS_MESSAGE_TYPE_METHOD_RETURN && dbus_message_has_signature(reply, "b")) {
        DBusMessageIter args;
        if (dbus_message_iter_init(reply, &args)) {
            dbus_bool_t has_owner = FALSE;
            dbus_message_iter_get_basic(&args, &has_owner);
            atomic_store(&g_appmenu_registrar_has_owner, has_owner ? 1 : 0);
        }
    }
    dbus_message_unref(reply);
}

static void query_appmenu_registrar_owner(void) {
    if (g_appmenu_registrar_query_in_flight || atomic_load(&g_appmenu_registrar_has_owner) != -1) return;
    if (ztray_linux_dbus_init() == 0) return;

    DBusMessage *msg = dbus_message_new_method_call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner");
    if (!msg) return;

    const char *registrar = "com.canonical.AppMenu.Registrar";
    if (!dbus_message_append_args(msg, DBUS_TYPE_STRING, &registrar, DBUS_TYPE_INVALID)) {
        dbus_message_unref(msg);
        return;
    }

    DBusPendingCall *pending = NULL;
    if (!dbus_connection_send_with_reply(g_conn, msg, &pending, -1)) {
        dbus_message_unref(msg);
        return;
    }
    dbus_message_unref(msg);
    if (!pending) return;
    if (!dbus_pending_call_set_notify(pending, appmenu_registrar_query_notify, NULL, NULL)) {
        dbus_pending_call_cancel(pending);
        dbus_pending_call_unref(pending);
        return;
    }
    g_appmenu_registrar_query_in_flight = 1;
    dbus_connection_flush(g_conn);
}

/* 1 = com.canonical.AppMenu.Registrar has an owner, 0 = no owner, -1 = query pending or unavailable */
static void tray_host_query_notify(DBusPendingCall *pending, void *user_data) {
    (void)user_data;
    DBusMessage *reply = dbus_pending_call_steal_reply(pending);
    dbus_pending_call_unref(pending);
    g_tray_host_query_in_flight = 0;
    atomic_store(&g_tray_host_has_owner, -1);

    if (!reply) return;
    if (dbus_message_get_type(reply) == DBUS_MESSAGE_TYPE_METHOD_RETURN && dbus_message_has_signature(reply, "b")) {
        DBusMessageIter args;
        if (dbus_message_iter_init(reply, &args)) {
            dbus_bool_t has_owner = FALSE;
            dbus_message_iter_get_basic(&args, &has_owner);
            atomic_store(&g_tray_host_has_owner, has_owner ? 1 : 0);
        }
    }
    dbus_message_unref(reply);
}

/* Asks the bus whether org.kde.StatusNotifierWatcher is owned. Desktops that
 * show StatusNotifierItems own it (KDE Plasma, Cinnamon, Budgie, waybar's tray,
 * GNOME with the AppIndicator extension); stock GNOME does not. */
static void query_tray_host_owner(void) {
    if (g_tray_host_query_in_flight || atomic_load(&g_tray_host_has_owner) != -1) return;
    if (!g_conn) return;

    DBusMessage *msg = dbus_message_new_method_call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner");
    if (!msg) return;

    const char *watcher = "org.kde.StatusNotifierWatcher";
    if (!dbus_message_append_args(msg, DBUS_TYPE_STRING, &watcher, DBUS_TYPE_INVALID)) {
        dbus_message_unref(msg);
        return;
    }

    DBusPendingCall *pending = NULL;
    if (!dbus_connection_send_with_reply(g_conn, msg, &pending, -1)) {
        dbus_message_unref(msg);
        return;
    }
    dbus_message_unref(msg);
    if (!pending) return;
    if (!dbus_pending_call_set_notify(pending, tray_host_query_notify, NULL, NULL)) {
        dbus_pending_call_cancel(pending);
        dbus_pending_call_unref(pending);
        return;
    }
    g_tray_host_query_in_flight = 1;
    dbus_connection_flush(g_conn);
}

/* 1 = a StatusNotifierWatcher shows the tray icon, 0 = none on this desktop,
 * -1 = no tray installed yet or the answer is still pending */
int ztray_linux_tray_host_state(void) {
    if (!g_tray_sni_active) return -1;
    query_tray_host_owner();
    return atomic_load(&g_tray_host_has_owner);
}

int ztray_linux_appmenu_registrar_has_owner(void) {
    query_appmenu_registrar_owner();
    return atomic_load(&g_appmenu_registrar_has_owner);
}

int ztray_linux_dbus_init(void) {
    if (g_conn) return 1;
    if (!ztray_dbus_load()) return 0;
    DBusError err;
    dbus_error_init(&err);
    g_conn = dbus_bus_get(DBUS_BUS_SESSION, &err);
    if (!g_conn) {
        dbus_error_free(&err);
        return 0;
    }
    dbus_connection_add_filter(g_conn, filter_message, NULL, NULL);
    char bus_name[64];
    snprintf(bus_name, sizeof(bus_name), "org.ztray.app%d", (int)getpid());
    dbus_uint32_t flags = DBUS_NAME_FLAG_DO_NOT_QUEUE;
    (void)dbus_bus_request_name(g_conn, bus_name, flags, NULL);
    return 1;
}

void ztray_linux_dbus_shutdown(void) {
    if (!g_conn) return;
    ztray_linux_tray_shutdown();
    dbus_connection_remove_filter(g_conn, filter_message, NULL);
    dbus_connection_unref(g_conn);
    g_conn = NULL;
    g_appmenu_registrar_query_in_flight = 0;
    atomic_store(&g_appmenu_registrar_has_owner, -1);
    g_tray_host_query_in_flight = 0;
    atomic_store(&g_tray_host_has_owner, -1);
    free_menubar_items();
    g_menubar_revision = 0;
}

typedef struct {
    int32_t id;
    int32_t parent_id;
    int32_t action_id;
    uint32_t flags;
    uint8_t shortcut_modifiers;
    uint8_t shortcut_key;
    const char *label;
} ZTrayLinuxItem;

static void free_items(ZTrayItem *items, int n) {
    for (int i = 0; i < n; i++) {
        free(items[i].label);
        items[i].label = NULL;
    }
}

static int replace_items(ZTrayItem *target, int *target_n, const ZTrayLinuxItem *items, int n) {
    if (n < 0 || n > ZTRAY_MAX_ITEMS) return 0;

    ZTrayItem replacement[ZTRAY_MAX_ITEMS] = {0};
    for (int i = 0; i < n; i++) {
        replacement[i].id = items[i].id;
        replacement[i].parent_id = items[i].parent_id;
        replacement[i].action_id = items[i].action_id;
        replacement[i].flags = items[i].flags;
        replacement[i].shortcut_modifiers = items[i].shortcut_modifiers;
        replacement[i].shortcut_key = items[i].shortcut_key;
        replacement[i].label = items[i].label ? strdup(items[i].label) : strdup("");
        if (!replacement[i].label) {
            free_items(replacement, n);
            return 0;
        }
    }

    free_items(target, *target_n);
    memcpy(target, replacement, sizeof(replacement));
    *target_n = n;
    return 1;
}

int ztray_linux_dbus_set_items(const ZTrayLinuxItem *items, int n) {
    if (!replace_items(g_menubar_items, &g_n_menubar, items, n)) return 0;
    if (g_menubar_revision == 0xFFFFFFFFu)
        g_menubar_revision = 1;
    else
        g_menubar_revision++;
    emit_layout_updated(ZTRAY_MENU_PATH, g_menubar_revision);
    return 1;
}

int ztray_linux_tray_set_items(const ZTrayLinuxItem *items, int n) {
    if (!replace_items(g_tray_items, &g_n_tray, items, n)) return 0;
    if (g_tray_revision == 0xFFFFFFFFu)
        g_tray_revision = 1;
    else
        g_tray_revision++;
    emit_layout_updated(ZTRAY_TRAY_MENU_PATH, g_tray_revision);
    return 1;
}

int ztray_linux_tray_install(const char *tooltip_utf8, const char *icon_name_or_null, const unsigned char *icon_png, int icon_png_len) {
    if (ztray_linux_dbus_init() == 0) return 0;

    unsigned char *icon_argb = NULL;
    int icon_width = 0;
    int icon_height = 0;
    if (icon_png != NULL && icon_png_len > 0 &&
        !ztray_linux_icon_pixmap_from_png(icon_png, icon_png_len, &icon_width, &icon_height, &icon_argb))
        return 0;

    free(g_tray_tooltip);
    g_tray_tooltip = tooltip_utf8 ? strdup(tooltip_utf8) : strdup("ztray");
    if (!g_tray_tooltip) {
        free(icon_argb);
        return 0;
    }

    free(g_tray_icon_name);
    if (icon_name_or_null && icon_name_or_null[0])
        g_tray_icon_name = strdup(icon_name_or_null);
    else
        g_tray_icon_name = NULL;

    free(g_tray_icon_argb);
    g_tray_icon_argb = icon_argb;
    g_tray_icon_width = icon_width;
    g_tray_icon_height = icon_height;
    g_tray_sni_active = 1;
    emit_new_icon();
    (void)register_sni_watcher();
    return 1;
}

void ztray_linux_tray_shutdown(void) {
    g_tray_sni_active = 0;
    free(g_tray_tooltip);
    g_tray_tooltip = NULL;
    free(g_tray_icon_name);
    g_tray_icon_name = NULL;
    free(g_tray_icon_argb);
    g_tray_icon_argb = NULL;
    g_tray_icon_width = 0;
    g_tray_icon_height = 0;
    free_tray_items();
    g_tray_revision = 0;
    atomic_store(&g_pending_tray_action, -1);
}

void ztray_linux_dbus_dispatch(void) {
    if (g_conn) dbus_connection_read_write_dispatch(g_conn, 0);
}

int ztray_linux_dbus_take_pending(void) {
    return atomic_exchange(&g_pending_menubar_action, -1);
}

int ztray_linux_tray_take_pending(void) {
    return atomic_exchange(&g_pending_tray_action, -1);
}
