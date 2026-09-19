#include "device_config.h"
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = (char)tolower((unsigned char)c);
    return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

bool gw_address_parse(const char *text, uint8_t addr[6]) {
    if (!text || strlen(text) != 17) return false;
    for (int i = 0; i < 6; ++i) {
        int hi = nibble(text[i * 3]), lo = nibble(text[i * 3 + 1]);
        if (hi < 0 || lo < 0 || (i < 5 && text[i * 3 + 2] != ':')) return false;
        addr[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

void gw_address_format(const uint8_t addr[6], char text[18]) {
    snprintf(text, 18, "%02X:%02X:%02X:%02X:%02X:%02X", addr[0], addr[1], addr[2], addr[3], addr[4], addr[5]);
}

// 提取广播数据中的完整或缩短本地名称，后面的同名段覆盖前面的
bool gw_adv_local_name(const uint8_t *data, size_t len, char *out, size_t cap) {
    if (!data || !out || cap == 0) return false;
    out[0] = '\0';
    bool found = false;
    for (size_t p = 0; p < len;) {
        size_t n = data[p];
        if (!n) { ++p; continue; }
        if (p + n + 1 > len) break;
        if ((data[p + 1] == 8 || data[p + 1] == 9) && n > 1) {
            size_t copy = n - 1 < cap - 1 ? n - 1 : cap - 1;
            memcpy(out, data + p + 2, copy);
            out[copy] = '\0';
            found = true;
        }
        p += n + 1;
    }
    return found;
}

static bool number(const cJSON *o, const char *key, int min, int max, int def, int *out) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    if (!v) { *out = def; return true; }
    if (!cJSON_IsNumber(v) || !isfinite(v->valuedouble) || v->valuedouble < min ||
        v->valuedouble > max || floor(v->valuedouble) != v->valuedouble) return false;
    *out = (int)v->valuedouble;
    return true;
}

static bool boolean(const cJSON *o, const char *key, bool def, bool *out) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    if (!v) { *out = def; return true; }
    if (!cJSON_IsBool(v)) return false;
    *out = cJSON_IsTrue(v);
    return true;
}

static const char *string(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}

static bool uuid_copy(const char *s, char out[37]) {
    if (!s) return false;
    size_t n = strlen(s);
    if (n != 4 && n != 8 && n != 32 && n != 36) return false;
    for (size_t i = 0; i < n; ++i) {
        if (n == 36 && (i == 8 || i == 13 || i == 18 || i == 23)) {
            if (s[i] != '-') return false;
        } else if (!isxdigit((unsigned char)s[i])) return false;
    }
    // 统一为无连字符的大写 UUID，便于比较重复订阅
    size_t j = 0;
    for (size_t i = 0; i < n; ++i) if (s[i] != '-') out[j++] = (char)toupper((unsigned char)s[i]);
    out[j] = 0;
    return true;
}

bool gw_registry_parse(const cJSON *json, gw_registry_t *out, const char **error) {
    memset(out, 0, sizeof(*out));
    *error = "invalid_registry";
    int version;
    if (!cJSON_IsObject(json) || !number(json, "version", 1, 1, 0, &version) || version != 1) return false;
    const cJSON *devices = cJSON_GetObjectItemCaseSensitive(json, "devices");
    if (!cJSON_IsArray(devices) || cJSON_GetArraySize(devices) > GW_DEVICE_LIMIT) {
        *error = "devices_must_be_array_up_to_32"; return false;
    }
    const cJSON *item;
    cJSON_ArrayForEach(item, devices) {
        gw_device_t *d = &out->devices[out->count];
        int v;
        const char *alias = string(item, "alias"), *mode = string(item, "mode"), *report = string(item, "reportMode");
        if (!cJSON_IsObject(item) || !gw_address_parse(string(item, "device"), d->addr)) {
            *error = "invalid_device_address"; return false;
        }
        for (unsigned i = 0; i < out->count; ++i) if (memcmp(out->devices[i].addr, d->addr, 6) == 0) {
            *error = "duplicate_device"; return false;
        }
        if (!alias || strlen(alias) > 48) { *error = "alias_max_48_bytes"; return false; }
        strcpy(d->alias, alias);
        const char *id = string(item, "deviceId"), *uuid = string(item, "deviceUuid");
        if ((cJSON_GetObjectItemCaseSensitive(item, "deviceId") && (!id || !*id || strlen(id) > 64)) ||
            (cJSON_GetObjectItemCaseSensitive(item, "deviceUuid") && (!uuid || strlen(uuid) != 36))) {
            *error = "invalid_device_identity"; return false;
        }
        if (uuid) {
            char normalized[37];
            if (!uuid_copy(uuid, normalized)) { *error = "invalid_device_uuid"; return false; }
            strcpy(d->device_uuid, uuid);
        }
        if (id) strcpy(d->device_id, id);
        else if (uuid) strcpy(d->device_id, uuid);
        // 未配置稳定身份时使用当前地址作为设备标识
        char effective_id[65];
        if (d->device_id[0]) strcpy(effective_id, d->device_id);
        else gw_address_format(d->addr, effective_id);
        for (unsigned i = 0; i < out->count; ++i) {
            char previous[65];
            if (out->devices[i].device_id[0]) strcpy(previous, out->devices[i].device_id);
            else gw_address_format(out->devices[i].addr, previous);
            if (!strcmp(effective_id, previous)) { *error = "duplicate_device_id"; return false; }
        }
        if (!number(item, "addressType", 0, 3, 0, &v)) { *error = "invalid_address_type"; return false; }
        d->address_type = (uint8_t)v;
        if (!boolean(item, "enabled", true, &d->enabled)) { *error = "invalid_enabled"; return false; }
        if (!mode || (strcmp(mode, "connection") && strcmp(mode, "broadcast"))) { *error = "invalid_mode"; return false; }
        d->broadcast = strcmp(mode, "broadcast") == 0;
        if (!report || (strcmp(report, "latest") && strcmp(report, "stream"))) { *error = "invalid_report_mode"; return false; }
        d->latest = strcmp(report, "latest") == 0;
        if (!number(item, "intervalMinMs", 15, 4000, 100, &v) || v % 5) { *error = "invalid_min_interval"; return false; }
        d->interval_min_ms = (uint16_t)v;
        if (!number(item, "intervalMaxMs", d->interval_min_ms, 4000, 200, &v) || v % 5 || v < d->interval_min_ms) {
            *error = "invalid_max_interval"; return false;
        }
        d->interval_max_ms = (uint16_t)v;
        const cJSON *subs = cJSON_GetObjectItemCaseSensitive(item, "subscriptions");
        if (!cJSON_IsArray(subs) || cJSON_GetArraySize(subs) > GW_SUBSCRIPTION_LIMIT ||
            (d->broadcast && cJSON_GetArraySize(subs))) { *error = "invalid_subscriptions"; return false; }
        const cJSON *sub;
        cJSON_ArrayForEach(sub, subs) {
            gw_subscription_t *s = &d->subscriptions[d->subscription_count];
            if (!cJSON_IsObject(sub) || !uuid_copy(string(sub, "service"), s->service) ||
                !uuid_copy(string(sub, "characteristic"), s->characteristic) ||
                !boolean(sub, "indicate", false, &s->indicate)) { *error = "invalid_subscription"; return false; }
            for (unsigned i = 0; i < d->subscription_count; ++i) if (
                !strcmp(s->service, d->subscriptions[i].service) && !strcmp(s->characteristic, d->subscriptions[i].characteristic)) {
                *error = "duplicate_subscription"; return false;
            }
            ++d->subscription_count;
        }
        ++out->count;
    }
    *error = NULL;
    return true;
}

cJSON *gw_registry_json(const gw_registry_t *registry) {
    cJSON *root = cJSON_CreateObject();
    if (!root) return NULL;
    cJSON_AddNumberToObject(root, "version", 1);
    cJSON *devices = cJSON_AddArrayToObject(root, "devices");
    for (unsigned i = 0; i < registry->count; ++i) {
        const gw_device_t *d = &registry->devices[i];
        cJSON *o = cJSON_CreateObject();
        char addr[18]; gw_address_format(d->addr, addr);
        cJSON_AddStringToObject(o, "device", addr);
        cJSON_AddStringToObject(o, "alias", d->alias);
        if (d->device_id[0]) cJSON_AddStringToObject(o, "deviceId", d->device_id);
        if (d->device_uuid[0]) cJSON_AddStringToObject(o, "deviceUuid", d->device_uuid);
        cJSON_AddNumberToObject(o, "addressType", d->address_type);
        cJSON_AddBoolToObject(o, "enabled", d->enabled);
        cJSON_AddStringToObject(o, "mode", d->broadcast ? "broadcast" : "connection");
        cJSON_AddStringToObject(o, "reportMode", d->latest ? "latest" : "stream");
        cJSON_AddNumberToObject(o, "intervalMinMs", d->interval_min_ms);
        cJSON_AddNumberToObject(o, "intervalMaxMs", d->interval_max_ms);
        cJSON *subs = cJSON_AddArrayToObject(o, "subscriptions");
        for (unsigned j = 0; j < d->subscription_count; ++j) {
            cJSON *sub = cJSON_CreateObject();
            cJSON_AddStringToObject(sub, "service", d->subscriptions[j].service);
            cJSON_AddStringToObject(sub, "characteristic", d->subscriptions[j].characteristic);
            cJSON_AddBoolToObject(sub, "indicate", d->subscriptions[j].indicate);
            cJSON_AddItemToArray(subs, sub);
        }
        cJSON_AddItemToArray(devices, o);
    }
    return root;
}

uint32_t gw_retry_delay(unsigned failures, unsigned slot) {
    unsigned shift = failures > 7 ? 7 : failures;
    uint32_t delay = 2000U << shift;
    return delay + (slot * 137U) % 1000U;
}
