#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "device_config.h"

#define GW_V1_MAX_FRAME 65536
#define GW_V1_MAX_GATT_OPS 4
#define CONFIG_HTTPD_WS_SUPPORT 0
#define ESP_OK 0
#define pdTRUE 1
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(x) ((void)(x))
#define portEXIT_CRITICAL(x) ((void)(x))
#define ESP_LOGE(...) ((void)0)
typedef int portMUX_TYPE;
typedef void *httpd_handle_t;
typedef struct { unsigned capacity, size, count, head; unsigned char *items; } *QueueHandle_t;
static QueueHandle_t xQueueCreate(unsigned capacity, unsigned size) {
    QueueHandle_t q = calloc(1, sizeof(*q)); q->capacity = capacity; q->size = size; q->items = calloc(capacity, size); return q;
}
static unsigned uxQueueSpacesAvailable(QueueHandle_t q) { return q->capacity - q->count; }
static int xQueueSend(QueueHandle_t q, const void *item, int ticks) {
    (void)ticks; if (q->count == q->capacity) return 0;
    memcpy(q->items + ((q->head + q->count++) % q->capacity) * q->size, item, q->size); return 1;
}
static int xQueueReceive(QueueHandle_t q, void *item, int ticks) {
    (void)ticks; if (!q->count) return 0;
    memcpy(item, q->items + q->head * q->size, q->size); q->head = (q->head + 1) % q->capacity; --q->count; return 1;
}
static int64_t clock_ms = 1000;
static int64_t esp_timer_get_time(void) { return clock_ms * 1000; }
typedef struct { bool connected, services_ready, subscription_pending; int64_t started_ms; } gw_link_t;
static gw_link_t links[256];
static unsigned starts, closes;
static unsigned gw_protocol_managed_gatt_count(void) { return 0; }
static bool mqtt_ready = true;
static int forced_code;
static char operations[128][16];
static cJSON *sent[1024];
static unsigned sent_count;
static bool gw_adapter_link(const uint8_t addr[6], gw_link_t *link) { *link = links[addr[5]]; return link->connected; }
static int gw_adapter_disconnect(const uint8_t addr[6]) { (void)addr; ++closes; return 0; }
static cJSON *gw_manager_status(void) { return cJSON_Parse("{\"devices\":[]}"); }
static unsigned management_calls, restart_calls;
static int gw_manager_manage(const cJSON *data, cJSON **result, const char **error) {
    (void)data; (void)error; ++management_calls;
    *result = cJSON_Parse("{\"restarting\":true}"); return 0;
}
static void gw_adapter_restart(void) { ++restart_calls; }
static bool gw_protocol_publish(cJSON *frame, int qos) {
    assert(qos >= 0 && qos <= 1);
    if (!mqtt_ready) return false;
    assert(sent_count < 1024); sent[sent_count++] = cJSON_Duplicate(frame, true); return true;
}
static int gw_protocol_ble_start(const cJSON *request, const uint8_t addr[6], uint8_t type,
                                 uint16_t *handle, bool *pending, int *native) {
    (void)addr; (void)type; *native = 0;
    if (forced_code) return forced_code;
    const char *op = cJSON_GetObjectItemCaseSensitive(request, "op")->valuestring;
    assert(starts < 128); snprintf(operations[starts++], 16, "%s", op);
    *pending = strcmp(op, "scan") != 0; *handle = 42;
    return 0;
}
// Base64 由固件链接的 mbedTLS 提供，这里的测试集中验证调度及 UTF-8/hex 路径
static int mbedtls_base64_decode(unsigned char *a, size_t b, size_t *c, const unsigned char *d, size_t e) {
    (void)a; (void)b; (void)c; (void)d; (void)e; return -1;
}
static int mbedtls_base64_encode(unsigned char *a, size_t b, size_t *c, const unsigned char *d, size_t e) {
    (void)a; (void)b; (void)c; (void)d; (void)e; return -1;
}
#define MALLOC_CAP_SPIRAM 0
#define MALLOC_CAP_8BIT 0
static void *heap_caps_calloc(size_t n, size_t size, int caps) { (void)caps; return calloc(n, size); }
#include "protocol_under_test.inc"

static void clear_sent(void) { for (unsigned i = 0; i < sent_count; ++i) cJSON_Delete(sent[i]); sent_count = 0; }
static void reset(void) {
    for (unsigned i = 0; i < REQUEST_COUNT; ++i) { cJSON_Delete(s_requests[i].request); cJSON_Delete(s_requests[i].results); }
    for (unsigned i = 0; i < CACHE_COUNT; ++i) cJSON_free(s_cache[i].response);
    for (unsigned i = 0; i < EVENT_COUNT; ++i) cJSON_Delete(s_stream[i]);
    memset(s_requests, 0, sizeof(s_requests)); memset(s_cache, 0, sizeof(s_cache)); memset(s_devices, 0, sizeof(s_devices));
    memset(s_stream, 0, sizeof(s_stream)); memset(links, 0, sizeof(links));
    free(s_values); s_values = NULL;
    if (s_input) { assert(!s_input->count); free(s_input->items); free(s_input); }
    s_input = NULL; s_owned_count = s_cache_cursor = s_sequence = s_revision = s_stream_count = s_stream_head = 0;
    s_flush = 0; s_scan_until = 0; s_cache_bytes = 0; s_overflow = 0; s_unmatched = 0;
    starts = closes = 0; forced_code = 0; mqtt_ready = true;
    clock_ms += 10000; clear_sent(); gw_protocol_init("gw-test");
}
static void known(unsigned suffix) {
    char mac[18]; snprintf(mac, sizeof(mac), "AA:BB:CC:DD:EE:%02X", suffix);
    int i = device_by_mac(mac, true, 0);
    assert(i >= 0); s_devices[i].registered = true;
    links[suffix].connected = links[suffix].services_ready = true;
}
static void request(const char *messages) {
    cJSON *frame = cJSON_CreateObject(); cJSON_AddNumberToObject(frame, "v", 1);
    cJSON_AddStringToObject(frame, "gatewayId", "gw-test"); cJSON_AddStringToObject(frame, "clientId", "app-test");
    cJSON *items = cJSON_Parse(messages); assert(items); cJSON_AddItemToObject(frame, "messages", items);
    char *text = cJSON_PrintUnformatted(frame); gw_protocol_receive(text, strlen(text), -1);
    free(text); cJSON_Delete(frame); gw_protocol_tick();
}
static cJSON *result(const char *id) {
    for (unsigned i = sent_count; i > 0; --i) {
        cJSON *message = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(sent[i-1], "messages"), 0);
        if (eq(str(message, "reqId"), id)) return message;
    }
    return NULL;
}
static void event(const char *type, int suffix, int status, const char *value) {
    cJSON *e = cJSON_CreateObject(); cJSON_AddStringToObject(e, "type", type);
    char mac[18]; snprintf(mac, sizeof(mac), "AA:BB:CC:DD:EE:%02X", suffix);
    cJSON_AddStringToObject(e, "device", mac); cJSON_AddNumberToObject(e, "status", status);
    cJSON_AddNumberToObject(e, "handle", 42);
    if (value) cJSON_AddStringToObject(e, "data", value);
    gw_protocol_event(e); cJSON_Delete(e); gw_protocol_tick();
}
#define READ1 "{\"type\":\"req\",\"reqId\":\"r1\",\"op\":\"read\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\"}"
int main(void) {
    reset();
    request("[{\"type\":\"req\",\"reqId\":\"manage-1\",\"op\":\"manage\",\"data\":{\"action\":\"restart\"}}]");
    assert(management_calls == 1 && restart_calls == 1);
    assert(number(result("manage-1"), "code", -1) == 0);
    request("[{\"type\":\"req\",\"reqId\":\"manage-1\",\"op\":\"manage\",\"data\":{\"action\":\"restart\"}}]");
    assert(management_calls == 1 && restart_calls == 1);

    reset(); known(1); known(2);
    request("[" READ1 ", {\"type\":\"req\",\"reqId\":\"r2\",\"op\":\"read\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\"},"
            "{\"type\":\"req\",\"reqId\":\"r3\",\"op\":\"read\",\"deviceId\":\"AA:BB:CC:DD:EE:02\",\"service\":\"fff0\",\"char\":\"fff1\"}]");
    assert(starts == 2 && !result("r1"));
    request("[" READ1 "]"); assert(starts == 2);
    event("ble.read_result", 1, 0, "64"); assert(starts == 3 && number(result("r1"), "code", -1) == 0);
    assert(eq(str(result("r1"), "value"), "64"));
    request("[" READ1 "]"); assert(starts == 3);
    event("ble.read_result", 1, 14, NULL); assert(number(result("r2"), "code", -1) == 4101);
    event("ble.read_result", 2, 0, "65");
    assert(s_values[0].valid);
    unsigned rev = s_revision;
    request("[{\"type\":\"req\",\"reqId\":\"sync\",\"op\":\"snapshot\"}]");
    assert(number(data_of(result("sync")), "revision", -1) == (int)(rev + 1));

    reset(); known(1);
    request("[{\"type\":\"req\",\"reqId\":\"batch\",\"op\":\"batch\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"data\":{\"steps\":[{\"id\":\"s1\",\"op\":\"write\",\"service\":\"fff0\",\"char\":\"fff1\",\"value\":\"01\"},{\"id\":\"s2\",\"op\":\"read\",\"service\":\"fff0\",\"char\":\"fff1\"}]}}," READ1 "]");
    assert(starts == 1 && !strcmp(operations[0], "write"));
    event("ble.write_result", 1, 14, NULL);
    assert(number(result("batch"), "code", -1) == 4003);
    cJSON *steps = cJSON_GetObjectItemCaseSensitive(data_of(result("batch")), "steps");
    assert(number(cJSON_GetArrayItem(steps, 0), "code", -1) == 4201);
    assert(number(cJSON_GetArrayItem(steps, 1), "code", -1) == 4999);
    assert(starts == 2 && !s_values[0].valid);

    reset(); known(1);
    request("[" READ1 ", {\"type\":\"req\",\"reqId\":\"queued\",\"op\":\"read\",\"queueTimeout\":10,\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\"}]");
    clock_ms += 11; gw_protocol_tick(); assert(number(result("queued"), "code", -1) == 2002 && starts == 1);
    clock_ms += 5000; gw_protocol_tick(); assert(number(result("r1"), "code", -1) == 4901 && closes == 1);
    request("[{\"type\":\"req\",\"reqId\":\"late\",\"op\":\"read\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\"}]");
    event("ble.read_result", 1, 0, "99"); assert(starts == 1 && !result("late"));
    links[1].connected = false; event("ble.connection", 1, 0, NULL);
    assert(number(result("late"), "code", -1) == 3002);

    reset(); known(1);
    request("[{\"type\":\"req\",\"reqId\":\"sub\",\"op\":\"subscribe\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"0000fff0-0000-1000-8000-00805f9b34fb\",\"char\":\"fff1\"}]");
    event("ble.subscribe_result", 1, 0, NULL);
    mqtt_ready = false;
    event("ble.notify", 1, 0, "01"); event("ble.notify", 1, 0, "02");
    assert(s_stream_count == 2 && !strcmp(s_values[0].value, "02"));
    mqtt_ready = true; gw_protocol_tick(); assert(s_stream_count == 0);
    char uuid[37]; assert(normalize_uuid("0000FFF0-0000-1000-8000-00805F9B34FB", uuid) && !strcmp(uuid, "fff0"));
    assert(!normalize_uuid("0000-fff0-00001000800000805f9b34fb", uuid));
    cJSON *read = cJSON_Parse("{\"format\":\"utf8\"}"), *out = cJSON_CreateObject();
    assert(add_read_value(out, read, "E4BDA0E5A5BD") && eq(str(out, "value"), "你好")); cJSON_Delete(out);
    out = cJSON_CreateObject(); assert(!add_read_value(out, read, "C080")); cJSON_Delete(out); cJSON_Delete(read);


    reset(); known(1);
    request("[{\"type\":\"req\",\"reqId\":\"atomic\",\"op\":\"batch\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"data\":{\"stopOnError\":false,\"steps\":[{\"op\":\"write\",\"service\":\"fff0\",\"char\":\"fff1\",\"value\":\"01\"},{\"op\":\"read\",\"service\":\"fff0\",\"char\":\"fff1\"}]}}," READ1 "]");
    event("ble.write_result", 1, 14, NULL);
    assert(starts == 2 && !result("atomic") && !result("r1"));
    event("ble.read_result", 1, 0, "66");
    assert(starts == 3 && number(result("atomic"), "code", -1) == 4003);
    steps = cJSON_GetObjectItemCaseSensitive(data_of(result("atomic")), "steps");
    assert(number(cJSON_GetArrayItem(steps, 1), "code", -1) == 0);

    reset();
    for (unsigned i = 1; i <= 5; ++i) {
        known(i);
        char message[256]; snprintf(message, sizeof(message), "[{\"type\":\"req\",\"reqId\":\"p%u\",\"op\":\"read\",\"deviceId\":\"AA:BB:CC:DD:EE:%02X\",\"service\":\"fff0\",\"char\":\"fff1\"}]", i, i);
        request(message);
    }
    assert(starts == 4); event("ble.read_result", 1, 0, "01"); assert(starts == 5);

    reset(); known(1); links[1].connected = false;
    request("[{\"type\":\"req\",\"reqId\":\"auto\",\"op\":\"read\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\",\"data\":{\"autoConnect\":true}}]");
    assert(starts == 1 && !strcmp(operations[0], "connect"));
    links[1].connected = links[1].services_ready = true;
    event("ble.services_ready", 1, 0, NULL);
    assert(starts == 2 && !strcmp(operations[1], "read") && !result("auto"));
    event("ble.read_result", 1, 0, "01"); assert(number(result("auto"), "code", -1) == 0);

    reset(); known(1);
    request("[{\"type\":\"req\",\"reqId\":\"latest\",\"op\":\"subscribe\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\",\"data\":{\"delivery\":\"latest\"}}]");
    event("ble.subscribe_result", 1, 0, NULL); mqtt_ready = false;
    event("ble.notify", 1, 0, "31"); event("ble.notify", 1, 0, "32");
    assert(s_stream_count == 0 && !strcmp(s_values[0].value, "32"));
    mqtt_ready = true;
    request("[{\"type\":\"req\",\"reqId\":\"step-timeout\",\"op\":\"batch\",\"timeout\":10000,\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"data\":{\"steps\":[{\"op\":\"read\",\"timeout\":20,\"service\":\"fff0\",\"char\":\"fff1\"}]}}]");
    clock_ms += 21; gw_protocol_tick();
    steps = cJSON_GetObjectItemCaseSensitive(data_of(result("step-timeout")), "steps");
    assert(number(cJSON_GetArrayItem(steps, 0), "code", -1) == 4901 && closes == 1);

    reset(); known(1);
    cJSON *managed = cJSON_Parse("{\"type\":\"ble.subscribe_result\",\"device\":\"AA:BB:CC:DD:EE:01\",\"status\":0,\"handle\":42,\"service\":\"FFF0\",\"char\":\"FFF1\",\"latest\":false}");
    assert(gw_protocol_event(managed)); cJSON_Delete(managed); gw_protocol_tick();
    mqtt_ready = false; event("ble.notify", 1, 0, "AB");
    assert(s_stream_count == 1 && s_values[0].subscribed && !strcmp(s_values[0].value, "AB"));
    mqtt_ready = true; gw_protocol_tick(); assert(s_stream_count == 0);
    unsigned before = starts;
    const char *old_request = "{\"id\":\"old\",\"op\":\"ble.write\",\"device\":\"AA:BB:CC:DD:EE:01\",\"data\":\"01\"}";
    gw_protocol_receive(old_request, strlen(old_request), -1); gw_protocol_tick();
    assert(starts == before);

    reset(); known(1); forced_code = 2003;
    links[1].connected = false;
    request("[{\"type\":\"req\",\"reqId\":\"connect\",\"op\":\"connect\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"queueTimeout\":100}]");
    assert(!result("connect")); clock_ms += 101; gw_protocol_tick(); assert(number(result("connect"), "code", -1) == 2002);
    request("[{\"type\":\"req\",\"reqId\":\"bad\",\"op\":\"read\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"zzzz\",\"char\":\"fff1\"}]");
    assert(number(result("bad"), "code", -1) == 1003);

    // 未登记设备不允许连接：完全未知返回 3001，扫描发现过但未登记返回 3004
    reset(); known(1);
    request("[{\"type\":\"req\",\"reqId\":\"unregistered\",\"op\":\"connect\",\"deviceId\":\"AA:BB:CC:DD:EE:77\"}]");
    assert(number(result("unregistered"), "code", -1) == 3001);
    cJSON *scan = cJSON_CreateObject();
    cJSON_AddStringToObject(scan, "type", "ble.scan");
    cJSON_AddStringToObject(scan, "device", "AA:BB:CC:DD:EE:77");
    cJSON_AddNumberToObject(scan, "rssi", -55); cJSON_AddNumberToObject(scan, "addressType", 1);
    cJSON_AddStringToObject(scan, "name", "Sensor-X");
    cJSON_AddStringToObject(scan, "advertisement", "0509424C45");
    assert(gw_protocol_event(scan)); cJSON_Delete(scan); gw_protocol_tick();
    request("[{\"type\":\"req\",\"reqId\":\"scanned\",\"op\":\"connect\",\"deviceId\":\"AA:BB:CC:DD:EE:77\"}]");
    assert(number(result("scanned"), "code", -1) == 3004);

    // 扫描结果带名称与广播原文，标记未登记，并且不产生状态增量
    unsigned revision_before = s_revision;
    request("[{\"type\":\"req\",\"reqId\":\"scan-start\",\"op\":\"scan\",\"data\":{\"action\":\"start\",\"duration\":1000}}]");
    assert(eq(str(data_of(result("scan-start")), "scanId"), s_scan_id));
    cJSON *adv = cJSON_CreateObject();
    cJSON_AddStringToObject(adv, "type", "ble.scan");
    cJSON_AddStringToObject(adv, "device", "AA:BB:CC:DD:EE:77");
    cJSON_AddNumberToObject(adv, "rssi", -55); cJSON_AddNumberToObject(adv, "addressType", 1);
    cJSON_AddStringToObject(adv, "name", "Sensor-X");
    cJSON_AddStringToObject(adv, "advertisement", "0509424C45");
    clock_ms += 200; assert(gw_protocol_event(adv)); cJSON_Delete(adv); gw_protocol_tick();
    cJSON *scan_event = NULL;
    for (unsigned i = sent_count; i > 0; --i) {
        cJSON *message = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(sent[i-1], "messages"), 0);
        if (eq(str(message, "op"), "scan")) { scan_event = message; break; }
    }
    assert(scan_event);
    cJSON *found = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(data_of(scan_event), "devices"), 0);
    assert(found && eq(str(found, "name"), "Sensor-X") && eq(str(found, "advertisement"), "0509424C45"));
    assert(number(found, "rssi", 0) == -55 && cJSON_IsFalse(cJSON_GetObjectItemCaseSensitive(found, "registered")));
    assert(s_revision == revision_before);
    request("[{\"type\":\"req\",\"reqId\":\"scan-stop\",\"op\":\"scan\",\"data\":{\"action\":\"stop\"}}]");

    // 扫描发现大量设备时只回收临时条目，登记设备始终保留并可继续操作
    reset(); known(1);
    for (unsigned i = 2; i <= 90; ++i) {
        char mac[18]; snprintf(mac, sizeof(mac), "AA:BB:CC:DD:EE:%02X", i);
        cJSON *e = cJSON_CreateObject(); cJSON_AddStringToObject(e, "type", "ble.scan");
        cJSON_AddStringToObject(e, "device", mac); cJSON_AddNumberToObject(e, "rssi", -60);
        assert(gw_protocol_event(e)); cJSON_Delete(e); gw_protocol_tick();
    }
    assert(find_device("AA:BB:CC:DD:EE:01") >= 0);
    unsigned live = 0;
    for (int i = 0; i < DEVICE_COUNT; ++i) live += s_devices[i].used ? 1 : 0;
    assert(live <= DEVICE_COUNT);
    request("[" READ1 "]");
    assert(starts == 1);

    // 读失败后不留下空缓存项
    reset(); known(1);
    request("[" READ1 "]");
    unsigned used = 0;
    for (unsigned i = 0; i < VALUE_COUNT; ++i) used += s_values[i].used ? 1 : 0;
    assert(used == 1);
    event("ble.read_result", 1, 14, NULL);
    assert(number(result("r1"), "code", -1) == 4101);
    used = 0;
    for (unsigned i = 0; i < VALUE_COUNT; ++i) used += s_values[i].used ? 1 : 0;
    assert(used == 0);

    // 连接建立失败返回 3003，不再冒充断开
    reset(); known(1); links[1].connected = links[1].services_ready = false;
    request("[{\"type\":\"req\",\"reqId\":\"failed\",\"op\":\"connect\",\"deviceId\":\"AA:BB:CC:DD:EE:01\"}]");
    assert(starts == 1 && !strcmp(operations[0], "connect"));
    event("ble.connection", 1, 133, NULL);
    assert(number(result("failed"), "code", -1) == 3003);

    // Batch 内允许连接步骤：连接→读，按顺序执行
    reset(); known(1); links[1].connected = links[1].services_ready = false;
    request("[{\"type\":\"req\",\"reqId\":\"chain\",\"op\":\"batch\",\"deviceId\":\"AA:BB:CC:DD:EE:01\","
            "\"data\":{\"steps\":[{\"op\":\"connect\"},{\"op\":\"read\",\"service\":\"fff0\",\"char\":\"fff1\"}]}}]");
    assert(starts == 1 && !strcmp(operations[0], "connect"));
    links[1].connected = links[1].services_ready = true;
    event("ble.services_ready", 1, 0, NULL);
    assert(starts == 2 && !strcmp(operations[1], "read"));
    event("ble.read_result", 1, 0, "07");
    steps = cJSON_GetObjectItemCaseSensitive(data_of(result("chain")), "steps");
    assert(number(result("chain"), "code", -1) == 0);
    assert(number(cJSON_GetArrayItem(steps, 0), "code", -1) == 0 && eq(str(cJSON_GetArrayItem(steps, 1), "value"), "07"));

    // 隔离到期后必须放行：断开事件丢失时设备不能永久不可用
    reset(); known(1);
    request("[" READ1 "]");
    clock_ms += 5000; gw_protocol_tick();
    assert(number(result("r1"), "code", -1) == 4901 && closes == 1);
    links[1].connected = links[1].services_ready = false;
    request("[{\"type\":\"req\",\"reqId\":\"blocked\",\"op\":\"read\",\"queueTimeout\":100,\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\"}]");
    clock_ms += 101; gw_protocol_tick();
    assert(number(result("blocked"), "code", -1) == 2002 && starts == 1);
    clock_ms += 5000;
    links[1].connected = links[1].services_ready = true;
    request("[{\"type\":\"req\",\"reqId\":\"released\",\"op\":\"read\",\"queueTimeout\":1000,\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\"}]");
    assert(starts == 2 && !result("released"));

    // 写成功不改变缓存，也不留下空缓存项
    reset(); known(1);
    request("[{\"type\":\"req\",\"reqId\":\"w1\",\"op\":\"write\",\"deviceId\":\"AA:BB:CC:DD:EE:01\",\"service\":\"fff0\",\"char\":\"fff1\",\"value\":\"01\"}]");
    event("ble.write_result", 1, 0, NULL);
    assert(number(result("w1"), "code", -1) == 0);
    used = 0;
    for (unsigned i = 0; i < VALUE_COUNT; ++i) used += s_values[i].used ? 1 : 0;
    assert(used == 0);

    // 特征表满时回收最久未使用的非订阅项，已订阅的条目不可回收
    reset(); known(1);
    for (unsigned i = 0; i < VALUE_COUNT; ++i) {
        char service[8]; snprintf(service, sizeof(service), "%04X", i + 1);
        protocol_value_t *v = value_slot(0, service, "FFF1", true);
        assert(v);
        v->valid = true; v->used_ms = (int64_t)i;
    }
    protocol_value_t *recycled = value_slot(0, "FFFF", "FFF1", true);
    assert(recycled == &s_values[0] && !value_slot(0, "0001", "FFF1", false));
    for (unsigned i = 0; i < VALUE_COUNT; ++i) s_values[i].subscribed = true;
    assert(!value_slot(0, "ABC0", "FFF1", true));

    reset(); clear_sent(); free(s_values); free(s_input->items); free(s_input);
    puts("PASS: V1 FIFO/concurrency, pending/completed dedup, async errors, snapshot/revision, batch skip, "
         "timeout isolation, stream replay, UUID/UTF-8, registration gate, scan metadata, table recycling");
}
