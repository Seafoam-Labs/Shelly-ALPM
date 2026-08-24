#include "blur_bridge.h"

#include <gdk/wayland/gdkwayland.h>
#include <stdlib.h>
#include <string.h>

#include "ext-background-effect-v1-client-protocol.h"

#if GDK_MAJOR_VERSION < 4 || (GDK_MAJOR_VERSION == 4 && GDK_MINOR_VERSION < 18)
#error "Shelly Wayland blur requires GTK 4.18 or newer"
#endif

struct ShellyWaylandBlur {
    GdkSurface *gdk_surface;
    struct wl_display *display;
    struct wl_surface *surface;
    struct wl_compositor *compositor;
    struct wl_registry *registry;
    struct ext_background_effect_manager_v1 *manager;
    struct ext_background_effect_surface_v1 *effect;
    uint32_t capabilities;
    int region_enabled;
    int region_width;
    int region_height;
};

static void apply_region(ShellyWaylandBlur *blur);

static void on_capabilities(
    void *data,
    struct ext_background_effect_manager_v1 *manager,
    uint32_t flags
) {
    ShellyWaylandBlur *blur = data;
    (void)manager;
    blur->capabilities = flags;
    apply_region(blur);
}

static const struct ext_background_effect_manager_v1_listener manager_listener = {
    .capabilities = on_capabilities,
};

static void on_registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version
) {
    ShellyWaylandBlur *blur = data;
    if (strcmp(interface, ext_background_effect_manager_v1_interface.name) != 0)
        return;
    if (blur->manager != NULL)
        return;

    blur->manager = wl_registry_bind(
        registry,
        name,
        &ext_background_effect_manager_v1_interface,
        version < 1 ? version : 1
    );
    ext_background_effect_manager_v1_add_listener(
        blur->manager,
        &manager_listener,
        blur
    );
}

static void on_registry_global_remove(
    void *data,
    struct wl_registry *registry,
    uint32_t name
) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = on_registry_global,
    .global_remove = on_registry_global_remove,
};

static void ensure_effect(ShellyWaylandBlur *blur) {
    if (blur->effect != NULL || blur->manager == NULL)
        return;
    if (!shelly_wayland_blur_has_capability(blur->capabilities))
        return;

    blur->effect = ext_background_effect_manager_v1_get_background_effect(
        blur->manager,
        blur->surface
    );
}

static void apply_region(ShellyWaylandBlur *blur) {
    if (
        !shelly_wayland_blur_has_capability(blur->capabilities) ||
        !blur->region_enabled
    ) {
        if (blur->effect != NULL) {
            ext_background_effect_surface_v1_set_blur_region(
                blur->effect,
                NULL
            );
            gdk_wayland_surface_force_next_commit(blur->gdk_surface);
        }
        return;
    }

    ensure_effect(blur);
    if (blur->effect == NULL)
        return;

    struct wl_region *region = wl_compositor_create_region(blur->compositor);
    if (region == NULL)
        return;
    wl_region_add(region, 0, 0, blur->region_width, blur->region_height);
    ext_background_effect_surface_v1_set_blur_region(blur->effect, region);
    wl_region_destroy(region);

    gdk_wayland_surface_force_next_commit(blur->gdk_surface);
}

int shelly_wayland_blur_has_capability(uint32_t flags) {
    return (
        flags & EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR
    ) != 0;
}

ShellyWaylandBlur *shelly_wayland_blur_new(void *display_ptr, void *surface_ptr) {
    GdkDisplay *display = display_ptr;
    GdkSurface *surface = surface_ptr;
    if (!GDK_IS_WAYLAND_DISPLAY(display) || !GDK_IS_WAYLAND_SURFACE(surface))
        return NULL;
    if (!gdk_wayland_display_query_registry(
        display,
        ext_background_effect_manager_v1_interface.name
    ))
        return NULL;

    ShellyWaylandBlur *blur = calloc(1, sizeof(*blur));
    if (blur == NULL)
        return NULL;

    blur->gdk_surface = surface;
    blur->display = gdk_wayland_display_get_wl_display(display);
    blur->surface = gdk_wayland_surface_get_wl_surface(surface);
    blur->compositor = gdk_wayland_display_get_wl_compositor(display);
    if (blur->display == NULL || blur->surface == NULL || blur->compositor == NULL) {
        free(blur);
        return NULL;
    }

    blur->registry = wl_display_get_registry(blur->display);
    if (blur->registry == NULL ||
        wl_registry_add_listener(blur->registry, &registry_listener, blur) != 0) {
        shelly_wayland_blur_free(blur);
        return NULL;
    }

    return blur;
}

void shelly_wayland_blur_set_region(ShellyWaylandBlur *blur, int width, int height) {
    if (blur == NULL)
        return;
    blur->region_enabled = 1;
    blur->region_width = width;
    blur->region_height = height;
    apply_region(blur);
}

void shelly_wayland_blur_clear_region(ShellyWaylandBlur *blur) {
    if (blur == NULL)
        return;
    blur->region_enabled = 0;
    apply_region(blur);
}

void shelly_wayland_blur_free(ShellyWaylandBlur *blur) {
    if (blur == NULL)
        return;
    if (blur->effect != NULL)
        ext_background_effect_surface_v1_destroy(blur->effect);
    if (blur->manager != NULL)
        ext_background_effect_manager_v1_destroy(blur->manager);
    if (blur->registry != NULL)
        wl_registry_destroy(blur->registry);
    free(blur);
}
