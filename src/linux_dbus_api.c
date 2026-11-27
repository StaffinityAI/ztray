/* Resolves the libdbus-1 functions declared in linux_dbus_api.h at runtime. */
#include "linux_dbus_api.h"

#include <dlfcn.h>
#include <string.h>

ZTrayDBusApi ztray_dbus;

static int g_state; /* 0 = not tried, 1 = loaded, -1 = unavailable */

int ztray_dbus_load(void) {
    if (g_state != 0) return g_state == 1;
    g_state = -1;
    /* The soname is part of the stable ABI; libdbus-1.so (unversioned) is a
     * development symlink and is deliberately not tried. */
    void *library = dlopen("libdbus-1.so.3", RTLD_NOW | RTLD_LOCAL);
    if (!library) return 0;
    ZTrayDBusApi api;
    memset(&api, 0, sizeof api);
#define ZTRAY_DBUS_RESOLVE(ret, name, params)                    \
    *(void **)(&api.name) = dlsym(library, "dbus_" #name);       \
    if (!api.name) {                                             \
        dlclose(library);                                        \
        return 0;                                                \
    }
    ZTRAY_DBUS_FUNCTIONS(ZTRAY_DBUS_RESOLVE)
#undef ZTRAY_DBUS_RESOLVE
    ztray_dbus = api;
    g_state = 1;
    return 1;
}
