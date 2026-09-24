#include "gateway_protocol.h"
#include "gateway_manager.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "mbedtls/base64.h"
#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <stdatomic.h>

#define DEVICE_COUNT 64
#define REQUEST_COUNT 64
#define CACHE_COUNT 128
#define CACHE_BYTES (256 * 1024)
#define VALUE_COUNT 192
#define VALUE_BYTES 512
#define EVENT_COUNT 128
#define MAX_STEPS 32
#define ID_BYTES 65
#define NAME_BYTES 32
#define SCAN_ADV_BYTES 31

// 隔离只用于避开迟到的回调，超时后必须放行，否则设备会被永久卡住
#define QUARANTINE_MS 5000

// 负数表示广播类目标，非负数是 WebSocket 会话号
#define ROUTE_MQTT (-1)
#define ROUTE_BROADCAST (-2)
#define ROUTE_STREAM (-3)

typedef struct {
    bool used;
    bool registered;
    uint8_t addr[6];
    uint8_t addr_type;
    char id[ID_BYTES];
    char uuid[37];
    char connection[16];
    char name[NAME_BYTES + 1];
    char advertisement[SCAN_ADV_BYTES * 2 + 1];
    int rssi;
    int64_t seen;
    bool dirty;
    bool scan_dirty;
    bool quarantine;
    int64_t quarantine_until;
} protocol_device_t;

typedef struct {
    bool used;
    int device;
    uint16_t handle;
    char service[37];
    char characteristic[37];
    char value[VALUE_BYTES * 2 + 1];
    int64_t ts;
    int64_t used_ms;
    bool valid;
    bool dirty;
    bool subscribed;
    bool latest;
} protocol_value_t;

typedef struct {
    bool used;
    bool running;
    bool pending;
    bool auto_connecting;
    int device;
    int value_index;
    int route;
    unsigned sequence;
    int64_t queued;
    int64_t started;
    int64_t deadline;
    int64_t step_deadline;
    uint16_t handle;
    char client[ID_BYTES];
    cJSON *request;
    cJSON *results;
    unsigned step;
    int first_error;
} protocol_request_t;

typedef struct {
    bool used;
    char client[ID_BYTES];
    char req_id[ID_BYTES];
    char *response;
    size_t bytes;
} protocol_cached_t;

typedef struct {
    cJSON *json;
    int route;
    bool event;
} protocol_input_t;

static char s_gateway[32];
static protocol_device_t s_devices[DEVICE_COUNT];
static protocol_value_t *s_values;
static protocol_request_t s_requests[REQUEST_COUNT];
static protocol_cached_t s_cache[CACHE_COUNT];
static unsigned s_cache_cursor, s_sequence, s_revision;
static size_t s_cache_bytes;
static QueueHandle_t s_input;
static atomic_uint s_overflow;
static atomic_uint s_unmatched;
static atomic_bool s_online;
static atomic_uint s_active;
static httpd_handle_t s_http;
static int64_t s_flush;
static unsigned s_scan_sequence;
static char s_scan_id[32];
static int64_t s_scan_until;
static portMUX_TYPE s_owner_lock = portMUX_INITIALIZER_UNLOCKED;
static uint8_t s_owned[DEVICE_COUNT][6];
static unsigned s_owned_count;
static cJSON *s_stream[EVENT_COUNT];
static unsigned s_stream_head, s_stream_count;

static int64_t monotonic_ms(void) { return esp_timer_get_time() / 1000; }
// 表满时回收最久未使用、未被订阅且没有请求正在占用的缓存项
static protocol_value_t *value_evictable(void) {
    protocol_value_t *best = NULL;
    for (unsigned i = 0; i < VALUE_COUNT; ++i) {
        protocol_value_t *v = &s_values[i];
        if (!v->used || v->subscribed) continue;
        bool busy = false;
        for (unsigned j = 0; j < REQUEST_COUNT; ++j)
            if (s_requests[j].used && s_requests[j].value_index == (int) i) {
                busy = true;
                break;
            }
        if (busy) continue;
        if (!best || v->used_ms < best->used_ms) best = v;
    }
    return best;
}

// 操作失败后释放本次新建且没有任何数据的缓存项，避免探测式请求占满特征表
static void value_release(int index) {
    if (index < 0 || index >= (int) VALUE_COUNT) return;
    protocol_value_t *v = &s_values[index];
    if (!v->used || v->subscribed || v->valid) return;
    memset(v, 0, sizeof(*v));
}

int64_t gw_protocol_timestamp(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    // 校时前返回零，避免把启动时长伪装成 Unix 时间
    return tv.tv_sec >= 1700000000 ? (int64_t) tv.tv_sec * 1000 + tv.tv_usec / 1000 : 0;
}

static const char *str(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}

static bool eq(const char *a, const char *b) { return a && b && !strcmp(a, b); }
static const cJSON *data_of(const cJSON *o) { return cJSON_GetObjectItemCaseSensitive(o, "data"); }

static int number(const cJSON *o, const char *key, int def) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsNumber(v) ? v->valueint : def;
}

static void timestamp(cJSON *o) {
    int64_t ts = gw_protocol_timestamp();
    cJSON_AddNumberToObject(o, "ts", (double) ts);
}

static void copy_field(cJSON *dst, const cJSON *src, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(src, key);
    if (v) cJSON_AddItemToObject(dst, key, cJSON_Duplicate(v, true));
}

const char *gw_protocol_error_text(int code) {
    switch (code) {
        case 0: return "ok";
        case 1001: return "invalid request";
        case 1002: return "unsupported operation";
        case 1003: return "invalid argument";
        case 2001: return "gateway busy";
        case 2002: return "queue timeout";
        case 2003: return "connection limit";
        case 3001: return "device not found";
        case 3002: return "not connected";
        case 3003: return "connect timeout";
        case 3004: return "device not registered";
        case 3101: return "disconnected";
        case 4001: return "service not found";
        case 4002: return "characteristic not found";
        case 4003: return "batch failed";
        case 4101: return "gatt read failed";
        case 4201: return "gatt write failed";
        case 4301: return "gatt subscribe failed";
        case 4901: return "gatt timeout";
        case 4999: return "skipped";
        default: return "operation failed";
    }
}

#if CONFIG_HTTPD_WS_SUPPORT
typedef struct {
    int route;
} ws_session_t;

static unsigned s_ws_sequence;

typedef struct {
    int route;
    char *text;
} ws_output_t;

static void ws_send(void *arg) {
    ws_output_t *out = arg;
    int fds[16];
    size_t count = 16;
    if (httpd_get_client_list(s_http, &count, fds) == ESP_OK) {
        for (size_t i = 0; i < count; ++i) {
            ws_session_t *session = httpd_sess_get_ctx(s_http, fds[i]);
            if (httpd_ws_get_fd_info(s_http, fds[i]) != HTTPD_WS_CLIENT_WEBSOCKET || !session ||
                (out->route >= 0 && session->route != out->route))
                continue;
            httpd_ws_frame_t frame = {
                .type = HTTPD_WS_TYPE_TEXT, .payload = (uint8_t *) out->text,
                .len = strlen(out->text)
            };
            if (httpd_ws_send_frame_async(s_http, fds[i], &frame) != ESP_OK)
                httpd_sess_trigger_close(s_http, fds[i]);
        }
    }
    free(out->text);
    free(out);
}

static bool ws_queue(int route, const char *text) {
    ws_output_t *out = calloc(1, sizeof(*out));
    if (!out) return false;
    out->route = route;
    out->text = strdup(text);
    if (!out->text || httpd_queue_work(s_http, ws_send, out) != ESP_OK) {
        free(out->text);
        free(out);
        return false;
    }
    return true;
}
#endif

static bool send_message(cJSON *message, const char *client, int route, int qos) {
    cJSON *frame = cJSON_CreateObject();
    if (!frame) return false;
    cJSON_AddNumberToObject(frame, "v", 1);
    cJSON_AddStringToObject(frame, "gatewayId", s_gateway);
    if (client && *client) cJSON_AddStringToObject(frame, "clientId", client);
    timestamp(frame);
    cJSON *messages = cJSON_AddArrayToObject(frame, "messages");
    if (!messages || !cJSON_AddItemToArray(messages, cJSON_Duplicate(message, true))) {
        cJSON_Delete(frame);
        return false;
    }
    bool sent = false;
    if (route == ROUTE_MQTT || route == ROUTE_BROADCAST) sent = gw_protocol_publish(frame, qos);
#if CONFIG_HTTPD_WS_SUPPORT
    // 流式通知先直接发送给局域网会话，MQTT 侧由可重发队列保证次序
    if (s_http && route != ROUTE_MQTT) {
        char *text = cJSON_PrintUnformatted(frame);
        if (text) {
            sent = ws_queue(route, text) || sent;
            cJSON_free(text);
        }
    }
#endif
    cJSON_Delete(frame);
    return sent;
}

cJSON *gw_protocol_response(const cJSON *req, int code) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddNumberToObject(o, "v", 1);
    cJSON_AddStringToObject(o, "type", "res");
    copy_field(o, req, "reqId");
    copy_field(o, req, "op");
    copy_field(o, req, "deviceId");
    copy_field(o, req, "service");
    copy_field(o, req, "char");
    cJSON_AddNumberToObject(o, "code", code);
    cJSON_AddStringToObject(o, "message", gw_protocol_error_text(code));
    timestamp(o);
    return o;
}

static void reply(protocol_request_t *r, cJSON *o) {
    // 完成结果先进入去重缓存，再尝试传输，断线重试也不会重复执行 BLE
    unsigned slot = s_cache_cursor++ % CACHE_COUNT;
    protocol_cached_t *cache = &s_cache[slot];
    s_cache_bytes -= cache->bytes;
    cJSON_free(cache->response);
    memset(cache, 0, sizeof(*cache));
    snprintf(cache->client, sizeof(cache->client), "%s", r->client);
    snprintf(cache->req_id, sizeof(cache->req_id), "%s", str(r->request, "reqId"));
    cache->used = true;
    cache->response = cJSON_PrintUnformatted(o);
    cache->bytes = cache->response ? strlen(cache->response) + 1 : 0;
    // 缓存同时受条目数和字节数限制，防止多个大快照耗尽 PSRAM
    for (unsigned i = 1; s_cache_bytes + cache->bytes > CACHE_BYTES && i < CACHE_COUNT; ++i) {
        protocol_cached_t *old = &s_cache[(slot + i) % CACHE_COUNT];
        s_cache_bytes -= old->bytes;
        cJSON_free(old->response);
        memset(old, 0, sizeof(*old));
    }
    if (cache->bytes > CACHE_BYTES) {
        cJSON_free(cache->response);
        cache->response = NULL;
        cache->bytes = 0;
    }
    s_cache_bytes += cache->bytes;
    send_message(o, r->client, r->route, 1);
    cJSON_Delete(o);
    cJSON_Delete(r->request);
    cJSON_Delete(r->results);
    memset(r, 0, sizeof(*r));
}

static cJSON *current(protocol_request_t *r) {
    if (eq(str(r->request, "op"), "batch"))
        return cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(data_of(r->request), "steps"), r->step);
    return r->request;
}

static bool add_read_value(cJSON *out, const cJSON *request, const char *hex) {
    const char *format = str(request, "format");
    if (!format || eq(format, "hex")) {
        return cJSON_AddStringToObject(out, "value", hex) && cJSON_AddStringToObject(out, "format", "hex");
    }
    uint8_t bytes[VALUE_BYTES + 1];
    size_t len = strlen(hex) / 2;
    if (len > VALUE_BYTES) return false;
    for (size_t i = 0; i < len; ++i) {
        unsigned value;
        if (sscanf(hex + i * 2, "%2x", &value) != 1) return false;
        bytes[i] = value;
    }
    bytes[len] = 0;
    if (eq(format, "base64")) {
        unsigned char encoded[(VALUE_BYTES + 2) / 3 * 4 + 1];
        size_t encoded_len;
        if (mbedtls_base64_encode(encoded, sizeof(encoded), &encoded_len, bytes, len)) return false;
        encoded[encoded_len] = 0;
        cJSON_AddStringToObject(out, "value", (const char *) encoded);
    } else {
        // JSON 字符串不能表达嵌入的零字节，非法 UTF-8 也不能直接转发
        for (size_t i = 0; i < len;) {
            uint32_t cp = bytes[i++];
            unsigned continuation = 0;
            uint32_t minimum = 0;
            if (!cp) return false;
            if (cp >= 0xc2 && cp <= 0xdf) {
                continuation = 1;
                minimum = 0x80;
                cp &= 0x1f;
            } else if (cp >= 0xe0 && cp <= 0xef) {
                continuation = 2;
                minimum = 0x800;
                cp &= 0x0f;
            } else if (cp >= 0xf0 && cp <= 0xf4) {
                continuation = 3;
                minimum = 0x10000;
                cp &= 7;
            } else if (cp >= 0x80) return false;
            if (i + continuation > len) return false;
            while (continuation--) {
                if ((bytes[i] & 0xc0) != 0x80) return false;
                cp = (cp << 6) | (bytes[i++] & 0x3f);
            }
            if (cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
        }
        cJSON_AddStringToObject(out, "value", (const char *) bytes);
    }
    cJSON_AddStringToObject(out, "format", format);
    return true;
}

static void complete(protocol_request_t *r, int code, int native, const char *value) {
    // 写入成功不改变缓存，失败的操作也没有数据，都不保留空缓存项
    if (code || eq(str(current(r), "op"), "write")) value_release(r->value_index);
    r->value_index = -1;
    if (!eq(str(r->request, "op"), "batch")) {
        cJSON *o = gw_protocol_response(r->request, code);
        if (value && !add_read_value(o, r->request, value)) {
            cJSON_Delete(o);
            o = gw_protocol_response(r->request, 1003);
        }
        if (native) cJSON_AddNumberToObject(cJSON_AddObjectToObject(o, "data"), "nativeCode", native);
        reply(r, o);
        return;
    }
    cJSON *step = current(r), *result = cJSON_CreateObject();
    copy_field(result, step, "id");
    if (value && !add_read_value(result, step, value)) code = 1003;
    cJSON_AddNumberToObject(result, "code", code);
    if (code) cJSON_AddStringToObject(result, "message", gw_protocol_error_text(code));
    if (native) cJSON_AddNumberToObject(cJSON_AddObjectToObject(result, "data"), "nativeCode", native);
    cJSON_AddItemToArray(r->results, result);
    if (code && !r->first_error) r->first_error = code;
    ++r->step;
    r->pending = false;
    bool stop = !cJSON_IsFalse(cJSON_GetObjectItemCaseSensitive(data_of(r->request), "stopOnError"));
    if (code && (stop || code == 4901 || code == 3101 || code == 3003)) {
        while ((step = current(r))) {
            result = cJSON_CreateObject();
            copy_field(result, step, "id");
            cJSON_AddNumberToObject(result, "code", 4999);
            cJSON_AddStringToObject(result, "message", "skipped");
            cJSON_AddItemToArray(r->results, result);
            ++r->step;
        }
    }
    if (!current(r)) {
        cJSON *o = gw_protocol_response(r->request, r->first_error ? 4003 : 0);
        cJSON_AddItemToObject(cJSON_AddObjectToObject(o, "data"), "steps", r->results);
        r->results = NULL;
        reply(r, o);
    }
}

static bool normalize_uuid(const char *in, char out[37]) {
    if (!in) return false;
    size_t n = strlen(in), j = 0;
    if (n != 4 && n != 8 && n != 32 && n != 36) return false;
    for (size_t i = 0; i < n; ++i) {
        if (n == 36 && (i == 8 || i == 13 || i == 18 || i == 23)) {
            if (in[i] != '-') return false;
        } else {
            if (!isxdigit((unsigned char)in[i])) return false;
            out[j++] = (char) tolower((unsigned char) in[i]);
        }
    }
    out[j] = 0;
    if (j == 32 && !strcmp(out + 8, "00001000800000805f9b34fb")) {
        out[8] = 0;
        j = 8;
    }
    if (j == 8 && !strncmp(out, "0000", 4)) memmove(out, out + 4, 5);
    return true;
}

static int find_device(const char *id) {
    for (int i = 0; i < DEVICE_COUNT; ++i) if (s_devices[i].used && eq(id, s_devices[i].id)) return i;
    return -1;
}

static bool device_referenced(int device) {
    for (unsigned i = 0; i < REQUEST_COUNT; ++i)
        if (s_requests[i].used && s_requests[i].device == device) return true;
    return false;
}

static void device_reset_values(int device) {
    for (unsigned i = 0; i < VALUE_COUNT; ++i)
        if (s_values[i].used && s_values[i].device == device) memset(&s_values[i], 0, sizeof(s_values[i]));
}

static int device_by_mac(const char *mac, bool create, int addr_type) {
    uint8_t addr[6];
    if (!gw_address_parse(mac, addr)) return -1;
    int free_slot = -1, evict = -1;
    for (int i = 0; i < DEVICE_COUNT; ++i) {
        if (s_devices[i].used && !memcmp(s_devices[i].addr, addr, 6)) return i;
        if (!s_devices[i].used) {
            if (free_slot < 0) free_slot = i;
            continue;
        }
        // 只有扫描发现的临时设备可以被回收，用户登记过的设备始终保留
        if (!s_devices[i].registered && !s_devices[i].quarantine && !device_referenced(i) &&
            (evict < 0 || s_devices[i].seen < s_devices[evict].seen))
            evict = i;
    }
    if (!create) return -1;
    int slot = free_slot >= 0 ? free_slot : evict;
    if (slot < 0) return -1;
    device_reset_values(slot);
    protocol_device_t *d = &s_devices[slot];
    memset(d, 0, sizeof(*d));
    d->used = true;
    memcpy(d->addr, addr, 6);
    d->addr_type = addr_type;
    gw_address_format(addr, d->id);
    strcpy(d->connection, "disconnected");
    d->rssi = 127;
    return slot;
}

static protocol_value_t *value_slot(int device, const char *svc, const char *chr, bool create) {
    protocol_value_t *empty = NULL;
    for (unsigned i = 0; i < VALUE_COUNT; ++i) {
        protocol_value_t *v = &s_values[i];
        if (v->used && v->device == device && eq(v->service, svc) && eq(v->characteristic, chr)) {
            v->used_ms = monotonic_ms();
            return v;
        }
        if (!v->used && !empty) empty = v;
    }
    if (!create || !svc || !chr) return NULL;
    protocol_value_t *v = empty ? empty : value_evictable();
    if (!v) return NULL;
    memset(v, 0, sizeof(*v));
    v->used = true;
    v->device = device;
    v->used_ms = monotonic_ms();
    snprintf(v->service, sizeof(v->service), "%s", svc);
    snprintf(v->characteristic, sizeof(v->characteristic), "%s", chr);
    return v;
}

static void own_device(int device) {
    portENTER_CRITICAL(&s_owner_lock);
    bool found = false;
    for (unsigned i = 0; i < s_owned_count; ++i) if (!memcmp(s_owned[i], s_devices[device].addr, 6)) found = true;
    if (!found && s_owned_count < DEVICE_COUNT) memcpy(s_owned[s_owned_count++], s_devices[device].addr, 6);
    portEXIT_CRITICAL(&s_owner_lock);
}

bool gw_protocol_owns(const uint8_t addr[6]) {
    bool found = false;
    portENTER_CRITICAL(&s_owner_lock);
    for (unsigned i = 0; i < s_owned_count; ++i) if (!memcmp(s_owned[i], addr, 6)) {
        found = true;
        break;
    }
    portEXIT_CRITICAL(&s_owner_lock);
    return found;
}

static cJSON *device_json(int i, bool delta) {
    protocol_device_t *d = &s_devices[i];
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "deviceId", d->id);
    if (d->uuid[0]) cJSON_AddStringToObject(o, "deviceUuid", d->uuid);
    char mac[18];
    gw_address_format(d->addr, mac);
    cJSON_AddStringToObject(o, "mac", mac);
    cJSON_AddStringToObject(o, "addrType", d->addr_type & 1 ? "random" : "public");
    if (d->name[0]) cJSON_AddStringToObject(o, "name", d->name);
    cJSON_AddStringToObject(o, "connection", d->connection);
    if (d->rssi != 127) cJSON_AddNumberToObject(o, "rssi", d->rssi);
    if (d->seen) cJSON_AddNumberToObject(o, "lastSeen", (double) d->seen);
    cJSON *services = cJSON_AddArrayToObject(o, "services");
    for (unsigned j = 0; j < VALUE_COUNT; ++j) {
        protocol_value_t *v = &s_values[j];
        if (!v->used || v->device != i || !v->valid || (delta && !v->dirty)) continue;
        cJSON *svc = NULL, *candidate;
        cJSON_ArrayForEach(candidate, services) if (eq(str(candidate, "uuid"), v->service)) {
            svc = candidate;
            break;
        }
        if (!svc) {
            svc = cJSON_CreateObject();
            cJSON_AddStringToObject(svc, "uuid", v->service);
            cJSON_AddArrayToObject(svc, "chars");
            cJSON_AddItemToArray(services, svc);
        }
        cJSON *ch = cJSON_CreateObject();
        cJSON_AddStringToObject(ch, "uuid", v->characteristic);
        cJSON_AddStringToObject(ch, "value", v->value);
        if (v->ts) cJSON_AddNumberToObject(ch, "ts", (double) v->ts);
        cJSON_AddItemToArray(cJSON_GetObjectItemCaseSensitive(svc, "chars"), ch);
    }
    return o;
}

// 扫描结果只描述发现信息，不携带连接状态，避免与状态缓存混淆
static cJSON *scan_json(int i) {
    protocol_device_t *d = &s_devices[i];
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "deviceId", d->id);
    if (d->uuid[0]) cJSON_AddStringToObject(o, "deviceUuid", d->uuid);
    char mac[18];
    gw_address_format(d->addr, mac);
    cJSON_AddStringToObject(o, "mac", mac);
    cJSON_AddStringToObject(o, "addrType", d->addr_type & 1 ? "random" : "public");
    if (d->rssi != 127) cJSON_AddNumberToObject(o, "rssi", d->rssi);
    if (d->seen) cJSON_AddNumberToObject(o, "lastSeen", (double) d->seen);
    if (d->name[0]) cJSON_AddStringToObject(o, "name", d->name);
    if (d->advertisement[0]) cJSON_AddStringToObject(o, "advertisement", d->advertisement);
    cJSON_AddBoolToObject(o, "registered", d->registered);
    return o;
}

static cJSON *state_json(bool delta) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddNumberToObject(o, "revision", s_revision);
    cJSON *devices = cJSON_AddArrayToObject(o, "devices");
    // 状态只描述用户登记过的设备，扫描发现的临时设备不进入状态缓存
    for (int i = 0; i < DEVICE_COUNT; ++i)
        if (s_devices[i].used && s_devices[i].registered && (!delta || s_devices[i].dirty))
            cJSON_AddItemToArray(devices, device_json(i, delta));
    return o;
}

static void flush_state(void) {
    bool dirty = false;
    for (int i = 0; i < DEVICE_COUNT; ++i) dirty |= s_devices[i].dirty && s_devices[i].registered;
    if (!dirty) return;
    // 一个聚合增量只增加一次版本号，避免正常聚合被客户端误判为丢包
    ++s_revision;
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "type", "event");
    cJSON_AddStringToObject(o, "op", "state");
    timestamp(o);
    cJSON_AddItemToObject(o, "data", state_json(true));
    send_message(o, NULL, ROUTE_BROADCAST, 0);
    cJSON_Delete(o);
    for (int i = 0; i < DEVICE_COUNT; ++i) s_devices[i].dirty = false;
    for (unsigned i = 0; i < VALUE_COUNT; ++i) s_values[i].dirty = false;
}

cJSON *gw_protocol_snapshot(void) {
    flush_state();
    return state_json(false);
}

static bool valid_timeout(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return !v || (cJSON_IsNumber(v) && isfinite(v->valuedouble) && v->valuedouble >= 1 &&
                  v->valuedouble <= 120000 && floor(v->valuedouble) == v->valuedouble);
}

static bool valid_bool(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return !v || cJSON_IsBool(v);
}

static bool optional_string(const cJSON *o, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return !v || cJSON_IsString(v);
}

static int validate_step(cJSON *r) {
    if (!cJSON_IsObject(r)) return 1001;
    const char *op = str(r, "op");
    const cJSON *data = data_of(r);
    if (!op || (data && !cJSON_IsObject(data)) || !valid_timeout(r, "timeout") || !valid_timeout(r, "queueTimeout"))
        return 1003;
    if (!valid_bool(data, "autoConnect") || !valid_bool(data, "enabled") || !optional_string(r, "format") ||
        !optional_string(data, "writeType") || !optional_string(data, "mode") || !optional_string(data, "delivery") ||
        !optional_string(data, "policy"))
        return 1003;
    if (eq(op, "read") || eq(op, "write") || eq(op, "subscribe")) {
        char uuid[37];
        if (!normalize_uuid(str(r, "service"), uuid)) return 1003;
        cJSON_ReplaceItemInObjectCaseSensitive(r, "service", cJSON_CreateString(uuid));
        if (!normalize_uuid(str(r, "char"), uuid)) return 1003;
        cJSON_ReplaceItemInObjectCaseSensitive(r, "char", cJSON_CreateString(uuid));
        const char *format = str(r, "format");
        if (format && !eq(format, "hex") && !eq(format, "base64") && !eq(format, "utf8")) return 1003;
        if (eq(op, "write")) {
            const char *value = str(r, "value");
            const char *wt = str(data, "writeType");
            if (!value || (wt && !eq(wt, "withResponse") && !eq(wt, "withoutResponse"))) return 1003;
            uint8_t bytes[VALUE_BYTES];
            size_t len = 0;
            if (!format || eq(format, "hex")) {
                len = strlen(value);
                if ((len & 1) || len > VALUE_BYTES * 2) return 1003;
                for (size_t i = 0; i < len; ++i) if (!isxdigit((unsigned char)value[i])) return 1003;
                return 0;
            }
            if (eq(format, "utf8")) {
                len = strlen(value);
                if (len > sizeof(bytes)) return 1003;
                memcpy(bytes, value, len);
            } else if (mbedtls_base64_decode(bytes, sizeof(bytes), &len, (const unsigned char *) value, strlen(value)))
                return 1003;
            char hex[VALUE_BYTES * 2 + 1];
            for (size_t i = 0; i < len; ++i) snprintf(hex + i * 2, 3, "%02X", bytes[i]);
            hex[len * 2] = 0;
            cJSON_ReplaceItemInObjectCaseSensitive(r, "value", cJSON_CreateString(hex));
            cJSON_ReplaceItemInObjectCaseSensitive(r, "format", cJSON_CreateString("hex"));
        }
        if (eq(op, "subscribe")) {
            const char *mode = str(data, "mode"), *delivery = str(data, "delivery");
            if ((mode && !eq(mode, "auto") && !eq(mode, "notify") && !eq(mode, "indicate")) ||
                (delivery && !eq(delivery, "latest") && !eq(delivery, "stream")))
                return 1003;
        }
        return 0;
    }
    // 连接类操作也允许作为 batch 步骤，实现“连接→订阅→读写”的一次下发
    if (eq(op, "connect") || eq(op, "disconnect")) {
        const char *policy = str(data, "policy");
        return (!policy || eq(policy, "queue") || eq(policy, "reject")) && valid_timeout(data, "queueTimeout")
                   ? 0
                   : 1003;
    }
    return 1002;
}

static void accept_message(const cJSON *source, const char *client, int route) {
    const char *id = str(source, "reqId");
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(source, "v");
    if (!cJSON_IsObject(source) || !cJSON_IsNumber(version) || version->valuedouble != 1 ||
        !eq(str(source, "type"), "req") || !id || !*id || strlen(id) >= ID_BYTES) {
        cJSON *o = gw_protocol_response(source, 1001);
        send_message(o, client, route, 1);
        cJSON_Delete(o);
        return;
    }
    for (unsigned i = 0; i < CACHE_COUNT; ++i)
        if (s_cache[i].used && eq(client, s_cache[i].client) && eq(id, s_cache[i].req_id)) {
            cJSON *cached = s_cache[i].response ? cJSON_Parse(s_cache[i].response) : gw_protocol_response(source, 2001);
            send_message(cached, client, route, 1);
            cJSON_Delete(cached);
            return;
        }
    for (unsigned i = 0; i < REQUEST_COUNT; ++i)
        if (s_requests[i].used && eq(client, s_requests[i].client) && eq(id, str(s_requests[i].request, "reqId"))) {
            // 同一客户端重连时将最终响应路由到最近一次请求来源
            s_requests[i].route = route;
            return;
        }
    protocol_request_t *r = NULL;
    for (unsigned i = 0; i < REQUEST_COUNT; ++i) if (!s_requests[i].used) {
        r = &s_requests[i];
        break;
    }
    if (!r) {
        cJSON *o = gw_protocol_response(source, 2001);
        send_message(o, client, route, 1);
        cJSON_Delete(o);
        return;
    }
    r->request = cJSON_Duplicate(source, true);
    if (!r->request) return;
    r->used = true;
    r->route = route;
    r->device = -1;
    r->value_index = -1;
    r->sequence = ++s_sequence;
    r->queued = monotonic_ms();
    snprintf(r->client, sizeof(r->client), "%s", client);
    const char *op = str(r->request, "op");
    const cJSON *data = data_of(r->request);
    if (!op || (data && !cJSON_IsObject(data)) || !valid_timeout(r->request, "timeout") || !valid_timeout(
            r->request, "queueTimeout")) {
        reply(r, gw_protocol_response(r->request, 1003));
        return;
    }
    if (eq(op, "manage")) {
        cJSON *result = NULL;
        const char *error = NULL;
        int code = gw_manager_manage(data, &result, &error);
        bool restart = !code && cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(result, "restarting"));
        cJSON *o = gw_protocol_response(r->request, code);
        if (error) cJSON_ReplaceItemInObjectCaseSensitive(o, "message", cJSON_CreateString(error));
        if (result) {
            if (eq(str(data, "action"), "status")) cJSON_AddNumberToObject(result, "maxFrameBytes", GW_V1_MAX_FRAME);
            cJSON_AddItemToObject(o, "data", result);
        }
        reply(r, o);
        // 先经原路返回响应并加入去重缓存，再延迟重启
        if (restart) gw_adapter_restart();
        return;
    }
    if (eq(op, "snapshot")) {
        flush_state();
        cJSON *o = gw_protocol_response(r->request, 0);
        cJSON_AddItemToObject(o, "data", state_json(false));
        reply(r, o);
        return;
    }
    if (eq(op, "scan")) {
        const char *action = str(data, "action");
        if ((!eq(action, "start") && !eq(action, "stop")) || !valid_timeout(data, "duration") || !valid_bool(
                data, "active")) {
            reply(r, gw_protocol_response(r->request, 1003));
            return;
        }
        uint8_t addr[6] = {0};
        bool pending = false;
        uint16_t handle = 0;
        int native = 0;
        int code = gw_protocol_ble_start(r->request, addr, 0, &handle, &pending, &native);
        cJSON *o = gw_protocol_response(r->request, code);
        if (!code) {
            for (int i = 0; i < DEVICE_COUNT; ++i) s_devices[i].scan_dirty = false;
            if (eq(action, "start")) {
                snprintf(s_scan_id, sizeof(s_scan_id), "s-%u", ++s_scan_sequence);
                s_scan_until = monotonic_ms() + number(data, "duration", 5000);
            } else {
                // 保留一个聚合窗口，让停止前最后发现的结果仍然发送出去
                s_scan_until = monotonic_ms();
            }
            cJSON_AddStringToObject(cJSON_AddObjectToObject(o, "data"), "scanId", s_scan_id);
        }
        reply(r, o);
        return;
    }
    int code = 0;
    if (eq(op, "batch")) {
        cJSON *steps = cJSON_GetObjectItemCaseSensitive(data, "steps"), *step;
        if (!cJSON_IsArray(steps) || !cJSON_GetArraySize(steps) || cJSON_GetArraySize(steps) > MAX_STEPS ||
            !valid_bool(data, "stopOnError") || !valid_bool(data, "autoConnect"))
            code = 1003;
        else
            cJSON_ArrayForEach(step, steps) {
                code = validate_step(step);
                if (code) break;
            }
        r->results = cJSON_CreateArray();
        if (!r->results) code = 2001;
    } else code = validate_step(r->request);
    if (code) {
        reply(r, gw_protocol_response(r->request, code));
        return;
    }
    if (!optional_string(r->request, "mac") || !optional_string(data, "mac") ||
        !optional_string(r->request, "addrType") || !optional_string(data, "addrType") ||
        !optional_string(data, "deviceUuid")) {
        reply(r, gw_protocol_response(r->request, 1003));
        return;
    }
    const char *device_uuid = str(data, "deviceUuid");
    if (device_uuid) {
        char uuid[37];
        if (strlen(device_uuid) != 36 || !normalize_uuid(device_uuid, uuid)) {
            reply(r, gw_protocol_response(r->request, 1003));
            return;
        }
    }
    const char *device_id = str(r->request, "deviceId");
    if (!device_id || !*device_id || strlen(device_id) >= ID_BYTES) {
        reply(r, gw_protocol_response(r->request, 1003));
        return;
    }
    int device = find_device(device_id);
    if (device < 0) {
        reply(r, gw_protocol_response(r->request, 3001));
        return;
    }
    // 只有用户在网关登记过的设备才允许连接和操作，扫描发现的设备仅供展示
    if (!s_devices[device].registered) {
        reply(r, gw_protocol_response(r->request, 3004));
        return;
    }
    const char *mac = str(data, "mac");
    if (!mac) mac = str(r->request, "mac");
    const char *addr_type = str(data, "addrType");
    if (!addr_type) addr_type = str(r->request, "addrType");
    if (addr_type && !eq(addr_type, "public") && !eq(addr_type, "random")) {
        reply(r, gw_protocol_response(r->request, 1003));
        return;
    }
    if (mac) {
        uint8_t addr[6];
        if (!gw_address_parse(mac, addr) || memcmp(addr, s_devices[device].addr, 6)) {
            reply(r, gw_protocol_response(r->request, 1003));
            return;
        }
    }
    if (addr_type) s_devices[device].addr_type = eq(addr_type, "random");
    if (device_uuid) {
        if (s_devices[device].uuid[0] && !eq(s_devices[device].uuid, device_uuid)) {
            reply(r, gw_protocol_response(r->request, 1003));
            return;
        }
        snprintf(s_devices[device].uuid, sizeof(s_devices[device].uuid), "%s", device_uuid);
    }
    r->device = device;
    own_device(device);
}

static void accept_frame(cJSON *frame, int route) {
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(frame, "v");
    const char *client = str(frame, "clientId");
    cJSON *messages = cJSON_GetObjectItemCaseSensitive(frame, "messages");
    if (!cJSON_IsObject(frame) || !cJSON_IsNumber(version) || version->valuedouble != 1 ||
        !eq(str(frame, "gatewayId"), s_gateway) || !client || !*client || strlen(client) >= ID_BYTES ||
        !cJSON_IsArray(messages) || cJSON_GetArraySize(messages) > REQUEST_COUNT) {
        cJSON *o = gw_protocol_response(NULL, 1001);
        send_message(o, NULL, route, 1);
        cJSON_Delete(o);
        return;
    }
    cJSON *message;
    cJSON_ArrayForEach(message, messages) accept_message(message, client, route);
}

static void update_value(protocol_value_t *v, const char *value) {
    if (!v || !value || strlen(value) > VALUE_BYTES * 2) return;
    strcpy(v->value, value);
    v->ts = gw_protocol_timestamp();
    v->valid = true;
    v->dirty = true;
    s_devices[v->device].seen = v->ts;
    s_devices[v->device].dirty = true;
}

static void process_event(cJSON *event) {
    const char *type = str(event, "type"), *mac = str(event, "device");
    int device = device_by_mac(mac, eq(type, "ble.scan") || eq(type, "ble.connection"),
                               number(event, "addressType", 0));
    if (device < 0) return;
    protocol_device_t *d = &s_devices[device];
    int native = number(event, "status", 0);
    if (eq(type, "ble.subscribe_result") && str(event, "service") && !native) {
        char service[37], characteristic[37];
        if (normalize_uuid(str(event, "service"), service) && normalize_uuid(str(event, "char"), characteristic)) {
            protocol_value_t *v = value_slot(device, service, characteristic, true);
            if (v) {
                v->handle = number(event, "handle", 0);
                v->subscribed = true;
                v->latest = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(event, "latest"));
            }
        }
        return;
    }
    if (eq(type, "ble.rssi")) {
        d->rssi = number(event, "rssi", 127);
        d->seen = gw_protocol_timestamp();
        d->dirty = true;
        return;
    }
    if (eq(type, "ble.scan")) {
        d->rssi = number(event, "rssi", 127);
        d->seen = gw_protocol_timestamp();
        d->addr_type = number(event, "addressType", d->addr_type);
        const char *name = str(event, "name"), *advertisement = str(event, "advertisement");
        if (name) snprintf(d->name, sizeof(d->name), "%s", name);
        if (advertisement && strlen(advertisement) <= SCAN_ADV_BYTES * 2)
            snprintf(d->advertisement, sizeof(d->advertisement), "%s", advertisement);
        // 扫描只更新扫描结果，不进入状态增量，避免扫描期间污染客户端缓存
        d->scan_dirty = s_scan_until > 0;
        return;
    }
    if (eq(type, "ble.connection")) {
        bool connected = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(event, "connected"));
        strcpy(d->connection, connected ? "connected" : "disconnected");
        d->dirty = true;
        d->seen = gw_protocol_timestamp();
        if (!connected) {
            d->quarantine = false;
            d->quarantine_until = 0;
            for (unsigned i = 0; i < VALUE_COUNT; ++i)
                if (s_values[i].used && s_values[i].device == device) {
                    s_values[i].handle = 0;
                    s_values[i].subscribed = false;
                }
        }
        cJSON *o = cJSON_CreateObject();
        cJSON_AddStringToObject(o, "type", "event");
        cJSON_AddStringToObject(o, "op", "connection");
        cJSON_AddStringToObject(o, "deviceId", d->id);
        timestamp(o);
        cJSON *data = cJSON_AddObjectToObject(o, "data");
        cJSON_AddStringToObject(data, "state", d->connection);
        copy_field(data, event, "mtu");
        copy_field(data, event, "reason");
        if (!connected && (native || number(event, "reason", 0))) {
            cJSON_AddNumberToObject(o, "code", 3101);
            cJSON_AddStringToObject(o, "message", "disconnected");
        }
        send_message(o, NULL, ROUTE_BROADCAST, 1);
        cJSON_Delete(o);
    }
    if (eq(type, "ble.notify")) {
        const char *value = str(event, "data");
        if (!value || strlen(value) > VALUE_BYTES * 2) {
            atomic_fetch_add(&s_overflow, 1);
            return;
        }
        uint16_t handle = number(event, "handle", 0);
        bool matched = false;
        for (unsigned i = 0; i < VALUE_COUNT; ++i) {
            protocol_value_t *v = &s_values[i];
            if (!v->used || v->device != device || v->handle != handle) continue;
            matched = true;
            update_value(v, str(event, "data"));
            if (v->subscribed && !v->latest) {
                cJSON *o = cJSON_CreateObject();
                cJSON_AddStringToObject(o, "type", "event");
                cJSON_AddStringToObject(o, "op", "notify");
                cJSON_AddStringToObject(o, "deviceId", d->id);
                cJSON_AddStringToObject(o, "service", v->service);
                cJSON_AddStringToObject(o, "char", v->characteristic);
                cJSON_AddStringToObject(o, "value", v->value);
                cJSON_AddStringToObject(o, "format", "hex");
                timestamp(o);
                send_message(o, NULL, ROUTE_STREAM, 1);
                if (s_stream_count < EVENT_COUNT) {
                    s_stream[(s_stream_head + s_stream_count++) % EVENT_COUNT] = o;
                } else {
                    cJSON_Delete(o);
                    atomic_fetch_add(&s_overflow, 1);
                    d->quarantine = true;
                    gw_adapter_disconnect(d->addr);
                }
            }
        }
        // 句柄变化或未订阅导致无法归属的通知要计数，便于排查通知丢失
        if (!matched)
            atomic_fetch_add(&s_unmatched, 1);
        return;
    }
    for (unsigned i = 0; i < REQUEST_COUNT; ++i) {
        protocol_request_t *r = &s_requests[i];
        if (!r->used || !r->pending || r->device != device) continue;
        const cJSON *step = current(r);
        const char *op = r->auto_connecting ? "connect" : str(step, "op");
        bool disconnected = eq(type, "ble.connection") && !eq(d->connection, "connected");
        bool connecting = eq(op, "connect");
        int code = native
                       ? (eq(op, "read")
                              ? 4101
                              : eq(op, "write")
                                    ? 4201
                                    : eq(op, "subscribe")
                                          ? 4301
                                          : connecting
                                                ? 3003
                                                : 3101)
                       : 0;
        bool matched = (eq(op, "connect") && eq(type, "ble.services_ready")) ||
                       (eq(op, "disconnect") && disconnected) ||
                       (eq(op, "read") && eq(type, "ble.read_result")) ||
                       (eq(op, "write") && eq(type, "ble.write_result")) ||
                       (eq(op, "subscribe") && (eq(type, "ble.subscribe_result") ||
                                                eq(type, "ble.unsubscribe_result")));
        // 连接建立失败属于连接错误，不应报成“已断开”
        if (disconnected && !eq(op, "disconnect")) {
            matched = true;
            code = connecting ? 3003 : 3101;
        }
        if (!matched) continue;
        if (!disconnected && !eq(op, "connect") && number(event, "handle", 0) != r->handle) continue;
        if (r->auto_connecting) {
            r->auto_connecting = false;
            r->pending = false;
            if (code) complete(r, code, native, NULL);
            continue;
        }
        protocol_value_t *v = value_slot(device, str(step, "service"), str(step, "char"), false);
        if (!code && eq(op, "read")) update_value(v, str(event, "data") ? str(event, "data") : "");
        if (!code && eq(op, "subscribe") && v) {
            v->subscribed = !cJSON_IsFalse(cJSON_GetObjectItemCaseSensitive(data_of(step), "enabled"));
            v->latest = eq(str(data_of(step), "delivery"), "latest");
        }
        complete(r, code, native, !code && eq(op, "read") ? (str(event, "data") ? str(event, "data") : "") : NULL);
    }
}

static void schedule(void) {
    int64_t now = monotonic_ms();
    unsigned active = gw_protocol_managed_gatt_count();
    for (unsigned i = 0; i < REQUEST_COUNT; ++i) if (s_requests[i].used && s_requests[i].pending) ++active;
    for (unsigned i = 0; i < REQUEST_COUNT; ++i) {
        protocol_request_t *r = &s_requests[i];
        if (!r->used || r->device < 0) continue;
        protocol_device_t *d = &s_devices[r->device];
        const char *op = str(current(r), "op");
        if (r->running && (now >= r->deadline || (r->pending && now >= r->step_deadline))) {
            bool connecting = r->auto_connecting || eq(op, "connect");
            if (r->pending) {
                d->quarantine = true;
                d->quarantine_until = now + QUARANTINE_MS;
                gw_adapter_disconnect(d->addr);
                if (active) --active;
            }
            complete(r, connecting ? 3003 : 4901, 0, NULL);
            continue;
        }
        // 断开事件丢失时隔离标记会一直阻止该设备，因此到期后无条件放行
        if (d->quarantine && now >= d->quarantine_until) {
            d->quarantine = false;
            d->quarantine_until = 0;
            gw_adapter_disconnect(d->addr);
        }
        if (r->pending) continue;
        if (!r->running) {
            int timeout = number(r->request, "queueTimeout", number(data_of(r->request), "queueTimeout", 10000));
            if (now - r->queued >= timeout) {
                reply(r, gw_protocol_response(r->request, 2002));
                continue;
            }
            bool earlier = false;
            for (unsigned j = 0; j < REQUEST_COUNT; ++j)
                if (s_requests[j].used && s_requests[j].device == r->device && s_requests[j].sequence < r->sequence)
                    earlier = true;
            if (earlier) continue;
        }
        if (d->quarantine || active >= GW_V1_MAX_GATT_OPS) continue;
        cJSON *step = current(r);
        gw_link_t link = {0};
        bool linked = gw_adapter_link(d->addr, &link);
        bool auto_connect = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(data_of(r->request), "autoConnect"));
        bool connect = eq(op, "connect") || (auto_connect && !link.connected);
        if (connect && linked && link.connected && link.services_ready) {
            complete(r, 0, 0, NULL);
            continue;
        }
        if (connect && linked) continue;
        if (!connect && !eq(op, "disconnect") && (!link.connected || !link.services_ready)) {
            complete(r, 3002, 0, NULL);
            continue;
        }
        if (eq(op, "disconnect") && !linked) {
            complete(r, 0, 0, NULL);
            continue;
        }
        protocol_value_t *v = NULL;
        if (!connect && (eq(op, "read") || eq(op, "write") || eq(op, "subscribe"))) {
            v = value_slot(r->device, str(step, "service"), str(step, "char"), true);
            if (!v) {
                complete(r, 2001, 0, NULL);
                continue;
            }
            r->value_index = (int) (v - s_values);
        } else r->value_index = -1;
        cJSON *auto_req = NULL;
        if (connect && !eq(op, "connect")) {
            auto_req = cJSON_CreateObject();
            cJSON_AddStringToObject(auto_req, "op", "connect");
        }
        bool pending = false;
        int native = 0;
        int code = gw_protocol_ble_start(auto_req ? auto_req : step, d->addr, d->addr_type, &r->handle, &pending,
                                         &native);
        cJSON_Delete(auto_req);
        bool reject = eq(str(data_of(r->request), "policy"), "reject");
        if ((code == 2001 || code == 2003) && !reject) continue;
        if (!r->running) {
            r->running = true;
            r->started = now;
            r->deadline = now + number(r->request, "timeout",
                                       eq(str(r->request, "op"), "batch") ? 10000 : connect ? 15000 : 5000);
        }
        if (!code && pending) {
            r->pending = true;
            r->auto_connecting = connect && !eq(op, "connect");
            ++active;
            r->step_deadline = now + number(step, "timeout", connect ? 15000 : 5000);
            if (v) v->handle = r->handle;
            if (connect || eq(op, "disconnect")) {
                strcpy(d->connection, connect ? "connecting" : "disconnecting");
                d->dirty = true;
            }
        } else complete(r, code, native, NULL);
    }
    s_active = active;
}

bool gw_protocol_gatt_available(void) { return s_active < GW_V1_MAX_GATT_OPS; }

void gw_protocol_init(const char *gateway_id) {
    snprintf(s_gateway, sizeof(s_gateway), "%s", gateway_id);
    // 特征缓存较大，优先放入 PSRAM，避免占用内部堆
    s_values = heap_caps_calloc(VALUE_COUNT, sizeof(*s_values), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s_values) s_values = calloc(VALUE_COUNT, sizeof(*s_values));
    s_input = xQueueCreate(EVENT_COUNT, sizeof(protocol_input_t));
    if (!s_values || !s_input) abort();
    cJSON *registry = gw_manager_status();
    const cJSON *devices = cJSON_GetObjectItemCaseSensitive(registry, "devices"), *item;
    cJSON_ArrayForEach(item, devices) {
        int i = device_by_mac(str(item, "device"), true, number(item, "addressType", 0));
        if (i < 0) continue;
        const char *id = str(item, "deviceId"), *uuid = str(item, "deviceUuid");
        if (id && *id) snprintf(s_devices[i].id, sizeof(s_devices[i].id), "%s", id);
        if (uuid) snprintf(s_devices[i].uuid, sizeof(s_devices[i].uuid), "%s", uuid);
        // 只有用户登记过的设备才允许通过协议连接和操作
        s_devices[i].registered = true;
    }
    cJSON_Delete(registry);
}

void gw_protocol_receive(const char *text, int len, int route) {
    if (!s_input || len <= 0 || len > GW_V1_MAX_FRAME) return;
    int depth = 0;
    bool quoted = false, escaped = false;
    for (int i = 0; i < len; ++i) {
        char ch = text[i];
        if (!ch) return;
        if (quoted) {
            if (escaped) escaped = false;
            else if (ch == '\\') {
                if (i + 5 < len && text[i + 1] == 'u' && !memcmp(text + i + 2, "0000", 4)) return;
                escaped = true;
            } else if (ch == '"') quoted = false;
        } else if (ch == '"') quoted = true;
        else if (ch == '{' || ch == '[') { if (++depth > 16) return; } else if (ch == '}' || ch == ']') {
            if (--depth < 0) return;
        }
    }
    if (depth || quoted) return;
    char *copy = malloc((size_t) len + 1);
    if (!copy) return;
    memcpy(copy, text, len);
    copy[len] = 0;
    protocol_input_t input = {.json = cJSON_ParseWithLengthOpts(copy, (size_t) len + 1, NULL, true), .route = route};
    free(copy);
    if (!input.json) return;
    if (xQueueSend(s_input, &input, 0) != pdTRUE) {
        cJSON_Delete(input.json);
        atomic_fetch_add(&s_overflow, 1);
    }
}

bool gw_protocol_event(const cJSON *event) {
    if (!s_input) return false;
    // 扫描允许窗口内去重，优先给操作完成和流式通知保留队列空间
    if (eq(str(event, "type"), "ble.scan") && uxQueueSpacesAvailable(s_input) < 16) return false;
    protocol_input_t input = {.json = cJSON_Duplicate(event, true), .event = true};
    if (!input.json || xQueueSend(s_input, &input, 0) != pdTRUE) {
        cJSON_Delete(input.json);
        atomic_fetch_add(&s_overflow, 1);
        return false;
    }
    return true;
}

void gw_protocol_online(void) { s_online = true; }

static void hello(void) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "type", "event");
    cJSON_AddStringToObject(o, "op", "hello");
    timestamp(o);
    cJSON *data = cJSON_AddObjectToObject(o, "data");
    cJSON_AddNumberToObject(data, "protocol", 1);
    cJSON_AddStringToObject(data, "firmware", GW_FIRMWARE_VERSION);
    cJSON_AddBoolToObject(data, "timeSynced", gw_protocol_timestamp() != 0);
    cJSON *ble = cJSON_AddObjectToObject(data, "ble");
    cJSON_AddNumberToObject(ble, "maxConnections", 32);
    cJSON_AddNumberToObject(ble, "maxGattOps", GW_V1_MAX_GATT_OPS);
    cJSON_AddBoolToObject(ble, "requireRegistration", true);
    cJSON *features = cJSON_AddObjectToObject(data, "features");
    cJSON_AddBoolToObject(features, "management", true);
    cJSON_AddBoolToObject(features, "batch", true);
    cJSON_AddBoolToObject(features, "snapshot", true);
    cJSON_AddBoolToObject(features, "scan", true);
    cJSON_AddBoolToObject(features, "notify", true);
    cJSON_AddBoolToObject(features, "waitNotify", false);
    // 管理动作列表与 gw_manager_manage 保持一致，App 据此决定显示哪些入口
    const char *actions[] = {
        "status", "backup", "save", "upsert", "remove", "pause", "resume",
        "seen", "diagnostics", "config.get", "config.set", "restart"
    };
    cJSON_AddItemToObject(features, "managementActions",
                          cJSON_CreateStringArray(actions, sizeof(actions) / sizeof(actions[0])));
    const char *formats[] = {"hex", "base64", "utf8"};
    cJSON_AddItemToObject(data, "formats", cJSON_CreateStringArray(formats, 3));
    cJSON_AddNumberToObject(data, "maxFrameBytes", GW_V1_MAX_FRAME);
    cJSON_AddNumberToObject(data, "dedupEntries", CACHE_COUNT);
    cJSON_AddNumberToObject(data, "dedupBytes", CACHE_BYTES);
    cJSON *counters = cJSON_AddObjectToObject(data, "counters");
    cJSON_AddNumberToObject(counters, "unmatchedNotify", atomic_load(&s_unmatched));
    send_message(o, NULL, ROUTE_BROADCAST, 1);
    cJSON_Delete(o);
}

void gw_protocol_tick(void) {
    if (atomic_exchange(&s_online, false)) hello();
    protocol_input_t input;
    for (unsigned i = 0; i < EVENT_COUNT && xQueueReceive(s_input, &input, 0) == pdTRUE; ++i) {
        if (input.event) process_event(input.json);
        else accept_frame(input.json, input.route);
        cJSON_Delete(input.json);
    }
    unsigned lost = atomic_exchange(&s_overflow, 0);
    if (lost) {
        ESP_LOGE("protocol", "Input/stream overflow: %u", lost);
        for (unsigned i = 0; i < VALUE_COUNT; ++i) {
            protocol_value_t *v = &s_values[i];
            if (!v->used || !v->subscribed || v->latest) continue;
            protocol_device_t *d = &s_devices[v->device];
            if (!d->quarantine) {
                d->quarantine = true;
                d->quarantine_until = monotonic_ms() + QUARANTINE_MS;
                gw_adapter_disconnect(d->addr);
            }
        }
        cJSON *o = cJSON_CreateObject();
        cJSON_AddStringToObject(o, "type", "event");
        cJSON_AddStringToObject(o, "op", "overflow");
        cJSON_AddNumberToObject(o, "code", 2001);
        cJSON_AddNumberToObject(cJSON_AddObjectToObject(o, "data"), "dropped", lost);
        timestamp(o);
        send_message(o, NULL, ROUTE_BROADCAST, 1);
        cJSON_Delete(o);
    }
    schedule();
    for (unsigned i = 0; i < 8 && s_stream_count; ++i) {
        cJSON *o = s_stream[s_stream_head];
        if (!send_message(o, NULL, ROUTE_MQTT, 1)) break;
        cJSON_Delete(o);
        s_stream[s_stream_head] = NULL;
        s_stream_head = (s_stream_head + 1) % EVENT_COUNT;
        --s_stream_count;
    }
    int64_t now = monotonic_ms();
    if (now >= s_flush) {
        s_flush = now + 200;
        flush_state();
        if (s_scan_until) {
            cJSON *o = cJSON_CreateObject();
            cJSON_AddStringToObject(o, "type", "event");
            cJSON_AddStringToObject(o, "op", "scan");
            timestamp(o);
            cJSON *data = cJSON_AddObjectToObject(o, "data"), *devices = cJSON_AddArrayToObject(data, "devices");
            cJSON_AddStringToObject(data, "scanId", s_scan_id);
            for (int i = 0; i < DEVICE_COUNT; ++i)
                if (s_devices[i].scan_dirty) {
                    cJSON_AddItemToArray(devices, scan_json(i));
                    s_devices[i].scan_dirty = false;
                }
            if (cJSON_GetArraySize(devices)) send_message(o, NULL, ROUTE_BROADCAST, 0);
            cJSON_Delete(o);
            if (now >= s_scan_until) s_scan_until = 0;
        }
    }
}
#if CONFIG_HTTPD_WS_SUPPORT
static esp_err_t ws_handler(httpd_req_t *req) {
    if (req->method == HTTP_GET) {
        ws_session_t *session = calloc(1, sizeof(*session));
        if (!session) return ESP_ERR_NO_MEM;
        session->route = (int) (++s_ws_sequence & 0x7fffffff);
        req->sess_ctx = session;
        return ESP_OK;
    }
    httpd_ws_frame_t frame = {0};
    esp_err_t err = httpd_ws_recv_frame(req, &frame, 0);
    if (err != ESP_OK) return err;
    if (frame.type != HTTPD_WS_TYPE_TEXT || !frame.final || frame.len > GW_V1_MAX_FRAME || !frame.len) return ESP_FAIL;
    frame.payload = malloc(frame.len + 1);
    if (!frame.payload) return ESP_ERR_NO_MEM;
    err = httpd_ws_recv_frame(req, &frame, frame.len);
    if (err == ESP_OK) gw_protocol_receive((const char *) frame.payload, frame.len,
                                           ((ws_session_t *) req->sess_ctx)->route);
    free(frame.payload);
    return err;
}
#endif
void gw_protocol_http_register(httpd_handle_t server) {
    s_http = server;
#if CONFIG_HTTPD_WS_SUPPORT
    const httpd_uri_t uri = {.uri = "/ble/v1", .method = HTTP_GET, .handler = ws_handler, .is_websocket = true};
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &uri));
#endif
}
