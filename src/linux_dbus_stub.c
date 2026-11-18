/* Unavailable D-Bus backend for non-native Linux targets, which have no host libdbus search paths.
 * Install and update calls report failure so callers receive DBusUnavailable or TrayInstallFailed. */
#include <stdint.h>

typedef struct {
    int32_t id;
    int32_t parent_id;
    int32_t action_id;
    uint32_t flags;
    uint8_t shortcut_modifiers;
    uint8_t shortcut_key;
    const char *label;
} ZTrayLinuxItem;

int ztray_linux_appmenu_registrar_has_owner(void) { return -1; }

int ztray_linux_dbus_init(void) { return 0; }
void ztray_linux_dbus_shutdown(void) {}
int ztray_linux_dbus_set_items(const ZTrayLinuxItem *items, int n) {
    (void)items;
    (void)n;
    return 0;
}
void ztray_linux_dbus_dispatch(void) {}
int ztray_linux_dbus_take_pending(void) { return -1; }

int ztray_linux_tray_install(const char *tooltip_utf8, const char *icon_name_or_null, const unsigned char *icon_png, int icon_png_len) {
    (void)tooltip_utf8;
    (void)icon_name_or_null;
    (void)icon_png;
    (void)icon_png_len;
    return 0;
}
void ztray_linux_tray_shutdown(void) {}
int ztray_linux_tray_set_items(const ZTrayLinuxItem *items, int n) {
    (void)items;
    (void)n;
    return 0;
}
int ztray_linux_tray_take_pending(void) { return -1; }
