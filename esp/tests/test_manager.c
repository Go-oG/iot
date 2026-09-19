#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "device_config.h"
#include "report_buffer.h"

typedef int esp_err_t;
typedef int SemaphoreHandle_t;
typedef uint8_t esp_bd_addr_t[6];
#define ESP_OK 0
#define ESP_ERR_INVALID_STATE 259
#define ESP_ERR_NO_MEM 257
#define ESP_ERR_NOT_FOUND 261
#define ESP_ERR_NOT_SUPPORTED 262
#define ESP_ERR_TIMEOUT 263
static const char *esp_err_to_name(int error) { (void)error; return "unknown"; }
#define portMAX_DELAY 0
static int lock_depth;
static int xSemaphoreTake(int lock, int delay) { (void)lock; (void)delay; assert(!lock_depth); ++lock_depth; return 1; }
static void xSemaphoreGive(int lock) { (void)lock; assert(lock_depth == 1); --lock_depth; }
static int64_t clock_ms = 100000;
static int64_t esp_timer_get_time(void) { return clock_ms * 1000; }
typedef struct { bool connected, services_ready, subscription_pending; int64_t started_ms; } gw_link_t;
typedef struct { uint8_t bda[6]; uint16_t min_int, max_int, timeout; } esp_ble_conn_update_params_t;
static int esp_ble_gap_update_conn_params(esp_ble_conn_update_params_t *p) { assert(!lock_depth); assert(p->timeout * 10 > p->max_int * 2.5); return 0; }
static int esp_ble_gap_read_rssi(uint8_t addr[6]) { (void)addr; assert(!lock_depth); return 0; }
static gw_link_t links[32];
static bool present[32], output_ready = true, auto_subscribe = true;
static unsigned connects, scans, disconnects, subscribed, published[32];
static bool gw_adapter_link(const uint8_t addr[6], gw_link_t *link) { assert(!lock_depth); *link = links[addr[5]]; return present[addr[5]]; }
static esp_err_t gw_adapter_connect(const uint8_t addr[6], uint8_t type) { (void)type; assert(!lock_depth); ++connects; present[addr[5]] = true; links[addr[5]].started_ms = clock_ms; return ESP_OK; }
static esp_err_t gw_adapter_disconnect(const uint8_t addr[6]);
static esp_err_t gw_adapter_subscribe(const gw_device_t *device, unsigned index);
static esp_err_t gw_adapter_scan(void) { assert(!lock_depth); ++scans; return ESP_OK; }
static bool gw_adapter_report(const uint8_t addr[6], const gw_report_t *report) { (void)report; assert(!lock_depth); ++published[addr[5]]; return output_ready; }
static void gw_adapter_expire(void) {}
static bool gw_adapter_protocol_owned(const uint8_t addr[6]) { (void)addr; return false; }
#include "manager_under_test.inc"
static esp_err_t gw_adapter_disconnect(const uint8_t addr[6]) { assert(!lock_depth); ++disconnects; present[addr[5]] = false; memset(&links[addr[5]], 0, sizeof(gw_link_t)); gw_manager_connection(addr, false, 22); return 0; }
static esp_err_t gw_adapter_subscribe(const gw_device_t *device, unsigned index) { assert(!lock_depth); assert(index < device->subscription_count); ++subscribed; if (auto_subscribe) gw_manager_subscription(device->addr, 0); return 0; }
static void reset(unsigned count) {
    free(s_runtime); s_runtime = calloc(32, sizeof(*s_runtime));
    memset(&s_registry, 0, sizeof(s_registry)); memset(links, 0, sizeof(links)); memset(present, 0, sizeof(present));
    memset(published, 0, sizeof(published)); memset(s_seen, 0, sizeof(s_seen));
    s_registry.count = count;
    for (unsigned i = 0; i < count; ++i) { s_registry.devices[i].addr[5] = i; s_registry.devices[i].enabled = true; s_registry.devices[i].interval_min_ms = 100; s_registry.devices[i].interval_max_ms = 200; }
    connects = scans = disconnects = subscribed = 0;
    s_next_connect_ms = s_next_scan_ms = 0; s_scan_requested = false; s_connect_cursor = 0;
    output_ready = auto_subscribe = true; clock_ms += 1000000;
}
int main(void) {
    reset(2);
    gw_manager_tick(); assert(connects == 1);
    clock_ms += 3000; gw_manager_tick(); assert(connects == 1);
    links[0].connected = true; links[0].services_ready = true; gw_manager_connection(s_registry.devices[0].addr, true, 0);
    clock_ms += 50; gw_manager_tick(); assert(connects == 2);
    gw_manager_connection(s_registry.devices[1].addr, false, 8); present[1] = false;
    assert(s_runtime[1].retry_ms > clock_ms);
    clock_ms += 500; gw_manager_tick(); assert(connects == 2);
    clock_ms += 3000; gw_manager_tick(); assert(connects == 3);
    gw_manager_pause(s_registry.devices[0].addr, true);
    clock_ms += 50; gw_manager_tick(); assert(!present[0] && s_runtime[0].paused);
    gw_manager_pause(s_registry.devices[0].addr, false); assert(!s_runtime[0].paused && !s_runtime[0].retry_ms);

    reset(1); links[0] = (gw_link_t){.connected=true,.services_ready=true,.started_ms=clock_ms}; present[0]=true;
    s_registry.devices[0].subscription_count = 4;
    for (unsigned i = 0; i < 4; ++i) { gw_manager_tick(); clock_ms += 50; }
    assert(subscribed == 4 && s_runtime[0].restored == 4);
    gw_manager_connection(s_registry.devices[0].addr, false, 19); assert(s_runtime[0].restored == 0);
    gw_manager_connection(s_registry.devices[0].addr, true, 0);
    for (unsigned i = 0; i < 4; ++i) { gw_manager_tick(); clock_ms += 50; }
    assert(subscribed == 8 && s_runtime[0].restored == 4);
    s_runtime[0].restored = 0; auto_subscribe = false;
    gw_manager_tick(); clock_ms += 11000; gw_manager_tick(); assert(disconnects == 1);

    reset(32);
    gw_report_t report = {.handle=1,.len=1,.data={7}};
    for (unsigned i=0;i<32;++i) {
        present[i]=true; links[i]=(gw_link_t){.connected=true,.services_ready=true,.started_ms=clock_ms};
        assert(gw_manager_report(s_registry.devices[i].addr,&report));
    }
    for (unsigned tick=0;tick<4;++tick) { gw_manager_tick(); clock_ms+=50; }
    for(unsigned i=0;i<32;++i) assert(published[i]==1);
    output_ready=false; assert(gw_manager_report(s_registry.devices[0].addr,&report)); assert(s_runtime[0].reports.dropped==1);
    output_ready=true; gw_manager_report(s_registry.devices[0].addr,&report); gw_manager_pause(s_registry.devices[0].addr,true);
    assert(s_runtime[0].reports.dropped==1);

    reset(2); s_registry.devices[1].broadcast=true;
    gw_manager_tick(); assert(scans==1 && connects==0);
    clock_ms+=6000; gw_manager_tick(); assert(connects==1 && !present[1]);
    clock_ms+=16000; gw_manager_tick(); assert(disconnects==1);
    const uint8_t ad[]={4,9,'B','L','E'}; gw_manager_seen(s_registry.devices[1].addr,1,-50,ad,sizeof(ad));
    assert(s_runtime[1].rssi==-50);
    cJSON *status=gw_manager_status(); assert(status); cJSON_Delete(status);
    free(s_runtime);
    puts("PASS: serialized reconnect/backoff/pause, subscription restore/timeout, protocol forwarding, enqueue failures, broadcast scan priority");
}
