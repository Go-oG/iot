#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "cJSON.h"

#define GW_DEVICE_LIMIT 32
#define GW_SUBSCRIPTION_LIMIT 4
#define GW_BACKUP_MAX_BYTES 32768
#define GW_ADV_NAME_MAX 33

typedef struct {
    char service[37];
    char characteristic[37];
    bool indicate;
} gw_subscription_t;

typedef struct {
    uint8_t addr[6];
    char alias[49];
    char device_id[65];
    char device_uuid[37];
    uint8_t address_type;
    bool enabled;
    bool broadcast;
    bool latest;
    uint16_t interval_min_ms;
    uint16_t interval_max_ms;
    uint8_t subscription_count;
    gw_subscription_t subscriptions[GW_SUBSCRIPTION_LIMIT];
} gw_device_t;

typedef struct {
    uint8_t count;
    gw_device_t devices[GW_DEVICE_LIMIT];
} gw_registry_t;

bool gw_address_parse(const char *text, uint8_t addr[6]);
void gw_address_format(const uint8_t addr[6], char text[18]);
bool gw_adv_local_name(const uint8_t *data, size_t len, char *out, size_t cap);
bool gw_registry_parse(const cJSON *json, gw_registry_t *out, const char **error);
cJSON *gw_registry_json(const gw_registry_t *registry);
uint32_t gw_retry_delay(unsigned failures, unsigned slot);
