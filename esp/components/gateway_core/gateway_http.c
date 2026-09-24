#include "gateway_protocol.h"
#include "gateway_manager.h"
#include "cJSON.h"
#include "esp_http_server.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define HTTP_ID_MAX 65
#define HTTP_OP_MAX 65

static unsigned s_http_scan_sequence;
static char s_http_scan_id[32] = "http-0";

static bool valid_identifier(const char *text, size_t limit) {
    return text && *text && strlen(text) < limit;
}

static const char *data_string(const cJSON *object, const char *key) {
    const cJSON *value = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(value) ? value->valuestring : NULL;
}

static bool valid_timeout(const cJSON *object, const char *key) {
    const cJSON *value = cJSON_GetObjectItemCaseSensitive(object, key);
    return !value || (cJSON_IsNumber(value) && isfinite(value->valuedouble) &&
                      value->valuedouble >= 1 && value->valuedouble <= 120000 &&
                      floor(value->valuedouble) == value->valuedouble);
}

static bool valid_bool(const cJSON *object, const char *key) {
    const cJSON *value = cJSON_GetObjectItemCaseSensitive(object, key);
    return !value || cJSON_IsBool(value);
}

static cJSON *read_json(httpd_req_t *req) {
    if (req->content_len <= 0 || req->content_len > GW_V1_MAX_FRAME) return NULL;
    char *text = malloc((size_t) req->content_len + 1);
    if (!text) return NULL;
    int received = 0, timeouts = 0;
    while (received < req->content_len) {
        int count = httpd_req_recv(req, text + received, req->content_len - received);
        if (count == HTTPD_SOCK_ERR_TIMEOUT && ++timeouts <= 3) continue;
        if (count <= 0) {
            free(text);
            return NULL;
        }
        received += count;
    }
    text[received] = '\0';
    cJSON *json = cJSON_ParseWithLengthOpts(text, (size_t) received + 1, NULL, true);
    free(text);
    return json;
}

static int validate_request(const cJSON *request, const char **error) {
    if (!cJSON_IsObject(request)) {
        *error = "invalid_request";
        return 1001;
    }
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(request, "v");
    if (!cJSON_IsNumber(version) || version->valuedouble != 1) {
        *error = "invalid_version";
        return 1001;
    }
    if (!cJSON_IsString(cJSON_GetObjectItemCaseSensitive(request, "type")) ||
        strcmp(data_string(request, "type"), "req")) {
        *error = "invalid_type";
        return 1001;
    }
    if (!valid_identifier(data_string(request, "reqId"), HTTP_ID_MAX)) {
        *error = "invalid_request_id";
        return 1001;
    }
    if (!valid_identifier(data_string(request, "op"), HTTP_OP_MAX)) {
        *error = "invalid_operation";
        return 1001;
    }
    const cJSON *data = cJSON_GetObjectItemCaseSensitive(request, "data");
    if (data && !cJSON_IsObject(data)) {
        *error = "invalid_data";
        return 1003;
    }
    return 0;
}

static int validate_scan(const cJSON *request, const char **error) {
    const cJSON *data = cJSON_GetObjectItemCaseSensitive(request, "data");
    if (!cJSON_IsObject(data)) {
        *error = "invalid_data";
        return 1003;
    }
    const char *action = data_string(data, "action");
    if ((!action || (strcmp(action, "start") && strcmp(action, "stop"))) ||
        !valid_timeout(data, "duration") || !valid_bool(data, "active")) {
        *error = "invalid_scan";
        return 1003;
    }
    return 0;
}

// 管理接口统一返回 V1 响应消息，HTTP 仅负责承载和状态码
static esp_err_t finish_request(httpd_req_t *req, cJSON *request, int code, const char *error,
                                cJSON *result, bool restart) {
    cJSON *response = gw_protocol_response(request, code);
    if (!response) {
        cJSON_Delete(request);
        cJSON_Delete(result);
        return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no_memory");
    }
    if (error) cJSON_ReplaceItemInObjectCaseSensitive(response, "message", cJSON_CreateString(error));
    if (result) cJSON_AddItemToObject(response, "data", result);
    char *text = cJSON_PrintUnformatted(response);
    if (!text) {
        cJSON_Delete(response);
        cJSON_Delete(request);
        return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no_memory");
    }
    const char *status = !code
                             ? "200 OK"
                             : error && !strcmp(error, "cross_origin_denied")
                                   ? "403 Forbidden"
                                   : "400 Bad Request";
    httpd_resp_set_status(req, status);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    esp_err_t err = httpd_resp_sendstr(req, text);
    cJSON_free(text);
    cJSON_Delete(response);
    cJSON_Delete(request);
    if (restart) gw_adapter_restart();
    return err;
}

static esp_err_t api_post(httpd_req_t *req) {
    if (!gw_http_json_post_allowed(req)) {
        return finish_request(req, NULL, 1001, "cross_origin_denied", NULL, false);
    }
    cJSON *request = read_json(req);
    if (!request) return finish_request(req, NULL, 1001, "invalid_json", NULL, false);
    const char *error = NULL;
    int code = validate_request(request, &error);
    if (code) return finish_request(req, request, code, error, NULL, false);
    const char *op = data_string(request, "op");
    cJSON *result = NULL;
    bool restart = false;
    if (!strcmp(op, "manage")) {
        const cJSON *data = cJSON_GetObjectItemCaseSensitive(request, "data");
        if (!cJSON_IsObject(data)) return finish_request(req, request, 1003, "invalid_data", NULL, false);
        code = gw_manager_manage(data, &result, &error);
        const char *action = data_string(data, "action");
        if (!code && result && action && !strcmp(action, "status"))
            cJSON_AddNumberToObject(result, "maxFrameBytes", GW_V1_MAX_FRAME);
        restart = !code && cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(result, "restarting"));
    } else if (!strcmp(op, "scan")) {
        code = validate_scan(request, &error);
        if (!code) {
            uint8_t addr[6] = {0};
            uint16_t handle = 0;
            int native = 0;
            bool pending = false;
            code = gw_protocol_ble_start(request, addr, 0, &handle, &pending, &native);
            if (!code) {
                if (!strcmp(data_string(cJSON_GetObjectItemCaseSensitive(request, "data"), "action"), "start"))
                    snprintf(s_http_scan_id, sizeof(s_http_scan_id), "http-%u", ++s_http_scan_sequence);
                result = cJSON_CreateObject();
                if (result) cJSON_AddStringToObject(result, "scanId", s_http_scan_id);
                else code = 2001;
            }
        }
    } else if (!strcmp(op, "snapshot")) {
        result = gw_protocol_snapshot();
        if (!result) code = 2001;
    } else {
        code = 1002;
        error = "unsupported_http_operation";
    }
    return finish_request(req, request, code, error, result, restart);
}

void gw_http_api_register(httpd_handle_t server) {
    const httpd_uri_t route = {.uri = "/api/v1", .method = HTTP_POST, .handler = api_post};
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &route));
}
