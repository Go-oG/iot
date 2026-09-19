/*
 * ESP32-C5 通用 BLE 远程网关，使用 ESP-IDF 6.1 与 Bluedroid BLE
 * 仅处理传输元数据，设备原始数据通过 MQTT 透明转发
 *
 * MQTT 主题
 *   iot/v1/<gateway-id>/down      V1 请求帧
 *   iot/v1/<gateway-id>/up        V1 响应与事件帧
 *   iot/v1/<gateway-id>/presence  保留状态与遗嘱消息
 *
 * Wi-Fi 与 MQTT 参数通过本地配置页面保存到 NVS
 * ESP32-C5 不支持经典蓝牙
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <stdatomic.h>

#include "sdkconfig.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"

#include "esp_log.h"
#include "esp_err.h"
#include "esp_system.h"
#include "esp_heap_caps.h"
#include "esp_psram.h"
#include "esp_flash.h"
#include "esp_mac.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_timer.h"
#include "esp_crt_bundle.h"
#include "esp_http_server.h"
#include "driver/gpio.h"
#include "nvs.h"

#include "nvs_flash.h"
#include "mqtt_client.h"
#include "cJSON.h"
#include "gateway_manager.h"
#include "gateway_core.h"
#include "gateway_protocol.h"
#include "esp_sntp.h"
#include "mdns.h"

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gattc_api.h"
#include "esp_gatt_common_api.h"
#include "esp_gatt_defs.h"

// ============================================================================
// Generic runtime configuration
// ============================================================================

#define GW_DEVICE_NAME        "ESP32-C5-BT-Gateway"

// Configuration portal. On first boot / after 30 s Wi-Fi failure / when BOOT is held for 3 s:
//   SSID: BTGW-XXXXXX
//   Password: btgw-xxxxxx (derived from the AP MAC suffix)
//   URL: http://192.168.4.1/
#define GW_CONFIG_AP_PREFIX      "BTGW-"
#define GW_CONFIG_AP_PASSWORD_PREFIX "btgw-"
#define GW_CONFIG_BUTTON_GPIO    CONFIG_GW_CONFIG_BUTTON_GPIO
#define GW_CONFIG_BUTTON_HOLD_MS 3000
#define GW_WIFI_CONNECT_TIMEOUT_MS 30000

#define GW_NVS_NAMESPACE      "btgw_cfg"
#define GW_MAX_BLE_CONNECTIONS  32
#define GW_MAX_CLASSIC_CONNECTIONS 0
#define GW_MAX_SPP_CONNECTIONS     0

// 控制器、协议栈和应用连接池必须同时配置为至少 32 条 BLE 连接
#if !defined(CONFIG_IDF_TARGET_ESP32C5)
#error "This gateway requires ESP32-C5"
#endif
#if !defined(CONFIG_BT_BLUEDROID_ENABLED) || !defined(CONFIG_BT_CONTROLLER_ENABLED) || !defined(CONFIG_BT_BLE_ENABLED)
#error "Enable the Bluetooth controller and Bluedroid BLE host"
#endif
#if !defined(CONFIG_BT_GATTC_ENABLE) || !defined(CONFIG_BT_BLE_42_SCAN_EN) || defined(CONFIG_BT_BLE_50_FEATURES_SUPPORTED)
#error "Enable GATTC and BLE 4.2 scanning; disable BLE 5.0 features"
#endif
#if CONFIG_BT_LE_MAX_CONNECTIONS < GW_MAX_BLE_CONNECTIONS
#error "Set CONFIG_BT_LE_MAX_CONNECTIONS to at least 32"
#endif
#if CONFIG_BT_ACL_CONNECTIONS < GW_MAX_BLE_CONNECTIONS
#error "Set CONFIG_BT_ACL_CONNECTIONS to at least 32"
#endif
#if !defined(CONFIG_BT_MULTI_CONNECTION_ENBALE)
#error "Enable CONFIG_BT_MULTI_CONNECTION_ENBALE"
#endif
#if CONFIG_BT_GATTC_NOTIF_REG_MAX < GW_MAX_BLE_CONNECTIONS
#error "Set CONFIG_BT_GATTC_NOTIF_REG_MAX to at least 32"
#endif
#define GW_MQTT_OUTBOX_MAX_BYTES (256 * 1024)
#define GW_MQTT_OUTBOX_RESPONSE_RESERVE (8 * 1024)
#define GW_TOPIC_MAX             128
#define GW_HEX_MAX_BYTES         2048

#define GW_WIFI_SSID_MAX         32
#define GW_WIFI_PASS_MAX         64
#define GW_MQTT_URI_MAX          191
#define GW_MQTT_USER_MAX         63
#define GW_MQTT_PASS_MAX         127
#define GW_GATEWAY_ID_MAX        31

typedef struct {
    bool configured;
    char wifi_ssid[GW_WIFI_SSID_MAX + 1];
    char wifi_password[GW_WIFI_PASS_MAX + 1];
    char mqtt_uri[GW_MQTT_URI_MAX + 1];
    char mqtt_username[GW_MQTT_USER_MAX + 1];
    char mqtt_password[GW_MQTT_PASS_MAX + 1];
    char gateway_id[GW_GATEWAY_ID_MAX + 1];
} gateway_config_t;

// ============================================================================
// Globals
// ============================================================================

static const char *TAG = "btgw";

// 同时记录内部内存和最大连续块，区分容量不足与碎片化
static void log_network_memory(const char *stage) {
    ESP_LOGI(TAG, "%s: internal=%u largest=%u dma=%u psram=%u", stage,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
}
static gateway_config_t g_config;
static char g_config_ap_ssid[33];
static char g_config_ap_password[16];
static httpd_handle_t g_config_httpd = NULL;
static EventGroupHandle_t g_runtime_events;
static const EventBits_t WIFI_CONNECTED_BIT = BIT0;
static const EventBits_t MQTT_CONNECTED_BIT = BIT1;
static esp_mqtt_client_handle_t g_mqtt = NULL;

static char g_topic_v1_down[GW_TOPIC_MAX];
static char g_topic_v1_up[GW_TOPIC_MAX];
static atomic_uint g_v1_scan_duration;
static char g_topic_status[GW_TOPIC_MAX];

static atomic_int g_gattc_if = ESP_GATT_IF_NONE;
static atomic_bool g_ble_scan_params_ready = false;
static atomic_bool g_ble_scanning = false;

// ============================================================================
// Connection state
// ============================================================================

typedef struct {
    bool used;
    bool connected;
    bool services_ready;
    bool cancel_requested;
    int64_t started_ms;
    bool managed_cccd;
    int64_t cccd_started_ms;
    esp_bd_addr_t addr;
    esp_ble_addr_type_t addr_type;
    uint16_t conn_id;
    uint16_t mtu;

    bool cccd_pending;
    bool cccd_unsubscribe;
    uint16_t pending_char_handle;
    uint16_t pending_cccd_handle;
    uint16_t pending_cccd_value;
    char pending_service[37];
    char pending_characteristic[37];
    bool pending_latest;
} ble_conn_t;

static ble_conn_t g_ble[GW_MAX_BLE_CONNECTIONS];

// 临界区只保护连接状态，蓝牙 API、内存分配和 MQTT 发布均在临界区外执行
static portMUX_TYPE g_connection_lock = portMUX_INITIALIZER_UNLOCKED;

// ============================================================================
// Persistent configuration + local configuration web portal
// ============================================================================

static void config_make_default_gateway_id(char out[GW_GATEWAY_ID_MAX + 1]) {
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(out, GW_GATEWAY_ID_MAX + 1, "btgw-%02X%02X%02X", mac[3], mac[4], mac[5]);
}

static void config_defaults(gateway_config_t *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    config_make_default_gateway_id(cfg->gateway_id);
}

static bool gateway_id_valid(const char *s) {
    if (!s || !*s || strlen(s) > GW_GATEWAY_ID_MAX) return false;
    for (const char *p = s; *p; ++p) {
        if (!(isalnum((unsigned char)*p) || *p == '-' || *p == '_')) return false;
    }
    return true;
}

static bool mqtt_uri_valid(const char *s) {
    if (!s) return false;
    if (strncmp(s, "mqtt://", 7) == 0) return strlen(s) > 7;
    if (strncmp(s, "mqtts://", 8) == 0) return strlen(s) > 8;
    return false;
}

static void nvs_get_string_or_empty(nvs_handle_t nvs, const char *key, char *out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = '\0';
    size_t len = cap;
    if (nvs_get_str(nvs, key, out, &len) != ESP_OK) out[0] = '\0';
    out[cap - 1] = '\0';
}

static bool config_load(gateway_config_t *cfg) {
    config_defaults(cfg);
    nvs_handle_t nvs;
    if (nvs_open(GW_NVS_NAMESPACE, NVS_READONLY, &nvs) != ESP_OK) return false;

    uint8_t ready = 0;
    nvs_get_u8(nvs, "ready", &ready);
    if (ready == 1) {
        nvs_get_string_or_empty(nvs, "wifi_ssid", cfg->wifi_ssid, sizeof(cfg->wifi_ssid));
        nvs_get_string_or_empty(nvs, "wifi_pass", cfg->wifi_password, sizeof(cfg->wifi_password));
        nvs_get_string_or_empty(nvs, "mqtt_uri", cfg->mqtt_uri, sizeof(cfg->mqtt_uri));
        nvs_get_string_or_empty(nvs, "mqtt_user", cfg->mqtt_username, sizeof(cfg->mqtt_username));
        nvs_get_string_or_empty(nvs, "mqtt_pass", cfg->mqtt_password, sizeof(cfg->mqtt_password));
        nvs_get_string_or_empty(nvs, "gateway_id", cfg->gateway_id, sizeof(cfg->gateway_id));
        cfg->configured = cfg->wifi_ssid[0] != '\0' && mqtt_uri_valid(cfg->mqtt_uri) && gateway_id_valid(cfg->gateway_id);
    }
    nvs_close(nvs);
    return cfg->configured;
}

static esp_err_t config_save(const gateway_config_t *cfg) {
    nvs_handle_t nvs;
    esp_err_t err = nvs_open(GW_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) return err;

    if ((err = nvs_set_str(nvs, "wifi_ssid", cfg->wifi_ssid)) != ESP_OK) goto done;
    if ((err = nvs_set_str(nvs, "wifi_pass", cfg->wifi_password)) != ESP_OK) goto done;
    if ((err = nvs_set_str(nvs, "mqtt_uri", cfg->mqtt_uri)) != ESP_OK) goto done;
    if ((err = nvs_set_str(nvs, "mqtt_user", cfg->mqtt_username)) != ESP_OK) goto done;
    if ((err = nvs_set_str(nvs, "mqtt_pass", cfg->mqtt_password)) != ESP_OK) goto done;
    if ((err = nvs_set_str(nvs, "gateway_id", cfg->gateway_id)) != ESP_OK) goto done;
    if ((err = nvs_set_u8(nvs, "ready", 1)) != ESP_OK) goto done;
    err = nvs_commit(nvs);

done:
    nvs_close(nvs);
    return err;
}

static void build_topics(void) {
    snprintf(g_topic_status, sizeof(g_topic_status), "iot/v1/%s/presence", g_config.gateway_id);
    snprintf(g_topic_v1_down, sizeof(g_topic_v1_down), "iot/v1/%s/down", g_config.gateway_id);
    snprintf(g_topic_v1_up, sizeof(g_topic_v1_up), "iot/v1/%s/up", g_config.gateway_id);
}

static void delayed_restart_task(void *arg) {
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();
}

static const char CONFIG_PAGE[] =
"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
"<title>Bluetooth Gateway</title><style>body{font-family:system-ui;margin:0;background:#f4f6f8;color:#17202a}"
"main{max-width:620px;margin:24px auto;padding:20px}section{background:white;border-radius:14px;padding:22px;box-shadow:0 2px 14px #0001}"
"h2{margin-top:0}label{display:block;margin:14px 0 5px;font-weight:600}input{box-sizing:border-box;width:100%;padding:11px;border:1px solid #ccd2d8;border-radius:8px;font-size:16px}"
"button{margin-top:20px;width:100%;padding:12px;border:0;border-radius:9px;background:#17202a;color:white;font-size:16px}"
"small{color:#667085}.row{display:flex;align-items:center;gap:8px;margin-top:8px}.row input{width:auto}#msg{margin-top:14px;white-space:pre-wrap}</style></head>"
"<body><main><section><a href='/'>返回设备管理</a><h2>ESP32-C5 Bluetooth Gateway</h2><small>配置 Wi-Fi 与 MQTT。保存后设备会自动重启。</small>"
"<label>Wi-Fi SSID</label><input id='ssid' maxlength='32'>"
"<label>Wi-Fi 密码</label><input id='wpass' type='password' maxlength='64' placeholder='留空保留现有密码'>"
"<div class='row'><input id='wclear' type='checkbox'><span>清空 Wi-Fi 密码（开放网络）</span></div>"
"<label>MQTT URI</label><input id='uri' maxlength='191' placeholder='mqtts://broker.example.com:8883'>"
"<label>MQTT 用户名</label><input id='user' maxlength='63'>"
"<label>MQTT 密码</label><input id='mpass' type='password' maxlength='127' placeholder='留空保留现有密码'>"
"<div class='row'><input id='mclear' type='checkbox'><span>清空 MQTT 密码</span></div>"
"<label>Gateway ID</label><input id='gid' maxlength='31'><small>仅允许字母、数字、-、_；它会出现在 MQTT Topic 中。</small>"
"<button onclick='saveCfg()'>保存并重启</button><div id='msg'></div></section></main>"
"<script>let current={};async function load(){current=await (await fetch('/api/config')).json();"
"ssid.value=current.wifiSsid||'';uri.value=current.mqttUri||'';user.value=current.mqttUsername||'';gid.value=current.gatewayId||'';}"
"async function saveCfg(){msg.textContent='正在保存...';let b={wifiSsid:ssid.value,wifiPassword:wpass.value,keepWifiPassword:!!current.wifiPasswordSet&&!wpass.value&&!wclear.checked,clearWifiPassword:wclear.checked,mqttUri:uri.value,mqttUsername:user.value,mqttPassword:mpass.value,keepMqttPassword:!!current.mqttPasswordSet&&!mpass.value&&!mclear.checked,clearMqttPassword:mclear.checked,gatewayId:gid.value};"
"let r=await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});let j=await r.json();msg.textContent=j.ok?'保存成功，设备正在重启。':('保存失败：'+(j.error||r.status));}load();</script></body></html>";

static esp_err_t config_page_get(httpd_req_t *req) {
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, CONFIG_PAGE, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t config_api_get(httpd_req_t *req) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "configured", g_config.configured);
    cJSON_AddStringToObject(o, "wifiSsid", g_config.wifi_ssid);
    cJSON_AddBoolToObject(o, "wifiPasswordSet", g_config.wifi_password[0] != '\0');
    cJSON_AddStringToObject(o, "mqttUri", g_config.mqtt_uri);
    cJSON_AddStringToObject(o, "mqttUsername", g_config.mqtt_username);
    cJSON_AddBoolToObject(o, "mqttPasswordSet", g_config.mqtt_password[0] != '\0');
    cJSON_AddStringToObject(o, "gatewayId", g_config.gateway_id);
    char *json = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    if (!json) return ESP_ERR_NO_MEM;
    httpd_resp_set_type(req, "application/json");
    esp_err_t err = httpd_resp_sendstr(req, json);
    cJSON_free(json);
    return err;
}

static void config_http_error(httpd_req_t *req, const char *status, const char *error) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", false);
    cJSON_AddStringToObject(o, "error", error);
    char *json = cJSON_PrintUnformatted(o);
    cJSON_Delete(o);
    httpd_resp_set_status(req, "400 Bad Request");
    httpd_resp_set_type(req, "application/json");
    if (json) {
        httpd_resp_sendstr(req, json);
        cJSON_free(json);
    } else {
        httpd_resp_sendstr(req, "{\"ok\":false}");
    }
}

static bool json_copy_string(cJSON *root, const char *key, char *dst, size_t cap, bool required) {
    cJSON *v = cJSON_GetObjectItemCaseSensitive(root, key);
    if (!cJSON_IsString(v)) return !required;
    size_t n = strlen(v->valuestring);
    if (n >= cap) return false;
    strlcpy(dst, v->valuestring, cap);
    return true;
}

static bool json_bool_value(cJSON *root, const char *key) {
    return cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(root, key));
}

static esp_err_t config_api_post(httpd_req_t *req) {
    // 写配置会影响 Wi-Fi 与 MQTT，只接受同源页面提交的 JSON
    if (!gw_http_json_post_allowed(req)) {
        config_http_error(req, "403 Forbidden", "cross_origin_denied");
        return ESP_OK;
    }
    if (req->content_len <= 0 || req->content_len > 2048) {
        config_http_error(req, "400 Bad Request", "invalid_body_size");
        return ESP_OK;
    }

    char *body = malloc((size_t)req->content_len + 1);
    if (!body) return ESP_ERR_NO_MEM;
    int received = 0;
    while (received < req->content_len) {
        int n = httpd_req_recv(req, body + received, req->content_len - received);
        if (n <= 0) {
            free(body);
            config_http_error(req, "400 Bad Request", "receive_failed");
            return ESP_OK;
        }
        received += n;
    }
    body[received] = '\0';

    cJSON *root = cJSON_Parse(body);
    free(body);
    if (!root) {
        config_http_error(req, "400 Bad Request", "invalid_json");
        return ESP_OK;
    }

    gateway_config_t next = g_config;
    next.configured = true;

    if (!json_copy_string(root, "wifiSsid", next.wifi_ssid, sizeof(next.wifi_ssid), true) || next.wifi_ssid[0] == '\0') {
        cJSON_Delete(root); config_http_error(req, "400 Bad Request", "invalid_wifi_ssid"); return ESP_OK;
    }
    if (!json_copy_string(root, "mqttUri", next.mqtt_uri, sizeof(next.mqtt_uri), true) || !mqtt_uri_valid(next.mqtt_uri)) {
        cJSON_Delete(root); config_http_error(req, "400 Bad Request", "invalid_mqtt_uri"); return ESP_OK;
    }
    if (!json_copy_string(root, "mqttUsername", next.mqtt_username, sizeof(next.mqtt_username), false)) {
        cJSON_Delete(root); config_http_error(req, "400 Bad Request", "invalid_mqtt_username"); return ESP_OK;
    }
    if (!json_copy_string(root, "gatewayId", next.gateway_id, sizeof(next.gateway_id), true) || !gateway_id_valid(next.gateway_id)) {
        cJSON_Delete(root); config_http_error(req, "400 Bad Request", "invalid_gateway_id"); return ESP_OK;
    }
    if (json_bool_value(root, "clearWifiPassword")) {
        next.wifi_password[0] = '\0';
    } else if (!json_bool_value(root, "keepWifiPassword")) {
        if (!json_copy_string(root, "wifiPassword", next.wifi_password, sizeof(next.wifi_password), false)) {
            cJSON_Delete(root); config_http_error(req, "400 Bad Request", "invalid_wifi_password"); return ESP_OK;
        }
    }

    if (json_bool_value(root, "clearMqttPassword")) {
        next.mqtt_password[0] = '\0';
    } else if (!json_bool_value(root, "keepMqttPassword")) {
        if (!json_copy_string(root, "mqttPassword", next.mqtt_password, sizeof(next.mqtt_password), false)) {
            cJSON_Delete(root); config_http_error(req, "400 Bad Request", "invalid_mqtt_password"); return ESP_OK;
        }
    }

    // ESP-IDF accepts an empty password for open Wi-Fi. WPA/WPA2/WPA3 PSKs must be >= 8 chars.
    if (next.wifi_password[0] != '\0' && strlen(next.wifi_password) < 8) {
        cJSON_Delete(root); config_http_error(req, "400 Bad Request", "wifi_password_must_be_empty_or_8_plus"); return ESP_OK;
    }
    cJSON_Delete(root);

    esp_err_t err = config_save(&next);
    if (err != ESP_OK) {
        config_http_error(req, "400 Bad Request", esp_err_to_name(err));
        return ESP_OK;
    }
    g_config = next;

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    if (xTaskCreate(delayed_restart_task, "cfg_restart", 2048, NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "Failed to create configuration restart task");
        esp_restart();
    }
    return ESP_OK;
}


// MQTT 网络配置只保存到 NVS，当前路由一直保留到重启
int gw_adapter_config(const cJSON *config, cJSON **result, const char **error) {
    if (!config) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "configured", g_config.configured);
    cJSON_AddStringToObject(o, "wifiSsid", g_config.wifi_ssid);
    cJSON_AddBoolToObject(o, "wifiPasswordSet", g_config.wifi_password[0] != '\0');
    cJSON_AddStringToObject(o, "mqttUri", g_config.mqtt_uri);
    cJSON_AddStringToObject(o, "mqttUsername", g_config.mqtt_username);
    cJSON_AddBoolToObject(o, "mqttPasswordSet", g_config.mqtt_password[0] != '\0');
    cJSON_AddStringToObject(o, "gatewayId", g_config.gateway_id);
        *result = o;
        return o ? 0 : 2001;
    }
    cJSON *root = (cJSON *)config;
    const char *strings[] = {"wifiSsid", "wifiPassword", "mqttUri", "mqttUsername", "mqttPassword", "gatewayId"};
    for (unsigned i = 0; i < sizeof(strings) / sizeof(strings[0]); ++i) {
        const cJSON *v = cJSON_GetObjectItemCaseSensitive(root, strings[i]);
        if (v && !cJSON_IsString(v)) { *error = "invalid_string_field"; return 1003; }
    }
    const char *flags[] = {"keepWifiPassword", "keepMqttPassword", "clearWifiPassword", "clearMqttPassword"};
    for (unsigned i = 0; i < sizeof(flags) / sizeof(flags[0]); ++i) {
        const cJSON *v = cJSON_GetObjectItemCaseSensitive(root, flags[i]);
        if (v && !cJSON_IsBool(v)) { *error = "invalid_boolean_field"; return 1003; }
    }
    gateway_config_t next = g_config;
    next.configured = true;

    if (!json_copy_string(root, "wifiSsid", next.wifi_ssid, sizeof(next.wifi_ssid), true) || next.wifi_ssid[0] == '\0') {
        *error = "invalid_wifi_ssid"; return 1003;
    }
    if (!json_copy_string(root, "mqttUri", next.mqtt_uri, sizeof(next.mqtt_uri), true) || !mqtt_uri_valid(next.mqtt_uri)) {
        *error = "invalid_mqtt_uri"; return 1003;
    }
    if (!json_copy_string(root, "mqttUsername", next.mqtt_username, sizeof(next.mqtt_username), false)) {
        *error = "invalid_mqtt_username"; return 1003;
    }
    if (!json_copy_string(root, "gatewayId", next.gateway_id, sizeof(next.gateway_id), true) || !gateway_id_valid(next.gateway_id)) {
        *error = "invalid_gateway_id"; return 1003;
    }
    if (json_bool_value(root, "clearWifiPassword")) {
        next.wifi_password[0] = '\0';
    } else if (!json_bool_value(root, "keepWifiPassword")) {
        if (!json_copy_string(root, "wifiPassword", next.wifi_password, sizeof(next.wifi_password), false)) {
            *error = "invalid_wifi_password"; return 1003;
        }
    }

    if (json_bool_value(root, "clearMqttPassword")) {
        next.mqtt_password[0] = '\0';
    } else if (!json_bool_value(root, "keepMqttPassword")) {
        if (!json_copy_string(root, "mqttPassword", next.mqtt_password, sizeof(next.mqtt_password), false)) {
            *error = "invalid_mqtt_password"; return 1003;
        }
    }

    // 开放网络允许空密码，其他 Wi-Fi 密码至少八字节
    if (next.wifi_password[0] != '\0' && strlen(next.wifi_password) < 8) {
        *error = "wifi_password_must_be_empty_or_8_plus"; return 1003;
    }

    esp_err_t err = config_save(&next);
    if (err != ESP_OK) {
        *error = esp_err_to_name(err);
        return 2001;
    }
    *result = cJSON_CreateObject();
    return 0;
}

static void config_http_start(void) {
    if (g_config_httpd) return;
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.max_uri_handlers = 12;
    cfg.stack_size = 8192;
    ESP_ERROR_CHECK(httpd_start(&g_config_httpd, &cfg));

    const httpd_uri_t root = {.uri = "/config", .method = HTTP_GET, .handler = config_page_get};
    const httpd_uri_t api_get = {.uri = "/api/config", .method = HTTP_GET, .handler = config_api_get};
    const httpd_uri_t api_post = {.uri = "/api/config", .method = HTTP_POST, .handler = config_api_post};
    ESP_ERROR_CHECK(httpd_register_uri_handler(g_config_httpd, &root));
    ESP_ERROR_CHECK(httpd_register_uri_handler(g_config_httpd, &api_get));
    ESP_ERROR_CHECK(httpd_register_uri_handler(g_config_httpd, &api_post));
    gw_manager_http_register(g_config_httpd);
    gw_protocol_http_register(g_config_httpd);
    ESP_LOGI(TAG, "HTTP management server started on port %u", (unsigned)cfg.server_port);
    log_network_memory("HTTP ready");
}

static void config_portal_enable(bool keep_station) {
    log_network_memory("Before config portal");
    wifi_config_t ap = {0};
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    snprintf(g_config_ap_ssid, sizeof(g_config_ap_ssid), "%s%02X%02X%02X",
             GW_CONFIG_AP_PREFIX, mac[3], mac[4], mac[5]);
    snprintf(g_config_ap_password, sizeof(g_config_ap_password), "%s%02x%02x%02x",
             GW_CONFIG_AP_PASSWORD_PREFIX, mac[3], mac[4], mac[5]);

    strlcpy((char *)ap.ap.ssid, g_config_ap_ssid, sizeof(ap.ap.ssid));
    strlcpy((char *)ap.ap.password, g_config_ap_password, sizeof(ap.ap.password));
    ap.ap.ssid_len = (uint8_t)strlen(g_config_ap_ssid);
    ap.ap.channel = 1;
    ap.ap.max_connection = 4;
    ap.ap.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_ERROR_CHECK(esp_wifi_set_mode(keep_station ? WIFI_MODE_APSTA : WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
    config_http_start();
    ESP_LOGW(TAG, "Config portal enabled: SSID=%s password=%s URL=http://192.168.4.1",
             g_config_ap_ssid, g_config_ap_password);
}

static void wifi_config_fallback_task(void *arg) {
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(GW_WIFI_CONNECT_TIMEOUT_MS));
    if ((xEventGroupGetBits(g_runtime_events) & WIFI_CONNECTED_BIT) == 0) {
        ESP_LOGW(TAG, "Wi-Fi not connected after %d ms; enabling configuration portal", GW_WIFI_CONNECT_TIMEOUT_MS);
        config_portal_enable(true);
    }
    vTaskDelete(NULL);
}

static void config_button_task(void *arg) {
    (void)arg;
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << GW_CONFIG_BUTTON_GPIO,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    if (gpio_config(&io) != ESP_OK) {
        ESP_LOGW(TAG, "Cannot configure config button GPIO %d", GW_CONFIG_BUTTON_GPIO);
        vTaskDelete(NULL);
        return;
    }

    int held_ms = 0;
    bool fired = false;
    while (true) {
        if (gpio_get_level(GW_CONFIG_BUTTON_GPIO) == 0) {
            held_ms += 100;
            if (!fired && held_ms >= GW_CONFIG_BUTTON_HOLD_MS) {
                fired = true;
                ESP_LOGW(TAG, "BOOT held for %d ms; enabling configuration portal", GW_CONFIG_BUTTON_HOLD_MS);
                config_portal_enable(g_config.configured);
            }
        } else {
            held_ms = 0;
            fired = false;
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

// ============================================================================
// Utility
// ============================================================================

static bool bda_equal(const esp_bd_addr_t a, const esp_bd_addr_t b) {
    return memcmp(a, b, ESP_BD_ADDR_LEN) == 0;
}

static void bda_to_string(const esp_bd_addr_t bda, char out[18]) {
    snprintf(out, 18, "%02X:%02X:%02X:%02X:%02X:%02X",
             bda[0], bda[1], bda[2], bda[3], bda[4], bda[5]);
}

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    c = (char)tolower((unsigned char)c);
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static uint8_t *hex_decode(const char *hex, size_t *out_len) {
    *out_len = 0;
    if (!hex) return NULL;

    size_t n = strlen(hex);
    if (n == 0 || (n & 1) != 0 || n / 2 > GW_HEX_MAX_BYTES) return NULL;

    uint8_t *buf = malloc(n / 2);
    if (!buf) return NULL;

    for (size_t i = 0; i < n; i += 2) {
        int hi = hex_nibble(hex[i]);
        int lo = hex_nibble(hex[i + 1]);
        if (hi < 0 || lo < 0) {
            free(buf);
            return NULL;
        }
        buf[i / 2] = (uint8_t)((hi << 4) | lo);
    }
    *out_len = n / 2;
    return buf;
}

static char *hex_encode(const uint8_t *data, size_t len) {
    static const char *HEX = "0123456789ABCDEF";
    if ((!data && len != 0) || len > (SIZE_MAX - 1) / 2) return NULL;
    char *out = malloc(len * 2 + 1);
    if (!out) return NULL;
    for (size_t i = 0; i < len; ++i) {
        out[i * 2] = HEX[data[i] >> 4];
        out[i * 2 + 1] = HEX[data[i] & 0x0F];
    }
    out[len * 2] = '\0';
    return out;
}

static bool uuid_parse(const char *s, esp_bt_uuid_t *uuid) {
    if (!s || !uuid) return false;

    char compact[33] = {0};
    size_t j = 0;
    for (size_t i = 0; s[i] != '\0'; ++i) {
        if (s[i] == '-') continue;
        if (!isxdigit((unsigned char)s[i]) || j >= sizeof(compact) - 1) return false;
        compact[j++] = s[i];
    }
    compact[j] = '\0';

    memset(uuid, 0, sizeof(*uuid));
    if (j == 4) {
        uuid->len = ESP_UUID_LEN_16;
        unsigned int v = 0;
        if (sscanf(compact, "%4x", &v) != 1) return false;
        uuid->uuid.uuid16 = (uint16_t)v;
        return true;
    }
    if (j == 8) {
        uuid->len = ESP_UUID_LEN_32;
        unsigned long v = 0;
        if (sscanf(compact, "%8lx", &v) != 1) return false;
        uuid->uuid.uuid32 = (uint32_t)v;
        return true;
    }
    if (j == 32) {
        uuid->len = ESP_UUID_LEN_128;
        uint8_t normal[16];
        for (int i = 0; i < 16; ++i) {
            int hi = hex_nibble(compact[i * 2]);
            int lo = hex_nibble(compact[i * 2 + 1]);
            if (hi < 0 || lo < 0) return false;
            normal[i] = (uint8_t)((hi << 4) | lo);
        }
        // Bluedroid stores 128-bit UUID byte arrays little-endian.
        for (int i = 0; i < 16; ++i) uuid->uuid.uuid128[i] = normal[15 - i];
        return true;
    }
    return false;
}

static bool mqtt_output_available(int qos) {
    if (!g_mqtt || !g_runtime_events ||
        (xEventGroupGetBits(g_runtime_events) & MQTT_CONNECTED_BIT) == 0) return false;
    return qos != 0 || esp_mqtt_client_get_outbox_size(g_mqtt) <
                          GW_MQTT_OUTBOX_MAX_BYTES - GW_MQTT_OUTBOX_RESPONSE_RESERVE;
}

static bool mqtt_publish_json(const char *topic, cJSON *obj, int qos, bool retain) {
    if (!obj || !mqtt_output_available(qos)) return false;
    char *s = cJSON_PrintUnformatted(obj);
    if (!s) return false;
    int result = esp_mqtt_client_enqueue(g_mqtt, topic, s, (int)strlen(s), qos, retain, true);
    cJSON_free(s);
    return result >= 0;
}

static cJSON *event_base(const char *type) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddStringToObject(o, "type", type);
    cJSON_AddNumberToObject(o, "ts", (double)(esp_timer_get_time() / 1000));
    return o;
}

static void publish_event(cJSON *obj) {
    gw_protocol_event(obj);
    cJSON_Delete(obj);
}

static void publish_status(bool online) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "online", online);
    int64_t ts = gw_protocol_timestamp();
    cJSON_AddNumberToObject(o, "ts", (double)ts);
    cJSON_AddStringToObject(o, "gateway", g_config.gateway_id);
    cJSON_AddStringToObject(o, "firmware", GW_FIRMWARE_VERSION);
    if (online) {
        cJSON_AddBoolToObject(o, "ble", true);
        cJSON_AddBoolToObject(o, "classic", false);
    }
    mqtt_publish_json(g_topic_status, o, 1, true);
    cJSON_Delete(o);
}

// 连接池查找和分配函数由持有连接锁的调用方使用
static ble_conn_t *ble_find_by_addr(const esp_bd_addr_t addr) {
    for (int i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) {
        if (g_ble[i].used && bda_equal(g_ble[i].addr, addr)) return &g_ble[i];
    }
    return NULL;
}

static ble_conn_t *ble_find_by_conn_id(uint16_t conn_id) {
    for (int i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) {
        if (g_ble[i].used && g_ble[i].connected && g_ble[i].conn_id == conn_id) return &g_ble[i];
    }
    return NULL;
}

static ble_conn_t *ble_alloc(const esp_bd_addr_t addr, esp_ble_addr_type_t type) {
    ble_conn_t *e = ble_find_by_addr(addr);
    if (e) return e;
    for (int i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) {
        if (!g_ble[i].used) {
            memset(&g_ble[i], 0, sizeof(g_ble[i]));
            g_ble[i].used = true;
            g_ble[i].started_ms = esp_timer_get_time() / 1000;
            g_ble[i].addr_type = type;
            memcpy(g_ble[i].addr, addr, ESP_BD_ADDR_LEN);
            return &g_ble[i];
        }
    }
    return NULL;
}

static void ble_release(ble_conn_t *e) {
    if (e) memset(e, 0, sizeof(*e));
}

static bool ble_snapshot_by_addr(const esp_bd_addr_t addr, ble_conn_t *out) {
    portENTER_CRITICAL(&g_connection_lock);
    ble_conn_t *e = ble_find_by_addr(addr);
    if (e) *out = *e;
    portEXIT_CRITICAL(&g_connection_lock);
    return e != NULL;
}

static bool ble_snapshot_by_conn_id(uint16_t conn_id, ble_conn_t *out) {
    portENTER_CRITICAL(&g_connection_lock);
    ble_conn_t *e = ble_find_by_conn_id(conn_id);
    if (e) *out = *e;
    portEXIT_CRITICAL(&g_connection_lock);
    return e != NULL;
}

static bool ble_begin_cccd_operation(const ble_conn_t *conn, uint16_t char_handle,
                                     uint16_t cccd_handle, uint16_t value, bool unsubscribe, bool managed) {
    bool accepted = false;
    portENTER_CRITICAL(&g_connection_lock);
    ble_conn_t *e = ble_find_by_conn_id(conn->conn_id);
    bool busy = false;
    // 注册回调不携带连接标识，继续串行处理订阅以避免相同句柄串台
    for (int i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) {
        if (g_ble[i].used && g_ble[i].cccd_pending) busy = true;
    }
    if (e && bda_equal(e->addr, conn->addr) && !busy) {
        e->cccd_pending = true;
        e->managed_cccd = managed;
        e->cccd_started_ms = esp_timer_get_time() / 1000;
        e->cccd_unsubscribe = unsubscribe;
        e->pending_char_handle = char_handle;
        e->pending_cccd_handle = cccd_handle;
        e->pending_cccd_value = value;
        accepted = true;
    }
    portEXIT_CRITICAL(&g_connection_lock);
    return accepted;
}

static void ble_finish_cccd_operation(uint16_t conn_id, uint16_t cccd_handle,
                                      esp_gatt_status_t status) {
    ble_conn_t snapshot;
    bool found = false;
    portENTER_CRITICAL(&g_connection_lock);
    ble_conn_t *e = ble_find_by_conn_id(conn_id);
    if (e && e->cccd_pending && e->pending_cccd_handle == cccd_handle) {
        snapshot = *e;
        e->cccd_pending = false;
        found = true;
    }
    portEXIT_CRITICAL(&g_connection_lock);
    if (!found) return;
    if (snapshot.managed_cccd) gw_manager_subscription(snapshot.addr, status);

    cJSON *o = event_base(snapshot.cccd_unsubscribe ? "ble.unsubscribe_result" : "ble.subscribe_result");
    char addr[18];
    bda_to_string(snapshot.addr, addr);
    cJSON_AddStringToObject(o, "device", addr);
    cJSON_AddNumberToObject(o, "handle", snapshot.pending_char_handle);
    cJSON_AddNumberToObject(o, "status", status);
    if (snapshot.managed_cccd) {
        cJSON_AddStringToObject(o, "service", snapshot.pending_service);
        cJSON_AddStringToObject(o, "char", snapshot.pending_characteristic);
        cJSON_AddBoolToObject(o, "latest", snapshot.pending_latest);
    }
    publish_event(o);
}

static void ble_notify_registration_done(esp_gatt_if_t gattc_if, uint16_t char_handle,
                                         esp_gatt_status_t status, bool unsubscribe) {
    ble_conn_t snapshot;
    bool found = false;
    portENTER_CRITICAL(&g_connection_lock);
    for (int i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) {
        ble_conn_t *e = &g_ble[i];
        if (e->used && e->connected && e->cccd_pending &&
            e->cccd_unsubscribe == unsubscribe && e->pending_char_handle == char_handle) {
            snapshot = *e;
            found = true;
            break;
        }
    }
    portEXIT_CRITICAL(&g_connection_lock);
    if (!found) return;

    if (status == ESP_GATT_OK) {
        uint8_t value[2] = {(uint8_t)snapshot.pending_cccd_value,
                            (uint8_t)(snapshot.pending_cccd_value >> 8)};
        esp_err_t err = esp_ble_gattc_write_char_descr(
            gattc_if, snapshot.conn_id, snapshot.pending_cccd_handle,
            sizeof(value), value, ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE);
        if (err == ESP_OK) return;
        status = ESP_GATT_ERROR;
    }
    ble_finish_cccd_operation(snapshot.conn_id, snapshot.pending_cccd_handle, status);
}

// ============================================================================
// BLE GATT lookup / discovery serialization
// ============================================================================

static bool ble_resolve_char(ble_conn_t *conn,
                             const char *service_uuid_s,
                             const char *char_uuid_s,
                             esp_gattc_service_elem_t *service,
                             esp_gattc_char_elem_t *ch) {
    if (!conn || !conn->connected || !conn->services_ready) return false;

    esp_bt_uuid_t service_uuid;
    esp_bt_uuid_t char_uuid;
    if (!uuid_parse(service_uuid_s, &service_uuid) || !uuid_parse(char_uuid_s, &char_uuid)) return false;

    uint16_t service_count = 1;
    if (esp_ble_gattc_get_service(g_gattc_if, conn->conn_id, &service_uuid,
                                  service, &service_count, 0) != ESP_GATT_OK || service_count == 0) {
        return false;
    }

    uint16_t char_count = 1;
    if (esp_ble_gattc_get_char_by_uuid(g_gattc_if, conn->conn_id,
                                       service->start_handle, service->end_handle,
                                       char_uuid, ch, &char_count) != ESP_GATT_OK || char_count == 0) {
        return false;
    }
    return true;
}

// ============================================================================
// BLE callbacks
// ============================================================================

static void ble_gap_cb(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
    switch (event) {
        case ESP_GAP_BLE_SCAN_PARAM_SET_COMPLETE_EVT: {
            g_ble_scan_params_ready = param->scan_param_cmpl.status == ESP_BT_STATUS_SUCCESS;
            unsigned duration = atomic_exchange(&g_v1_scan_duration, 0);
            if (duration && (!g_ble_scan_params_ready || esp_ble_gap_start_scanning(duration) != ESP_OK)) g_ble_scanning = false;
            break;
        }

        case ESP_GAP_BLE_SCAN_START_COMPLETE_EVT:
            if (param->scan_start_cmpl.status != ESP_BT_STATUS_SUCCESS) g_ble_scanning = false;
            break;
        case ESP_GAP_BLE_SCAN_STOP_COMPLETE_EVT:
            if (param->scan_stop_cmpl.status == ESP_BT_STATUS_SUCCESS) g_ble_scanning = false;
            break;
        case ESP_GAP_BLE_READ_RSSI_COMPLETE_EVT: {
            gw_manager_rssi(param->read_rssi_cmpl.remote_addr,
                            param->read_rssi_cmpl.status == ESP_BT_STATUS_SUCCESS ? param->read_rssi_cmpl.rssi : 127);
            if (param->read_rssi_cmpl.status == ESP_BT_STATUS_SUCCESS) {
                cJSON *o = event_base("ble.rssi"); char addr[18]; bda_to_string(param->read_rssi_cmpl.remote_addr, addr);
                cJSON_AddStringToObject(o, "device", addr); cJSON_AddNumberToObject(o, "rssi", param->read_rssi_cmpl.rssi);
                gw_protocol_event(o); cJSON_Delete(o);
            }
            break;
        }
        case ESP_GAP_BLE_UPDATE_CONN_PARAMS_EVT:
            gw_manager_interval(param->update_conn_params.bda, param->update_conn_params.status,
                                param->update_conn_params.conn_int);
            break;
        case ESP_GAP_BLE_SCAN_RESULT_EVT: {
            if (param->scan_rst.search_evt == ESP_GAP_SEARCH_INQ_RES_EVT) {
                size_t len = param->scan_rst.adv_data_len + param->scan_rst.scan_rsp_len;
                if (len > sizeof(param->scan_rst.ble_adv)) len = sizeof(param->scan_rst.ble_adv);
                gw_manager_seen(param->scan_rst.bda, param->scan_rst.ble_addr_type, param->scan_rst.rssi,
                                param->scan_rst.ble_adv, len);
                {
                    cJSON *o = event_base("ble.scan");
                    char addr[18]; bda_to_string(param->scan_rst.bda, addr);
                    cJSON_AddStringToObject(o, "device", addr);
                    cJSON_AddNumberToObject(o, "addressType", param->scan_rst.ble_addr_type);
                    cJSON_AddNumberToObject(o, "rssi", param->scan_rst.rssi);
                    char name[GW_ADV_NAME_MAX];
                    if (gw_adv_local_name(param->scan_rst.ble_adv, len, name, sizeof(name)))
                        cJSON_AddStringToObject(o, "name", name);
                    char *hex = hex_encode(param->scan_rst.ble_adv, len);
                    if (hex) { cJSON_AddStringToObject(o, "advertisement", hex); free(hex); }
                    publish_event(o);
                }
            } else if (param->scan_rst.search_evt == ESP_GAP_SEARCH_INQ_CMPL_EVT) {
                g_ble_scanning = false;
                cJSON *o = event_base("ble.scan_complete");
                publish_event(o);
            }
            break;
        }

        default:
            break;
    }
}

static void ble_gattc_cb(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if,
                         esp_ble_gattc_cb_param_t *param) {
    switch (event) {
        case ESP_GATTC_REG_EVT:
            if (param->reg.status == ESP_GATT_OK) {
                g_gattc_if = gattc_if;
                ESP_LOGI(TAG, "GATTC registered if=%d", gattc_if);
            }
            break;

        case ESP_GATTC_OPEN_EVT: {
            bool accepted = false;
            portENTER_CRITICAL(&g_connection_lock);
            ble_conn_t *e = ble_find_by_addr(param->open.remote_bda);
            if (param->open.status == ESP_GATT_OK) {
                if (e && !e->connected && !e->cancel_requested) {
                    e->connected = true;
                    e->conn_id = param->open.conn_id;
                    e->mtu = param->open.mtu;
                    accepted = true;
                }
            } else if (e && !e->connected) {
                ble_release(e);
            }
            portEXIT_CRITICAL(&g_connection_lock);

            gw_manager_connection(param->open.remote_bda, accepted,
                                  accepted ? 0 : param->open.status ? param->open.status : ESP_ERR_INVALID_STATE);
            cJSON *o = event_base("ble.connection");
            char addr[18];
            bda_to_string(param->open.remote_bda, addr);
            cJSON_AddStringToObject(o, "device", addr);
            cJSON_AddNumberToObject(o, "status", param->open.status);
            cJSON_AddBoolToObject(o, "connected", accepted);
            if (accepted) {
                cJSON_AddNumberToObject(o, "connId", param->open.conn_id);
                cJSON_AddNumberToObject(o, "mtu", param->open.mtu);
                if (esp_ble_gattc_send_mtu_req(gattc_if, param->open.conn_id) != ESP_OK) {
                    esp_ble_gattc_search_service(gattc_if, param->open.conn_id, NULL);
                }
            } else if (param->open.status == ESP_GATT_OK) {
                // 拒绝没有预留名额的连接，避免产生连接池无法管理的链路
                esp_ble_gattc_close(gattc_if, param->open.conn_id);
                portENTER_CRITICAL(&g_connection_lock);
                e = ble_find_by_addr(param->open.remote_bda);
                if (e && !e->connected) ble_release(e);
                portEXIT_CRITICAL(&g_connection_lock);
                cJSON_AddStringToObject(o, "error", "untracked_connection");
            }
            publish_event(o);
            break;
        }

        case ESP_GATTC_CFG_MTU_EVT: {
            portENTER_CRITICAL(&g_connection_lock);
            ble_conn_t *e = ble_find_by_conn_id(param->cfg_mtu.conn_id);
            if (e && param->cfg_mtu.status == ESP_GATT_OK) e->mtu = param->cfg_mtu.mtu;
            portEXIT_CRITICAL(&g_connection_lock);
            // 等待 MTU 交换结束后再发现服务，避免同一 ATT 链路请求重叠
            if (e) esp_ble_gattc_search_service(gattc_if, param->cfg_mtu.conn_id, NULL);
            break;
        }

        case ESP_GATTC_SEARCH_CMPL_EVT: {
            ble_conn_t snapshot;
            portENTER_CRITICAL(&g_connection_lock);
            ble_conn_t *e = ble_find_by_conn_id(param->search_cmpl.conn_id);
            if (e) {
                e->services_ready = param->search_cmpl.status == ESP_GATT_OK;
                snapshot = *e;
            }
            portEXIT_CRITICAL(&g_connection_lock);
            if (e) {
                cJSON *o = event_base("ble.services_ready");
                char addr[18];
                bda_to_string(snapshot.addr, addr);
                cJSON_AddStringToObject(o, "device", addr);
                cJSON_AddBoolToObject(o, "ready", snapshot.services_ready);
                cJSON_AddNumberToObject(o, "status", param->search_cmpl.status);
                publish_event(o);
            }
            break;
        }

        case ESP_GATTC_READ_CHAR_EVT: {
            ble_conn_t snapshot;
            ble_conn_t *e = ble_snapshot_by_conn_id(param->read.conn_id, &snapshot) ? &snapshot : NULL;
            cJSON *o = event_base("ble.read_result");
            if (e) {
                char addr[18];
                bda_to_string(e->addr, addr);
                cJSON_AddStringToObject(o, "device", addr);
            }
            cJSON_AddNumberToObject(o, "handle", param->read.handle);
            cJSON_AddNumberToObject(o, "status", param->read.status);
            if (param->read.status == ESP_GATT_OK) {
                char *hex = hex_encode(param->read.value, param->read.value_len);
                if (hex) {
                    cJSON_AddStringToObject(o, "data", hex);
                    free(hex);
                } else cJSON_SetNumberValue(cJSON_GetObjectItemCaseSensitive(o, "status"), ESP_GATT_ERROR);
            }
            publish_event(o);
            break;
        }

        case ESP_GATTC_WRITE_CHAR_EVT: {
            ble_conn_t snapshot;
            ble_conn_t *e = ble_snapshot_by_conn_id(param->write.conn_id, &snapshot) ? &snapshot : NULL;
            cJSON *o = event_base("ble.write_result");
            if (e) {
                char addr[18];
                bda_to_string(e->addr, addr);
                cJSON_AddStringToObject(o, "device", addr);
            }
            cJSON_AddNumberToObject(o, "handle", param->write.handle);
            cJSON_AddNumberToObject(o, "status", param->write.status);
            publish_event(o);
            break;
        }

        case ESP_GATTC_NOTIFY_EVT: {
            gw_report_t report = {.handle = param->notify.handle, .indicate = !param->notify.is_notify,
                                  .received_ms = esp_timer_get_time() / 1000, .len = param->notify.value_len};
            if (report.len <= sizeof(report.data)) memcpy(report.data, param->notify.value, report.len);
            if (gw_protocol_owns(param->notify.remote_bda)) {
                cJSON *o = event_base("ble.notify");
                char addr[18]; bda_to_string(param->notify.remote_bda, addr);
                cJSON_AddStringToObject(o, "device", addr); cJSON_AddNumberToObject(o, "handle", report.handle);
                char *hex = hex_encode(param->notify.value, param->notify.value_len);
                if (hex) { cJSON_AddStringToObject(o, "data", hex); free(hex); }
                gw_protocol_event(o); cJSON_Delete(o);
            } else if (!gw_manager_report(param->notify.remote_bda, &report)) gw_adapter_report(param->notify.remote_bda, &report);
            break;
        }

        case ESP_GATTC_REG_FOR_NOTIFY_EVT:
            ble_notify_registration_done(gattc_if, param->reg_for_notify.handle,
                                         param->reg_for_notify.status, false);
            break;

        case ESP_GATTC_UNREG_FOR_NOTIFY_EVT:
            ble_notify_registration_done(gattc_if, param->unreg_for_notify.handle,
                                         param->unreg_for_notify.status, true);
            break;

        case ESP_GATTC_WRITE_DESCR_EVT:
            ble_finish_cccd_operation(param->write.conn_id, param->write.handle, param->write.status);
            break;

        case ESP_GATTC_CANCEL_OPEN_EVT: {
            portENTER_CRITICAL(&g_connection_lock);
            ble_conn_t *e = ble_find_by_addr(param->cancel_open.remote_bda);
            if (e && !e->connected) {
                if (param->cancel_open.status == ESP_GATT_OK) ble_release(e);
                else e->cancel_requested = false;
            }
            portEXIT_CRITICAL(&g_connection_lock);
            gw_manager_connection(param->cancel_open.remote_bda, false,
                                  param->cancel_open.status ? param->cancel_open.status : ESP_ERR_TIMEOUT);
            if (param->cancel_open.status == ESP_GATT_OK) {
                cJSON *o = event_base("ble.connection"); char addr[18]; bda_to_string(param->cancel_open.remote_bda, addr);
                cJSON_AddStringToObject(o, "device", addr); cJSON_AddBoolToObject(o, "connected", false);
                gw_protocol_event(o); cJSON_Delete(o);
            }
            break;
        }

        case ESP_GATTC_DISCONNECT_EVT: {
            portENTER_CRITICAL(&g_connection_lock);
            ble_conn_t *e = ble_find_by_conn_id(param->disconnect.conn_id);
            if (e && bda_equal(e->addr, param->disconnect.remote_bda)) ble_release(e);
            portEXIT_CRITICAL(&g_connection_lock);
            cJSON *o = event_base("ble.connection");
            char addr[18];
            gw_manager_connection(param->disconnect.remote_bda, false, param->disconnect.reason);
            bda_to_string(param->disconnect.remote_bda, addr);
            cJSON_AddStringToObject(o, "device", addr);
            cJSON_AddBoolToObject(o, "connected", false);
            cJSON_AddNumberToObject(o, "reason", param->disconnect.reason);
            publish_event(o);
            break;
        }

        default:
            break;
    }
}

// ============================================================================
// 协议参数与诊断
// ============================================================================

static const char *json_string(cJSON *o, const char *key) {
    cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}

static int json_int(cJSON *o, const char *key, int def) {
    cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsNumber(v) ? v->valueint : def;
}

cJSON *gw_adapter_diagnostics(void) {
    cJSON *o = cJSON_CreateObject();
    cJSON_AddBoolToObject(o, "ok", true);
    cJSON_AddStringToObject(o, "gateway", g_config.gateway_id);
    cJSON_AddStringToObject(o, "firmware", GW_FIRMWARE_VERSION);
    cJSON_AddStringToObject(o, "chip", CONFIG_IDF_TARGET);
    cJSON_AddNumberToObject(o, "maxBleConnections", GW_MAX_BLE_CONNECTIONS);
    cJSON_AddNumberToObject(o, "maxClassicConnections", GW_MAX_CLASSIC_CONNECTIONS);
    cJSON_AddNumberToObject(o, "maxSppConnections", GW_MAX_SPP_CONNECTIONS);
    uint32_t flash_size = 0;
    if (esp_flash_get_physical_size(NULL, &flash_size) == ESP_OK) {
        cJSON_AddNumberToObject(o, "flashSizeBytes", flash_size);
    }
    cJSON_AddNumberToObject(o, "psramSizeBytes", esp_psram_get_size());
    cJSON_AddNumberToObject(o, "freeInternalHeapBytes",
                            heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    cJSON_AddNumberToObject(o, "largestInternalBlockBytes",
                            heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    cJSON_AddNumberToObject(o, "freePsramHeapBytes",
                            heap_caps_get_free_size(MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    cJSON *features = cJSON_AddArrayToObject(o, "features");
    cJSON_AddItemToArray(features, cJSON_CreateString("ble-gatt-client"));
    cJSON_AddItemToArray(features, cJSON_CreateString("device-registry"));
    cJSON_AddItemToArray(features, cJSON_CreateString("auto-reconnect"));
    cJSON_AddItemToArray(features, cJSON_CreateString("v1-state-stream"));
    cJSON_AddItemToArray(features, cJSON_CreateString("local-dashboard"));
    cJSON_AddNumberToObject(o, "minimumInternalHeapBytes", heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    cJSON_AddNumberToObject(o, "uptimeMs", (double)(esp_timer_get_time() / 1000));
    cJSON_AddBoolToObject(o, "wifiConnected", (xEventGroupGetBits(g_runtime_events) & WIFI_CONNECTED_BIT) != 0);
    cJSON_AddBoolToObject(o, "mqttConnected", (xEventGroupGetBits(g_runtime_events) & MQTT_CONNECTED_BIT) != 0);
    cJSON_AddNumberToObject(o, "mqttOutboxBytes", g_mqtt ? esp_mqtt_client_get_outbox_size(g_mqtt) : 0);
    int connected = 0, pending = 0;
    portENTER_CRITICAL(&g_connection_lock);
    for (unsigned i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) if (g_ble[i].used) {
        if (g_ble[i].connected) ++connected; else ++pending;
    }
    portEXIT_CRITICAL(&g_connection_lock);
    cJSON_AddNumberToObject(o, "connectedDevices", connected);
    cJSON_AddNumberToObject(o, "connectingDevices", pending);
    return o;
}

static void gateway_task(void *arg) {
    (void)arg;
    while (true) {
        gw_protocol_tick();
        gw_manager_tick();
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// ============================================================================
// MQTT / Wi-Fi
// ============================================================================

static void mqtt_event_handler(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {
    (void)handler_args;
    (void)base;
    esp_mqtt_event_handle_t event = event_data;

    switch ((esp_mqtt_event_id_t)event_id) {
        case MQTT_EVENT_CONNECTED:
            ESP_LOGI(TAG, "MQTT connected");
            xEventGroupSetBits(g_runtime_events, MQTT_CONNECTED_BIT);
            esp_mqtt_client_subscribe(g_mqtt, g_topic_v1_down, 1);
            gw_protocol_online();
            publish_status(true);
            break;

        case MQTT_EVENT_DISCONNECTED:
            xEventGroupClearBits(g_runtime_events, MQTT_CONNECTED_BIT);
            break;

        case MQTT_EVENT_DATA: {
            static char *payload;
            static int received, total;
            if (event->current_data_offset == 0) {
                free(payload); payload = NULL; received = total = 0;
                if (event->retain) break;
                if (event->topic_len != strlen(g_topic_v1_down) ||
                    memcmp(event->topic, g_topic_v1_down, event->topic_len) ||
                    event->total_data_len <= 0 || event->total_data_len > GW_V1_MAX_FRAME) break;
                total = event->total_data_len;
                payload = malloc((size_t)total);
            }
            if (!payload) break;
            if (event->current_data_offset != received || event->total_data_len != total || event->data_len <= 0 || event->data_len > total - received) {
                free(payload); payload = NULL; break;
            }
            memcpy(payload + received, event->data, event->data_len); received += event->data_len;
            if (received == total) {
                gw_protocol_receive(payload, total, -1);
                free(payload); payload = NULL;
            }
            break;
        }

        default:
            break;
    }
}

static void mqtt_start(void) {
    log_network_memory("Before MQTT");
    static char lwt[128];
    snprintf(lwt, sizeof(lwt), "{\"online\":false,\"gateway\":\"%s\"}", g_config.gateway_id);

    esp_mqtt_client_config_t cfg = {0};
    cfg.broker.address.uri = g_config.mqtt_uri;
    cfg.credentials.username = g_config.mqtt_username[0] ? g_config.mqtt_username : NULL;
    cfg.credentials.authentication.password = g_config.mqtt_password[0] ? g_config.mqtt_password : NULL;
    cfg.session.keepalive = 30;
    cfg.session.last_will.topic = g_topic_status;
    cfg.session.last_will.msg = lwt;
    cfg.session.last_will.msg_len = 0;
    cfg.session.last_will.qos = 1;
    cfg.session.last_will.retain = true;
    cfg.buffer.size = 8192;
    cfg.buffer.out_size = 8192;
    cfg.outbox.limit = GW_MQTT_OUTBOX_MAX_BYTES;

    if (strncmp(g_config.mqtt_uri, "mqtts://", 8) == 0) {
        cfg.broker.verification.crt_bundle_attach = esp_crt_bundle_attach;
    }

    g_mqtt = esp_mqtt_client_init(&cfg);
    if (!g_mqtt) {
        ESP_LOGE(TAG, "MQTT client init failed");
        return;
    }
    ESP_ERROR_CHECK(esp_mqtt_client_register_event(g_mqtt, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL));
    ESP_ERROR_CHECK(esp_mqtt_client_start(g_mqtt));
}

static void wifi_connect_logged(void) {
    esp_err_t err = esp_wifi_connect();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Wi-Fi connect request failed: %s", esp_err_to_name(err));
        log_network_memory("Wi-Fi connect failed");
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data) {
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        wifi_connect_logged();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event = data;
        ESP_LOGW(TAG, "Wi-Fi disconnected: reason=%u", (unsigned)event->reason);
        xEventGroupClearBits(g_runtime_events, WIFI_CONNECTED_BIT);
        wifi_connect_logged();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = data;
        ESP_LOGI(TAG, "Wi-Fi connected: http://" IPSTR "/", IP2STR(&event->ip_info.ip));
        log_network_memory("Wi-Fi got IP");
        xEventGroupSetBits(g_runtime_events, WIFI_CONNECTED_BIT);
    }
}

static void wifi_start(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, wifi_event_handler, NULL));

    if (!g_config.configured) {
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
        config_portal_enable(false);
        ESP_ERROR_CHECK(esp_wifi_start());
        if (xTaskCreate(config_button_task, "config_button", 3072, NULL, 2, NULL) != pdPASS) {
            ESP_LOGE(TAG, "Failed to create configuration button task");
        }
        return;
    }

    wifi_config_t wifi = {0};
    strlcpy((char *)wifi.sta.ssid, g_config.wifi_ssid, sizeof(wifi.sta.ssid));
    strlcpy((char *)wifi.sta.password, g_config.wifi_password, sizeof(wifi.sta.password));
    // WIFI_AUTH_OPEN is a minimum threshold, not a request to use an open link.
    // It keeps the gateway compatible with open/WPA2/WPA3 networks.
    wifi.sta.threshold.authmode = WIFI_AUTH_OPEN;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi));
    ESP_ERROR_CHECK(esp_wifi_start());
    if (xTaskCreate(wifi_config_fallback_task, "wifi_cfg_fallback", 3072, NULL, 2, NULL) != pdPASS) {
        ESP_LOGE(TAG, "Failed to create Wi-Fi fallback task");
    }
    if (xTaskCreate(config_button_task, "config_button", 3072, NULL, 2, NULL) != pdPASS) {
        ESP_LOGE(TAG, "Failed to create configuration button task");
    }
}

// ============================================================================
// Bluetooth initialization
// ============================================================================

static void bluetooth_start(void) {
    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    ESP_ERROR_CHECK(esp_ble_gap_set_device_name(GW_DEVICE_NAME));

    ESP_ERROR_CHECK(esp_ble_gap_register_callback(ble_gap_cb));
    ESP_ERROR_CHECK(esp_ble_gattc_register_callback(ble_gattc_cb));
    ESP_ERROR_CHECK(esp_ble_gatt_set_local_mtu(247));
    ESP_ERROR_CHECK(esp_ble_gattc_app_register(0));

    esp_ble_scan_params_t scan_params = {
        .scan_type = BLE_SCAN_TYPE_ACTIVE,
        .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
        .scan_filter_policy = BLE_SCAN_FILTER_ALLOW_ALL,
        .scan_interval = 0x80,
        // 扫描占空比降至 25%，为多设备连接和 Wi-Fi 留出无线时间
        .scan_window = 0x20,
        .scan_duplicate = BLE_SCAN_DUPLICATE_DISABLE,
    };
    ESP_ERROR_CHECK(esp_ble_gap_set_scan_params(&scan_params));
}

// ============================================================================
// 网关启动
// ============================================================================

void gateway_start(void) {
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    } else {
        ESP_ERROR_CHECK(ret);
    }

    gw_manager_init();
    bool configured = config_load(&g_config);
    if (!configured) config_defaults(&g_config);
    build_topics();
    gw_protocol_init(g_config.gateway_id);

    g_runtime_events = xEventGroupCreate();
    if (!g_runtime_events) {
        ESP_LOGE(TAG, "Failed to create runtime event group");
        abort();
    }
    if (xTaskCreate(gateway_task, "gateway", 12288, NULL, 6, NULL) != pdPASS) {
        ESP_LOGE(TAG, "Failed to create gateway task");
        abort();
    }

    wifi_start();
    log_network_memory("Wi-Fi started");
    esp_sntp_setoperatingmode(SNTP_OPMODE_POLL);
    esp_sntp_setservername(0, "pool.ntp.org");
    esp_sntp_init();
    bluetooth_start();
    log_network_memory("Bluetooth started");
    config_http_start();
    uint8_t mac[6]; esp_read_mac(mac, ESP_MAC_WIFI_STA);
    char hostname[32];
    snprintf(hostname, sizeof(hostname), "blegw-%02x%02x%02x%02x%02x%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    esp_err_t mdns_err = mdns_init();
    if (mdns_err == ESP_OK) {
        ESP_ERROR_CHECK(mdns_hostname_set(hostname));
        ESP_ERROR_CHECK(mdns_instance_name_set(g_config.gateway_id));
        mdns_txt_item_t txt[] = {{"path", "/ble/v1"}, {"protocol", "1"}, {"gatewayId", g_config.gateway_id}};
        ESP_ERROR_CHECK(mdns_service_add(NULL, "_blegw", "_tcp", 80, txt, 3));
    } else ESP_LOGW(TAG, "mDNS unavailable: %s", esp_err_to_name(mdns_err));

    if (!configured) {
        ESP_LOGW(TAG, "No runtime configuration. Connect to %s / password '%s' and open http://192.168.4.1", g_config_ap_ssid, g_config_ap_password);
        return;
    }

    xEventGroupWaitBits(g_runtime_events, WIFI_CONNECTED_BIT, pdFALSE, pdTRUE, portMAX_DELAY);
    mqtt_start();
    ESP_LOGI(TAG, "Gateway ready: %s, MQTT=%s", g_config.gateway_id, g_config.mqtt_uri);
}

bool gw_adapter_link(const uint8_t addr[6], gw_link_t *link) {
    ble_conn_t snapshot;
    if (!ble_snapshot_by_addr(addr, &snapshot)) return false;
    *link = (gw_link_t){.connected = snapshot.connected, .services_ready = snapshot.services_ready,
                        .subscription_pending = snapshot.cccd_pending, .started_ms = snapshot.started_ms};
    return true;
}

esp_err_t gw_adapter_connect(const uint8_t addr[6], uint8_t address_type) {
    if (g_gattc_if == ESP_GATT_IF_NONE) return ESP_ERR_INVALID_STATE;
    if (g_ble_scanning) return ESP_ERR_INVALID_STATE;
    portENTER_CRITICAL(&g_connection_lock);
    ble_conn_t *e = ble_find_by_addr(addr);
    if (e) {
        bool connected = e->connected;
        portEXIT_CRITICAL(&g_connection_lock);
        return connected ? ESP_OK : ESP_ERR_INVALID_STATE;
    }
    for (unsigned i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) if (g_ble[i].used && !g_ble[i].connected) {
        portEXIT_CRITICAL(&g_connection_lock);
        return ESP_ERR_INVALID_STATE;
    }
    e = ble_alloc(addr, (esp_ble_addr_type_t)address_type);
    portEXIT_CRITICAL(&g_connection_lock);
    if (!e) return ESP_ERR_NO_MEM;
    esp_ble_gatt_creat_conn_params_t params = {0};
    memcpy(params.remote_bda, addr, 6);
    params.remote_addr_type = (esp_ble_addr_type_t)address_type;
    params.own_addr_type = BLE_ADDR_TYPE_PUBLIC;
    params.is_direct = true;
    esp_err_t err = esp_ble_gattc_enh_open(g_gattc_if, &params);
    if (err != ESP_OK) {
        portENTER_CRITICAL(&g_connection_lock);
        e = ble_find_by_addr(addr);
        if (e && !e->connected) ble_release(e);
        portEXIT_CRITICAL(&g_connection_lock);
    }
    return err;
}

esp_err_t gw_adapter_disconnect(const uint8_t addr[6]) {
    ble_conn_t snapshot;
    portENTER_CRITICAL(&g_connection_lock);
    ble_conn_t *e = ble_find_by_addr(addr);
    if (!e || e->cancel_requested) { portEXIT_CRITICAL(&g_connection_lock); return ESP_OK; }
    snapshot = *e;
    e->cancel_requested = true;
    portEXIT_CRITICAL(&g_connection_lock);
    esp_err_t err;
    if (snapshot.connected) err = esp_ble_gattc_close(g_gattc_if, snapshot.conn_id);
    else {
        esp_ble_gattc_cancel_open_params_t params = {.gattc_if = g_gattc_if};
        memcpy(params.remote_bda, addr, 6);
        err = esp_ble_gattc_cancel_open(&params);
    }
    if (err != ESP_OK) {
        portENTER_CRITICAL(&g_connection_lock);
        e = ble_find_by_addr(addr);
        if (e) e->cancel_requested = false;
        portEXIT_CRITICAL(&g_connection_lock);
    }
    return err;
}

void gw_adapter_expire(void) {
    int64_t now = esp_timer_get_time() / 1000;
    for (unsigned i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) {
        esp_bd_addr_t addr;
        portENTER_CRITICAL(&g_connection_lock);
        bool expired = g_ble[i].used && ((!g_ble[i].connected && now - g_ble[i].started_ms > 15000) ||
                        (g_ble[i].cccd_pending && now - g_ble[i].cccd_started_ms > 10000));
        memcpy(addr, g_ble[i].addr, 6);
        portEXIT_CRITICAL(&g_connection_lock);
        if (expired) gw_adapter_disconnect(addr);
    }
}

esp_err_t gw_adapter_subscribe(const gw_device_t *device, unsigned index) {
    if (!gw_protocol_gatt_available()) return ESP_ERR_INVALID_STATE;
    if (index >= device->subscription_count) return ESP_ERR_INVALID_ARG;
    ble_conn_t conn;
    if (!ble_snapshot_by_addr(device->addr, &conn) || !conn.connected || !conn.services_ready) return ESP_ERR_INVALID_STATE;
    const gw_subscription_t *sub = &device->subscriptions[index];
    esp_gattc_service_elem_t service;
    esp_gattc_char_elem_t ch;
    if (!ble_resolve_char(&conn, sub->service, sub->characteristic, &service, &ch)) return ESP_ERR_NOT_FOUND;
    if (!(ch.properties & (sub->indicate ? ESP_GATT_CHAR_PROP_BIT_INDICATE : ESP_GATT_CHAR_PROP_BIT_NOTIFY))) return ESP_ERR_NOT_SUPPORTED;
    esp_bt_uuid_t uuid = {.len = ESP_UUID_LEN_16, .uuid = {.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG}};
    esp_gattc_descr_elem_t desc;
    uint16_t count = 1;
    if (esp_ble_gattc_get_descr_by_char_handle(g_gattc_if, conn.conn_id, ch.char_handle, uuid, &desc, &count) != ESP_GATT_OK || !count)
        return ESP_ERR_NOT_FOUND;
    if (!ble_begin_cccd_operation(&conn, ch.char_handle, desc.handle, sub->indicate ? 2 : 1, false, true)) return ESP_ERR_INVALID_STATE;
    portENTER_CRITICAL(&g_connection_lock);
    ble_conn_t *entry = ble_find_by_conn_id(conn.conn_id);
    if (entry) {
        snprintf(entry->pending_service, sizeof(entry->pending_service), "%s", sub->service);
        snprintf(entry->pending_characteristic, sizeof(entry->pending_characteristic), "%s", sub->characteristic);
        entry->pending_latest = device->latest;
    }
    portEXIT_CRITICAL(&g_connection_lock);
    esp_err_t err = esp_ble_gattc_register_for_notify(g_gattc_if, conn.addr, ch.char_handle);
    if (err != ESP_OK) ble_finish_cccd_operation(conn.conn_id, desc.handle, ESP_GATT_ERROR);
    return err;
}

esp_err_t gw_adapter_scan(void) {
    if (!g_ble_scan_params_ready) return ESP_ERR_INVALID_STATE;
    portENTER_CRITICAL(&g_connection_lock);
    bool pending = false;
    for (unsigned i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i) if (g_ble[i].used && !g_ble[i].connected) pending = true;
    portEXIT_CRITICAL(&g_connection_lock);
    if (pending) return ESP_ERR_INVALID_STATE;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_ble_scanning, &expected, true)) return ESP_OK;
    esp_err_t err = esp_ble_gap_start_scanning(5);
    if (err != ESP_OK) g_ble_scanning = false;
    return err;
}


bool gw_adapter_report(const uint8_t addr[6], const gw_report_t *report) {
    if (report->len > GW_REPORT_BYTES) return false;
    cJSON *o = event_base(report->broadcast ? "ble.scan" : "ble.notify");
    if (!o) return false;
    char text[18]; bda_to_string(addr, text);
    cJSON_AddStringToObject(o, "device", text);
    // 时间戳由协议层在校验后统一生成，这里不使用平台单调时间
    if (report->broadcast) {
        cJSON_AddNumberToObject(o, "rssi", report->rssi);
        cJSON_AddNumberToObject(o, "addressType", report->address_type);
        char name[GW_ADV_NAME_MAX];
        if (gw_adv_local_name(report->data, report->len, name, sizeof(name)))
            cJSON_AddStringToObject(o, "name", name);
    } else {
        cJSON_AddNumberToObject(o, "handle", report->handle);
        cJSON_AddStringToObject(o, "mode", report->indicate ? "indicate" : "notify");
    }
    char *hex = hex_encode(report->data, report->len);
    bool ok = false;
    if (hex) {
        cJSON_AddStringToObject(o, report->broadcast ? "advertisement" : "data", hex);
        ok = gw_protocol_event(o);
        free(hex);
    }
    cJSON_Delete(o);
    return ok;
}

void gw_adapter_restart(void) {
    if (xTaskCreate(delayed_restart_task, "devices_restart", 2048, NULL, 5, NULL) != pdPASS) esp_restart();
}

bool gw_protocol_publish(cJSON *frame, int qos) {
    return mqtt_publish_json(g_topic_v1_up, frame, qos, false);
}

int gw_protocol_ble_start(const cJSON *request, const uint8_t addr[6], uint8_t addr_type,
                          uint16_t *handle, bool *pending, int *native_code) {
    const char *op = json_string((cJSON *)request, "op");
    cJSON *data = cJSON_GetObjectItemCaseSensitive(request, "data");
    *pending = false;
    *native_code = 0;
    esp_err_t err = ESP_OK;
    if (!strcmp(op, "scan")) {
        if (!strcmp(json_string(data, "action"), "stop")) err = esp_ble_gap_stop_scanning();
        else {
            if (!g_ble_scan_params_ready || g_ble_scanning) return 2001;
            // 扫描参数更新完成后再启动，避免异步设置与启动相互竞争
            esp_ble_scan_params_t params = {
                .scan_type = cJSON_IsFalse(cJSON_GetObjectItemCaseSensitive(data, "active")) ? BLE_SCAN_TYPE_PASSIVE : BLE_SCAN_TYPE_ACTIVE,
                .own_addr_type = BLE_ADDR_TYPE_PUBLIC, .scan_filter_policy = BLE_SCAN_FILTER_ALLOW_ALL,
                .scan_interval = 0x80, .scan_window = 0x20, .scan_duplicate = BLE_SCAN_DUPLICATE_DISABLE,
            };
            g_v1_scan_duration = (json_int(data, "duration", 5000) + 999) / 1000;
            g_ble_scanning = true;
            err = esp_ble_gap_set_scan_params(&params);
            if (err != ESP_OK) { g_v1_scan_duration = 0; g_ble_scanning = false; }
        }
        *native_code = err;
        return err == ESP_OK ? 0 : 2001;
    }
    if (!strcmp(op, "connect")) {
        err = gw_adapter_connect(addr, addr_type);
        *native_code = err;
        *pending = err == ESP_OK;
        return err == ESP_OK ? 0 : err == ESP_ERR_NO_MEM ? 2003 : 2001;
    }
    if (!strcmp(op, "disconnect")) {
        err = gw_adapter_disconnect(addr);
        *native_code = err; *pending = err == ESP_OK;
        return err == ESP_OK ? 0 : 3101;
    }
    ble_conn_t conn;
    if (!ble_snapshot_by_addr(addr, &conn) || !conn.connected || !conn.services_ready || conn.cancel_requested) return 3002;
    if (conn.cccd_pending) return 2001;
    esp_bt_uuid_t svc_uuid, chr_uuid;
    if (!uuid_parse(json_string((cJSON *)request, "service"), &svc_uuid) ||
        !uuid_parse(json_string((cJSON *)request, "char"), &chr_uuid)) return 1003;
    esp_gattc_service_elem_t svc;
    uint16_t count = 1;
    esp_gatt_status_t status = esp_ble_gattc_get_service(g_gattc_if, conn.conn_id, &svc_uuid, &svc, &count, 0);
    if (status != ESP_GATT_OK || !count) { *native_code = status; return 4001; }
    esp_gattc_char_elem_t ch;
    count = 1;
    status = esp_ble_gattc_get_char_by_uuid(g_gattc_if, conn.conn_id, svc.start_handle, svc.end_handle, chr_uuid, &ch, &count);
    if (status != ESP_GATT_OK || !count) { *native_code = status; return 4002; }
    *handle = ch.char_handle;
    int failure;
    if (!strcmp(op, "read")) {
        failure = 4101;
        if (!(ch.properties & ESP_GATT_CHAR_PROP_BIT_READ)) return failure;
        err = esp_ble_gattc_read_char(g_gattc_if, conn.conn_id, ch.char_handle, ESP_GATT_AUTH_REQ_NONE);
    } else if (!strcmp(op, "write")) {
        failure = 4201;
        const char *type = json_string(data, "writeType");
        bool no_response = type && !strcmp(type, "withoutResponse");
        if (!(ch.properties & (no_response ? ESP_GATT_CHAR_PROP_BIT_WRITE_NR : ESP_GATT_CHAR_PROP_BIT_WRITE))) return failure;
        size_t len = 0;
        const char *value = json_string((cJSON *)request, "value");
        uint8_t *bytes = value && !*value ? calloc(1, 1) : hex_decode(value, &len);
        if (!bytes) return 1003;
        // 单次写不能超过协商后的 ATT 载荷，过长的数据需要客户端自行分片
        size_t payload = (size_t)(conn.mtu > 3 ? conn.mtu - 3 : 20);
        if (len > 512 || len > payload) { free(bytes); return 1003; }
        err = esp_ble_gattc_write_char(g_gattc_if, conn.conn_id, ch.char_handle, len, bytes,
                                     no_response ? ESP_GATT_WRITE_TYPE_NO_RSP : ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE);
        free(bytes);
    } else if (!strcmp(op, "subscribe")) {
        failure = 4301;
        bool enabled = !cJSON_IsFalse(cJSON_GetObjectItemCaseSensitive(data, "enabled"));
        const char *mode = json_string(data, "mode");
        bool indicate = mode && !strcmp(mode, "indicate");
        if (!mode || !strcmp(mode, "auto")) indicate = !(ch.properties & ESP_GATT_CHAR_PROP_BIT_NOTIFY);
        if (enabled && !(ch.properties & (indicate ? ESP_GATT_CHAR_PROP_BIT_INDICATE : ESP_GATT_CHAR_PROP_BIT_NOTIFY))) return failure;
        esp_bt_uuid_t uuid = {.len = ESP_UUID_LEN_16, .uuid = {.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG}};
        esp_gattc_descr_elem_t desc; count = 1;
        status = esp_ble_gattc_get_descr_by_char_handle(g_gattc_if, conn.conn_id, ch.char_handle, uuid, &desc, &count);
        if (status != ESP_GATT_OK || !count) { *native_code = status; return failure; }
        if (!ble_begin_cccd_operation(&conn, ch.char_handle, desc.handle, enabled ? (indicate ? 2 : 1) : 0, !enabled, false)) return 2001;
        err = enabled ? esp_ble_gattc_register_for_notify(g_gattc_if, conn.addr, ch.char_handle) :
                        esp_ble_gattc_unregister_for_notify(g_gattc_if, conn.addr, ch.char_handle);
        if (err != ESP_OK) {
            // 提交失败时没有异步回调，直接清理预留，避免重复完成下一条请求
            portENTER_CRITICAL(&g_connection_lock);
            ble_conn_t *e = ble_find_by_conn_id(conn.conn_id);
            if (e) e->cccd_pending = false;
            portEXIT_CRITICAL(&g_connection_lock);
        }
    } else return 1002;
    *native_code = err; *pending = err == ESP_OK;
    return err == ESP_OK ? 0 : failure;
}

bool gw_adapter_protocol_owned(const uint8_t addr[6]) { return gw_protocol_owns(addr); }

unsigned gw_protocol_managed_gatt_count(void) {
    unsigned count = 0;
    portENTER_CRITICAL(&g_connection_lock);
    for (unsigned i = 0; i < GW_MAX_BLE_CONNECTIONS; ++i)
        if (g_ble[i].used && g_ble[i].cccd_pending && g_ble[i].managed_cccd) ++count;
    portEXIT_CRITICAL(&g_connection_lock);
    return count;
}
