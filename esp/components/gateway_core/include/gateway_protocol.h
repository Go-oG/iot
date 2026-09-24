#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "cJSON.h"
#include "esp_http_server.h"

// 协议层与管理层共用同一版本号，避免 hello 与 diagnostics 上报不一致
#define GW_FIRMWARE_VERSION "0.7.0"

#define GW_V1_MAX_FRAME 65536
#define GW_V1_MAX_GATT_OPS 4

void gw_protocol_init(const char *gateway_id);
void gw_protocol_receive(const char *text, int len, int route);
bool gw_protocol_event(const cJSON *event);
void gw_protocol_tick(void);
void gw_protocol_online(void);
void gw_protocol_http_register(httpd_handle_t server);
void gw_http_api_register(httpd_handle_t server);
bool gw_protocol_owns(const uint8_t addr[6]);
int64_t gw_protocol_timestamp(void);
cJSON *gw_protocol_response(const cJSON *request, int code);
const char *gw_protocol_error_text(int code);
cJSON *gw_protocol_snapshot(void);

// 返回稳定协议错误码，pending 表示需要等待蓝牙完成回调
int gw_protocol_ble_start(const cJSON *request, const uint8_t addr[6], uint8_t addr_type,
                          uint16_t *handle, bool *pending, int *native_code);
bool gw_protocol_publish(cJSON *frame, int qos);

bool gw_protocol_gatt_available(void);
unsigned gw_protocol_managed_gatt_count(void);
