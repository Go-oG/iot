#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "device_config.h"
#include "report_buffer.h"

static cJSON *sample(void) {
    return cJSON_Parse("{\"version\":1,\"devices\":[{\"device\":\"AA:BB:CC:DD:EE:01\",\"alias\":\"温度计\",\"mode\":\"connection\",\"reportMode\":\"latest\",\"subscriptions\":[{\"service\":\"180f\",\"characteristic\":\"2a19\"}]}]}");
}

int main(void) {
    gw_registry_t registry;
    const char *error;
    cJSON *json = sample();
    assert(gw_registry_parse(json, &registry, &error));
    assert(registry.count == 1 && registry.devices[0].enabled);
    assert(!strcmp(registry.devices[0].subscriptions[0].service, "180F"));
    cJSON *roundtrip = gw_registry_json(&registry);
    gw_registry_t other;
    assert(gw_registry_parse(roundtrip, &other, &error));
    assert(!memcmp(&registry, &other, sizeof(registry)));
    cJSON_Delete(roundtrip);
    cJSON *devices = cJSON_GetObjectItemCaseSensitive(json, "devices");
    cJSON *device = cJSON_GetArrayItem(devices, 0);
    cJSON_AddItemToArray(devices, cJSON_Duplicate(device, true));
    assert(!gw_registry_parse(json, &registry, &error) && !strcmp(error, "duplicate_device"));
    cJSON_DeleteItemFromArray(devices, 1);
    cJSON_AddNumberToObject(device, "intervalMinMs", 4000);
    assert(!gw_registry_parse(json, &registry, &error));
    cJSON_AddNumberToObject(device, "intervalMaxMs", 4000);
    assert(gw_registry_parse(json, &registry, &error));
    cJSON_ReplaceItemInObjectCaseSensitive(device, "intervalMinMs", cJSON_CreateNumber(15.5));
    assert(!gw_registry_parse(json, &registry, &error));
    cJSON_DeleteItemFromObjectCaseSensitive(device, "intervalMinMs");
    cJSON_ReplaceItemInObjectCaseSensitive(device, "mode", cJSON_CreateString("broadcast"));
    assert(!gw_registry_parse(json, &registry, &error));
    cJSON_ReplaceItemInObjectCaseSensitive(device, "subscriptions", cJSON_CreateArray());
    assert(gw_registry_parse(json, &registry, &error));
    cJSON_AddStringToObject(device, "enabled", "true");
    assert(!gw_registry_parse(json, &registry, &error));
    cJSON_Delete(json);

    json = sample();
    device = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(json, "devices"), 0);
    cJSON_ReplaceItemInObjectCaseSensitive(device, "reportMode", cJSON_CreateString("all"));
    assert(!gw_registry_parse(json, &registry, &error));
    cJSON_ReplaceItemInObjectCaseSensitive(device, "reportMode", cJSON_CreateString("stream"));
    assert(gw_registry_parse(json, &registry, &error) && !registry.devices[0].latest);
    cJSON_AddStringToObject(device, "deviceId", "sensor-001");
    cJSON_AddStringToObject(device, "deviceUuid", "22c51f92-0c73-4fb4-a47d-e6a01001abcd");
    assert(gw_registry_parse(json, &registry, &error));
    roundtrip = gw_registry_json(&registry);
    assert(gw_registry_parse(roundtrip, &other, &error) && !memcmp(&registry, &other, sizeof(registry)));
    cJSON_Delete(roundtrip);
    cJSON *duplicate = cJSON_Duplicate(device, true);
    cJSON_ReplaceItemInObjectCaseSensitive(duplicate, "device", cJSON_CreateString("AA:BB:CC:DD:EE:02"));
    cJSON_AddItemToArray(cJSON_GetObjectItemCaseSensitive(json, "devices"), duplicate);
    assert(!gw_registry_parse(json, &other, &error) && !strcmp(error, "duplicate_device_id"));
    cJSON_Delete(json);

    memset(&registry, 0, sizeof(registry));
    registry.count = 32;
    for (unsigned i = 0; i < 32; ++i) {
        gw_device_t *d = &registry.devices[i];
        d->addr[5] = i;
        d->enabled = true;
        d->latest = true;
        d->interval_min_ms = 100;
        d->interval_max_ms = 200;
        d->subscription_count = 4;
        memset(d->alias, 'a', 48);
        for (unsigned j = 0; j < 4; ++j) {
            snprintf(d->subscriptions[j].service, 37, "0000180F00001000800000805F9B34FB");
            snprintf(d->subscriptions[j].characteristic, 37, "00002A%02X00001000800000805F9B34FB", j);
        }
    }
    json = gw_registry_json(&registry);
    char *text = cJSON_PrintUnformatted(json);
    assert(text && strlen(text) < GW_BACKUP_MAX_BYTES);
    assert(gw_registry_parse(json, &other, &error) && other.count == 32);
    devices = cJSON_GetObjectItemCaseSensitive(json, "devices");
    cJSON_AddItemToArray(devices, cJSON_Duplicate(cJSON_GetArrayItem(devices, 0), true));
    assert(!gw_registry_parse(json, &other, &error));
    free(text); cJSON_Delete(json);
    char nested[100] = {0};
    memset(nested, '[', 20); nested[20] = '0'; memset(nested + 21, ']', 20);
    assert(cJSON_Parse(nested) == NULL);
    uint8_t addr[6];
    assert(!gw_address_parse("AA:BB:CC:DD:EE:GG", addr));
    assert(!gw_address_parse("AA:BB:CC:DD:EE:01junk", addr));
    assert(gw_retry_delay(0, 0) == 2000 && gw_retry_delay(1, 0) == 4000);
    assert(gw_retry_delay(1000, 31) < 300000 && gw_retry_delay(1, 1) != gw_retry_delay(1, 0));

    gw_report_buffer_t q = {0};
    gw_report_t report = {.handle = 1, .len = 1, .data = {1}}, out;
    assert(gw_report_push(&q, &report, true));
    report.data[0] = 2;
    assert(gw_report_push(&q, &report, true) && q.count == 1 && q.coalesced == 1);
    report.handle = 2;
    assert(gw_report_push(&q, &report, true) && q.count == 2);
    assert(gw_report_pop(&q, 100, 1000, &out) && out.handle == 1 && out.data[0] == 2);
    assert(!gw_report_pop(&q, 1099, 1000, &out));
    assert(gw_report_pop(&q, 1100, 1000, &out) && out.handle == 2);
    memset(&q, 0, sizeof(q));
    for (unsigned i = 0; i < GW_REPORT_DEPTH; ++i) { report.data[0] = i; assert(gw_report_push(&q, &report, false)); }
    assert(!gw_report_push(&q, &report, false) && q.dropped == 1);
    for (unsigned i = 0; i < GW_REPORT_DEPTH; ++i) { assert(gw_report_pop(&q, i, 0, &out)); assert(out.data[0] == i); }
    report.len = GW_REPORT_BYTES + 1;
    assert(!gw_report_push(&q, &report, true) && q.dropped == 2);
    puts("PASS: registry validation/32-device roundtrip, retry backoff, per-handle coalescing, FIFO and overflow");
}
