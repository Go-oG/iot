#pragma once

#include "device_config.h"
#include "esp_err.h"
#include "esp_http_server.h"

#include "report_buffer.h"

typedef struct {
    bool connected;
    bool services_ready;
    bool subscription_pending;
    int64_t started_ms;
} gw_link_t;

void gw_manager_init(void);
void gw_manager_tick(void);
void gw_manager_http_register(httpd_handle_t server);
bool gw_http_json_post_allowed(httpd_req_t *req);
void gw_manager_connection(const uint8_t addr[6], bool connected, int status);
void gw_manager_subscription(const uint8_t addr[6], int status);
void gw_manager_rssi(const uint8_t addr[6], int rssi);
void gw_manager_interval(const uint8_t addr[6], int status, uint16_t units);
void gw_manager_seen(const uint8_t addr[6], uint8_t address_type, int rssi, const uint8_t *data, size_t len);
bool gw_manager_report(const uint8_t addr[6], const gw_report_t *report);
void gw_manager_pause(const uint8_t addr[6], bool pause);
cJSON *gw_manager_status(void);

// 由主程序实现 BLE 与 MQTT 适配，管理器不直接操作连接池
bool gw_adapter_link(const uint8_t addr[6], gw_link_t *link);
esp_err_t gw_adapter_connect(const uint8_t addr[6], uint8_t address_type);
esp_err_t gw_adapter_disconnect(const uint8_t addr[6]);
esp_err_t gw_adapter_subscribe(const gw_device_t *device, unsigned index);
esp_err_t gw_adapter_scan(void);
bool gw_adapter_report(const uint8_t addr[6], const gw_report_t *report);
cJSON *gw_adapter_diagnostics(void);
void gw_adapter_restart(void);
void gw_adapter_expire(void);

bool gw_adapter_protocol_owned(const uint8_t addr[6]);

// 返回 V1 稳定错误码，调用者发送响应后按 restarting 标记安排重启
int gw_manager_manage(const cJSON *data, cJSON **result, const char **error);
int gw_adapter_config(const cJSON *config, cJSON **result, const char **error);
