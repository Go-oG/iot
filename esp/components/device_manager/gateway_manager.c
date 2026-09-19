#include "gateway_manager.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_gap_ble_api.h"
#include "esp_heap_caps.h"
#include "nvs.h"
#include "nvs_flash.h"

#define GW_SEEN_LIMIT 64

typedef struct {
    bool paused;
    unsigned failures;
    int last_error;
    int interval_status;
    uint16_t interval_units;
    int rssi;
    int64_t last_seen_ms;
    int64_t retry_ms;
    int64_t subscription_retry_ms;
    int64_t subscription_started_ms;
    int64_t rssi_due_ms;
    bool params_requested;
    bool subscription_pending;
    unsigned restored;
    struct { uint64_t received, published, dropped; } reports;
} device_runtime_t;

typedef struct {
    bool used;
    uint8_t addr[6];
    uint8_t address_type;
    int rssi;
    int64_t seen_ms;
    char name[32];
} seen_device_t;

static gw_registry_t s_registry;
static device_runtime_t *s_runtime;
static seen_device_t s_seen[GW_SEEN_LIMIT];
static SemaphoreHandle_t s_lock;
static int64_t s_next_connect_ms;
static int64_t s_next_scan_ms;
static unsigned s_connect_cursor;
static bool s_scan_requested;
static bool s_restarting;
static const char *s_load_error;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static void lock(void) { xSemaphoreTake(s_lock, portMAX_DELAY); }
static void unlock(void) { xSemaphoreGive(s_lock); }

static int index_of(const uint8_t addr[6]) {
    for (unsigned i = 0; i < s_registry.count; ++i) if (!memcmp(s_registry.devices[i].addr, addr, 6)) return (int)i;
    return -1;
}

void gw_manager_init(void) {
    s_lock = xSemaphoreCreateMutex();
    s_runtime = heap_caps_calloc(GW_DEVICE_LIMIT, sizeof(*s_runtime), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_lock || !s_runtime) abort();
    esp_err_t err = nvs_flash_init_partition("registry");
    if (err != ESP_OK) { s_load_error = "registry_partition_unavailable"; return; }
    nvs_handle_t nvs;
    err = nvs_open_from_partition("registry", "devices", NVS_READONLY, &nvs);
    if (err == ESP_ERR_NVS_NOT_FOUND) return;
    if (err != ESP_OK) { s_load_error = "registry_open_failed"; return; }
    size_t size = 0;
    err = nvs_get_str(nvs, "config", NULL, &size);
    if (err == ESP_OK && size <= GW_BACKUP_MAX_BYTES && size > 0) {
        char *text = malloc(size);
        if (text && nvs_get_str(nvs, "config", text, &size) == ESP_OK) {
            cJSON *json = cJSON_Parse(text);
            gw_registry_t *parsed = calloc(1, sizeof(*parsed));
            const char *error = "no_memory";
            if (parsed && gw_registry_parse(json, parsed, &error)) s_registry = *parsed;
            else s_load_error = error;
            free(parsed);
            cJSON_Delete(json);
        } else s_load_error = "registry_read_failed";
        free(text);
    } else if (err != ESP_ERR_NVS_NOT_FOUND) s_load_error = "invalid_saved_registry";
    nvs_close(nvs);
    for (unsigned i = 0; i < s_registry.count; ++i) {
        s_runtime[i].rssi = 127;
        s_runtime[i].retry_ms = now_ms() + i * 2000;
    }
    ESP_LOGI("manager", "Loaded %u registered devices", s_registry.count);
}

void gw_manager_pause(const uint8_t addr[6], bool pause) {
    int i = index_of(addr);
    if (i < 0) return;
    lock();
    s_runtime[i].paused = pause;
    s_runtime[i].retry_ms = 0;
    unlock();
}

void gw_manager_connection(const uint8_t addr[6], bool connected, int status) {
    int i = index_of(addr);
    if (i < 0) return;
    lock();
    device_runtime_t *r = &s_runtime[i];
    r->last_error = status;
    r->restored = 0;
    r->subscription_pending = false;
    r->params_requested = false;
    r->subscription_retry_ms = 0;
    if (connected) {
        r->failures = 0;
        r->last_seen_ms = now_ms();
        r->rssi_due_ms = 0;
    } else {
        if (r->failures < 8) ++r->failures;
        r->retry_ms = now_ms() + gw_retry_delay(r->failures - 1, (unsigned)i);
    }
    unlock();
}

void gw_manager_subscription(const uint8_t addr[6], int status) {
    int i = index_of(addr);
    if (i < 0) return;
    lock();
    device_runtime_t *r = &s_runtime[i];
    if (r->subscription_pending) {
        r->subscription_pending = false;
        r->last_error = status;
        if (status == 0) ++r->restored;
        else r->subscription_retry_ms = now_ms() + 10000;
    }
    unlock();
}

void gw_manager_rssi(const uint8_t addr[6], int rssi) {
    int i = index_of(addr);
    if (i < 0) return;
    lock();
    s_runtime[i].rssi = rssi;
    if (rssi != 127) s_runtime[i].last_seen_ms = now_ms();
    unlock();
}

void gw_manager_interval(const uint8_t addr[6], int status, uint16_t units) {
    int i = index_of(addr);
    if (i < 0) return;
    lock();
    s_runtime[i].interval_status = status;
    if (!status) s_runtime[i].interval_units = units;
    unlock();
}

void gw_manager_seen(const uint8_t addr[6], uint8_t address_type, int rssi, const uint8_t *data, size_t len) {
    int64_t now = now_ms();
    lock();
    unsigned slot = 0;
    for (unsigned i = 0; i < GW_SEEN_LIMIT; ++i) {
        if (s_seen[i].used && !memcmp(s_seen[i].addr, addr, 6)) { slot = i; break; }
        if (!s_seen[i].used || s_seen[i].seen_ms < s_seen[slot].seen_ms) slot = i;
    }
    seen_device_t *seen = &s_seen[slot];
    if (!seen->used || memcmp(seen->addr, addr, 6)) memset(seen, 0, sizeof(*seen));
    seen->used = true;
    memcpy(seen->addr, addr, 6);
    seen->address_type = address_type;
    seen->rssi = rssi;
    seen->seen_ms = now;
    gw_adv_local_name(data, len, seen->name, sizeof(seen->name));
    int i = index_of(addr);
    if (i >= 0) { s_runtime[i].rssi = rssi; s_runtime[i].last_seen_ms = now; }
    unlock();
}

bool gw_manager_report(const uint8_t addr[6], const gw_report_t *report) {
    int i = index_of(addr);
    if (i < 0) return false;
    const gw_device_t *d = &s_registry.devices[i];
    lock();
    device_runtime_t *r = &s_runtime[i];
    if (!d->enabled || r->paused || d->broadcast != report->broadcast) { unlock(); return true; }
    ++r->reports.received;
    unlock();
    bool accepted = gw_adapter_report(addr, report);
    lock();
    if (accepted) ++r->reports.published;
    else ++r->reports.dropped;
    unlock();
    return true;
}

void gw_manager_tick(void) {
    static int64_t next_tick;
    int64_t now = now_ms();
    if (now < next_tick) return;
    next_tick = now + 50;
    gw_adapter_expire();
    bool pending_link = false, want_scan = false;
    for (unsigned i = 0; i < s_registry.count; ++i) {
        const gw_device_t *d = &s_registry.devices[i];
        if (gw_adapter_protocol_owned(d->addr)) continue;
        gw_link_t link = {0};
        bool present = gw_adapter_link(d->addr, &link);
        lock();
        bool paused = s_runtime[i].paused;
        bool params = s_runtime[i].params_requested;
        bool sub_pending = s_runtime[i].subscription_pending;
        unsigned restored = s_runtime[i].restored;
        int64_t sub_due = s_runtime[i].subscription_retry_ms;
        int64_t sub_start = s_runtime[i].subscription_started_ms;
        int64_t rssi_due = s_runtime[i].rssi_due_ms;
        unlock();
        if (!d->enabled || paused || d->broadcast) {
            if (present) gw_adapter_disconnect(d->addr);
            if (d->enabled && !paused && d->broadcast) want_scan = true;
            continue;
        }
        if (present && !link.connected) {
            pending_link = true;
            if (now - link.started_ms > 15000) gw_adapter_disconnect(d->addr);
        }
        if (!present || !link.connected) continue;
        if (!params) {
            esp_ble_conn_update_params_t p = {0};
            memcpy(p.bda, d->addr, 6);
            p.min_int = d->interval_min_ms * 4 / 5;
            p.max_int = d->interval_max_ms * 4 / 5;
            p.timeout = d->interval_max_ms > 1500 ? d->interval_max_ms * 4 / 10 : 600;
            esp_err_t err = esp_ble_gap_update_conn_params(&p);
            lock(); s_runtime[i].params_requested = true; s_runtime[i].interval_status = err; unlock();
        }
        if (now >= rssi_due) {
            esp_bd_addr_t addr; memcpy(addr, d->addr, 6);
            esp_ble_gap_read_rssi(addr);
            lock(); s_runtime[i].rssi_due_ms = now + 15000 + i * 137; unlock();
        }
        if ((!link.services_ready && now - link.started_ms > 20000) || (sub_pending && now - sub_start > 10000)) {
            // 超时后关闭链路，等待断开回调后恢复，避免迟到的订阅回调匹配到新操作
            gw_adapter_disconnect(d->addr);
            continue;
        }
        if (link.services_ready && !sub_pending && restored < d->subscription_count && now >= sub_due) {
            lock();
            s_runtime[i].subscription_pending = true;
            s_runtime[i].subscription_started_ms = now;
            unlock();
            esp_err_t err = gw_adapter_subscribe(d, restored);
            if (err != ESP_OK) {
                lock();
                s_runtime[i].subscription_pending = false;
                s_runtime[i].subscription_retry_ms = now + (err == ESP_ERR_INVALID_STATE ? 500 : 10000);
                s_runtime[i].last_error = err;
                unlock();
            }
        }
    }
    lock(); bool requested = s_scan_requested; unlock();
    if (!pending_link && (requested || (want_scan && now >= s_next_scan_ms))) {
        if (gw_adapter_scan() == ESP_OK) {
            lock(); s_scan_requested = false; unlock();
            s_next_scan_ms = now + 15000;
            s_next_connect_ms = now + 6000;
        }
    }
    if (!pending_link && now >= s_next_connect_ms) {
        for (unsigned visited = 0; visited < s_registry.count; ++visited) {
            unsigned i = s_connect_cursor++ % s_registry.count;
            const gw_device_t *d = &s_registry.devices[i];
            gw_link_t link;
            lock(); bool due = !s_runtime[i].paused && now >= s_runtime[i].retry_ms; unlock();
            if (!d->enabled || d->broadcast || !due || gw_adapter_protocol_owned(d->addr) || gw_adapter_link(d->addr, &link)) continue;
            esp_err_t err = gw_adapter_connect(d->addr, d->address_type);
            if (err != ESP_OK) {
                if (err != ESP_ERR_INVALID_STATE && err != ESP_ERR_NO_MEM) gw_manager_connection(d->addr, false, err);
                else { lock(); s_runtime[i].retry_ms = now + 2000; unlock(); }
            }
            s_next_connect_ms = now + 2000;
            pending_link = err == ESP_OK;
            break;
        }
    }

}

static const char *status_text(int status) {
    switch (status) {
        case 0: return "无错误";
        case 8: return "连接超时";
        case 19: return "远端主动断开";
        case 22: return "本地主动断开";
        case 133: return "GATT 操作失败";
        case ESP_ERR_TIMEOUT: return "操作超时";
        case ESP_ERR_NOT_FOUND: return "未找到服务、特征或描述符";
        case ESP_ERR_NOT_SUPPORTED: return "设备不支持此订阅模式";
        case ESP_ERR_INVALID_STATE: return "蓝牙操作忙或尚未就绪";
        case ESP_ERR_NO_MEM: return "内存或连接名额不足";
        default: return esp_err_to_name(status);
    }
}

cJSON *gw_manager_status(void) {
    cJSON *root = gw_registry_json(&s_registry);
    if (!root) return NULL;
    cJSON_AddBoolToObject(root, "ok", true);
    if (s_load_error) cJSON_AddStringToObject(root, "loadError", s_load_error);
    cJSON *states = cJSON_AddArrayToObject(root, "states");
    int64_t now = now_ms();
    for (unsigned i = 0; i < s_registry.count; ++i) {
        const gw_device_t *d = &s_registry.devices[i];
        gw_link_t link = {0};
        bool present = gw_adapter_link(d->addr, &link);
        cJSON *o = cJSON_CreateObject();
        char addr[18]; gw_address_format(d->addr, addr);
        cJSON_AddStringToObject(o, "device", addr);
        lock();
        device_runtime_t *r = &s_runtime[i];
        const char *state = !d->enabled ? "disabled" : r->paused ? "paused" : d->broadcast ? "broadcast" :
                            link.connected ? "connected" : present ? "connecting" : "backoff";
        // 只在锁内读取计数，JSON 分配在锁外进行
        bool paused = r->paused;
        int rssi = r->rssi, error = r->last_error, interval_status = r->interval_status;
        unsigned restored = r->restored, failures = r->failures;
        uint16_t units = r->interval_units;
        uint64_t received = r->reports.received, published = r->reports.published;
        uint64_t dropped = r->reports.dropped;
        int64_t last_seen = r->last_seen_ms, retry = r->retry_ms;
        unlock();
        cJSON_AddStringToObject(o, "state", state);
        cJSON_AddBoolToObject(o, "paused", paused);
        cJSON_AddBoolToObject(o, "protocolOwned", gw_adapter_protocol_owned(d->addr));
        cJSON_AddBoolToObject(o, "servicesReady", link.services_ready);
        if (rssi != 127) cJSON_AddNumberToObject(o, "rssi", rssi);
        cJSON_AddNumberToObject(o, "lastSeenAgoMs", last_seen ? now - last_seen : -1);
        cJSON_AddNumberToObject(o, "retryInMs", !present && retry > now ? retry - now : 0);
        cJSON_AddNumberToObject(o, "failures", failures);
        cJSON_AddNumberToObject(o, "lastError", error);
        cJSON_AddStringToObject(o, "lastErrorText", status_text(error));
        cJSON_AddNumberToObject(o, "restoredSubscriptions", restored);
        cJSON_AddNumberToObject(o, "intervalStatus", interval_status);
        cJSON_AddNumberToObject(o, "actualIntervalMs", units * 1.25);
        cJSON_AddNumberToObject(o, "received", (double)received);
        cJSON_AddNumberToObject(o, "published", (double)published);
        cJSON_AddNumberToObject(o, "dropped", (double)dropped);
        cJSON_AddItemToArray(states, o);
    }
    return root;
}

static esp_err_t send_json(httpd_req_t *req, cJSON *json) {
    char *text = json ? cJSON_PrintUnformatted(json) : NULL;
    cJSON_Delete(json);
    if (!text) return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no_memory");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    esp_err_t err = httpd_resp_sendstr(req, text);
    cJSON_free(text);
    return err;
}

static esp_err_t error_json(httpd_req_t *req, const char *error) {
    httpd_resp_set_status(req, "400 Bad Request");
    cJSON *json = cJSON_CreateObject();
    cJSON_AddBoolToObject(json, "ok", false);
    cJSON_AddStringToObject(json, "error", error);
    return send_json(req, json);
}

static esp_err_t denied_json(httpd_req_t *req) {
    httpd_resp_set_status(req, "403 Forbidden");
    cJSON *json = cJSON_CreateObject();
    cJSON_AddBoolToObject(json, "ok", false);
    cJSON_AddStringToObject(json, "error", "cross_origin_denied");
    return send_json(req, json);
}

// 写操作只接受同源且声明 JSON 的请求，避免其它网页借浏览器代提交配置
bool gw_http_json_post_allowed(httpd_req_t *req) {
    char type[64] = {0}, origin[160] = {0}, host[80] = {0};
    if (httpd_req_get_hdr_value_str(req, "Content-Type", type, sizeof(type)) != ESP_OK ||
        strncasecmp(type, "application/json", strlen("application/json"))) return false;
    if (httpd_req_get_hdr_value_str(req, "Origin", origin, sizeof(origin)) != ESP_OK) return true;
    if (httpd_req_get_hdr_value_str(req, "Host", host, sizeof(host)) != ESP_OK) return false;
    // 浏览器在 Origin 中省略 http 默认端口，比较前按相同规则归一化
    size_t host_len = strlen(host);
    if (host_len > 3 && !strcmp(host + host_len - 3, ":80")) host[host_len - 3] = '\0';
    const char *scheme = strstr(origin, "://");
    return scheme && !strcasecmp(scheme + 3, host);
}

static cJSON *read_json(httpd_req_t *req, int limit) {
    if (req->content_len <= 0 || req->content_len > limit) return NULL;
    char *text = malloc((size_t)req->content_len + 1);
    if (!text) return NULL;
    int pos = 0, timeouts = 0;
    while (pos < req->content_len) {
        int n = httpd_req_recv(req, text + pos, req->content_len - pos);
        if (n == HTTPD_SOCK_ERR_TIMEOUT && ++timeouts <= 3) continue;
        if (n <= 0) { free(text); return NULL; }
        pos += n;
    }
    text[pos] = 0;
    cJSON *json = cJSON_ParseWithLengthOpts(text, (size_t)pos + 1, NULL, true);
    free(text);
    return json;
}

static esp_err_t devices_get(httpd_req_t *req) { return send_json(req, gw_manager_status()); }
static esp_err_t diagnostics_get(httpd_req_t *req) { return send_json(req, gw_adapter_diagnostics()); }

static esp_err_t backup_get(httpd_req_t *req) {
    httpd_resp_set_hdr(req, "Content-Disposition", "attachment; filename=ble-devices.json");
    return send_json(req, gw_registry_json(&s_registry));
}

static esp_err_t devices_post(httpd_req_t *req) {
    if (!gw_http_json_post_allowed(req)) return denied_json(req);
    cJSON *registry = read_json(req, GW_BACKUP_MAX_BYTES);
    if (!registry) return error_json(req, "invalid_json");
    cJSON *data = cJSON_CreateObject(), *result = NULL;
    cJSON_AddStringToObject(data, "action", "save");
    cJSON_AddItemToObject(data, "registry", registry);
    const char *error = NULL;
    int code = gw_manager_manage(data, &result, &error);
    cJSON_Delete(data);
    if (code) { cJSON_Delete(result); return error_json(req, error ? error : "save_failed"); }
    cJSON_AddBoolToObject(result, "ok", true);
    esp_err_t sent = send_json(req, result);
    gw_adapter_restart();
    return sent;
}

// MQTT 管理入口复用登记校验和 NVS，不绕过设备登记策略
int gw_manager_manage(const cJSON *data, cJSON **result, const char **error) {
    const cJSON *a = cJSON_GetObjectItemCaseSensitive(data, "action");
    if (!cJSON_IsString(a)) { *error = "missing_action"; return 1003; }
    const char *action = a->valuestring;
    if (!strcmp(action, "status")) { *result = gw_manager_status(); return *result ? 0 : 2001; }
    if (!strcmp(action, "backup")) { *result = gw_registry_json(&s_registry); return *result ? 0 : 2001; }
    if (!strcmp(action, "diagnostics")) { *result = gw_adapter_diagnostics(); return *result ? 0 : 2001; }
    if (!strcmp(action, "config.get")) return gw_adapter_config(NULL, result, error);
    const cJSON *device = cJSON_GetObjectItemCaseSensitive(data, "device");
    if (!strcmp(action, "pause") || !strcmp(action, "resume")) {
        uint8_t addr[6];
        if (!cJSON_IsString(device) || !gw_address_parse(device->valuestring, addr) || index_of(addr) < 0) {
            *error = "device_not_registered"; return 3004;
        }
        if (gw_adapter_protocol_owned(addr)) { *error = "device_controlled_by_v1_use_connect_disconnect"; return 2001; }
        gw_manager_pause(addr, !strcmp(action, "pause"));
        *result = gw_manager_status(); return *result ? 0 : 2001;
    }
    if (strcmp(action, "save") && strcmp(action, "upsert") && strcmp(action, "remove") &&
        strcmp(action, "restart") && strcmp(action, "config.set")) { *error = "unsupported_management_action"; return 1002; }
    lock();
    if (s_restarting) { unlock(); *error = "restart_pending"; return 2001; }
    s_restarting = true;
    unlock();
    int code = 0;
    if (!strcmp(action, "config.set")) {
        const cJSON *config = cJSON_GetObjectItemCaseSensitive(data, "config");
        if (!cJSON_IsObject(config)) { *error = "invalid_config"; code = 1003; }
        else code = gw_adapter_config(config, result, error);
    } else if (strcmp(action, "restart")) {
        cJSON *registry = !strcmp(action, "save") ? cJSON_Duplicate(cJSON_GetObjectItemCaseSensitive(data, "registry"), true) : gw_registry_json(&s_registry);
        cJSON *devices = cJSON_GetObjectItemCaseSensitive(registry, "devices");
        if (!registry || !cJSON_IsArray(devices)) { code = 1003; *error = "invalid_registry"; }
        if (!code && strcmp(action, "save")) {
            const cJSON *address = !strcmp(action, "upsert") ? cJSON_GetObjectItemCaseSensitive(device, "device") : device;
            uint8_t addr[6];
            if (!cJSON_IsString(address) || !gw_address_parse(address->valuestring, addr)) {
                code = 1003; *error = "invalid_device_address";
            } else {
                int index = index_of(addr);
                if (!strcmp(action, "remove") && index < 0) { code = 3004; *error = "device_not_registered"; }
                else {
                    if (index >= 0) cJSON_DeleteItemFromArray(devices, index);
                    if (!strcmp(action, "upsert")) {
                        cJSON *copy = cJSON_Duplicate(device, true);
                        if (!copy || !cJSON_AddItemToArray(devices, copy)) {
                            cJSON_Delete(copy); code = 2001; *error = "no_memory";
                        }
                    }
                }
            }
        }
        gw_registry_t *parsed = calloc(1, sizeof(*parsed));
        if (!code && (!parsed || !registry || !gw_registry_parse(registry, parsed, error))) code = 1003;
        cJSON_Delete(registry);
        if (!code) {
            cJSON *canonical = gw_registry_json(parsed);
            char *text = canonical ? cJSON_PrintUnformatted(canonical) : NULL;
            cJSON_Delete(canonical);
            if (!text) { code = 2001; *error = "no_memory"; }
            else {
                nvs_handle_t nvs;
                esp_err_t err = nvs_open_from_partition("registry", "devices", NVS_READWRITE, &nvs);
                if (err == ESP_OK) {
                    err = nvs_set_str(nvs, "config", text);
                    if (err == ESP_OK) err = nvs_commit(nvs);
                    nvs_close(nvs);
                }
                if (err != ESP_OK) { code = 2001; *error = esp_err_to_name(err); }
                cJSON_free(text);
            }
        }
        free(parsed);
    }
    if (code) { lock(); s_restarting = false; unlock(); return code; }
    if (!*result) *result = cJSON_CreateObject();
    cJSON_AddBoolToObject(*result, "restarting", true);
    return 0;
}

static esp_err_t action_post(httpd_req_t *req) {
    if (!gw_http_json_post_allowed(req)) return denied_json(req);
    cJSON *json = read_json(req, 512);
    cJSON *op = cJSON_GetObjectItemCaseSensitive(json, "op");
    cJSON *device = cJSON_GetObjectItemCaseSensitive(json, "device");
    bool ok = false;
    if (cJSON_IsString(op)) {
        if (!strcmp(op->valuestring, "scan")) { lock(); s_scan_requested = true; unlock(); ok = true; }
        else if (cJSON_IsString(device)) {
            uint8_t addr[6];
            if (gw_address_parse(device->valuestring, addr) && index_of(addr) >= 0 &&
                (!strcmp(op->valuestring, "pause") || !strcmp(op->valuestring, "resume"))) {
                if (gw_adapter_protocol_owned(addr)) {
                    cJSON_Delete(json); return error_json(req, "device_controlled_by_v1");
                }
                gw_manager_pause(addr, !strcmp(op->valuestring, "pause")); ok = true;
            }
        }
    }
    cJSON_Delete(json);
    if (!ok) return error_json(req, "invalid_action");
    json = cJSON_CreateObject(); cJSON_AddBoolToObject(json, "ok", true);
    return send_json(req, json);
}

static esp_err_t seen_get(httpd_req_t *req) {
    seen_device_t *snapshot = malloc(sizeof(s_seen));
    if (!snapshot) return error_json(req, "no_memory");
    lock(); memcpy(snapshot, s_seen, sizeof(s_seen)); unlock();
    cJSON *root = cJSON_CreateObject(), *devices = cJSON_AddArrayToObject(root, "devices");
    int64_t now = now_ms();
    for (unsigned i = 0; i < GW_SEEN_LIMIT; ++i) if (snapshot[i].used) {
        cJSON *o = cJSON_CreateObject(); char addr[18]; gw_address_format(snapshot[i].addr, addr);
        cJSON_AddStringToObject(o, "device", addr);
        cJSON_AddStringToObject(o, "name", snapshot[i].name);
        cJSON_AddNumberToObject(o, "addressType", snapshot[i].address_type);
        cJSON_AddNumberToObject(o, "rssi", snapshot[i].rssi);
        cJSON_AddNumberToObject(o, "lastSeenAgoMs", now - snapshot[i].seen_ms);
        cJSON_AddItemToArray(devices, o);
    }
    free(snapshot);
    return send_json(req, root);
}

static esp_err_t dashboard_get(httpd_req_t *req) {
    extern const char dashboard_start[] asm("_binary_dashboard_html_start");
    extern const char dashboard_end[] asm("_binary_dashboard_html_end");
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, dashboard_start, dashboard_end - dashboard_start - 1);
}

void gw_manager_http_register(httpd_handle_t server) {
    const httpd_uri_t routes[] = {
        {.uri = "/", .method = HTTP_GET, .handler = dashboard_get},
        {.uri = "/api/devices", .method = HTTP_GET, .handler = devices_get},
        {.uri = "/api/devices", .method = HTTP_POST, .handler = devices_post},
        {.uri = "/api/backup", .method = HTTP_GET, .handler = backup_get},
        {.uri = "/api/action", .method = HTTP_POST, .handler = action_post},
        {.uri = "/api/seen", .method = HTTP_GET, .handler = seen_get},
        {.uri = "/api/diagnostics", .method = HTTP_GET, .handler = diagnostics_get},
    };
    for (unsigned i = 0; i < sizeof(routes) / sizeof(routes[0]); ++i) ESP_ERROR_CHECK(httpd_register_uri_handler(server, &routes[i]));
}
