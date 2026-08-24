#pragma once

#include <stdint.h>

typedef struct ShellyWaylandBlur ShellyWaylandBlur;

int shelly_wayland_blur_has_capability(uint32_t flags);
ShellyWaylandBlur *shelly_wayland_blur_new(void *display, void *surface);
void shelly_wayland_blur_set_region(ShellyWaylandBlur *blur, int width, int height);
void shelly_wayland_blur_clear_region(ShellyWaylandBlur *blur);
void shelly_wayland_blur_free(ShellyWaylandBlur *blur);
