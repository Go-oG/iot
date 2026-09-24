idf_component_register(
    SRCS "gateway_core.c" "gateway_protocol.c" "gateway_http.c"
    INCLUDE_DIRS "include"
    PRIV_REQUIRES device_manager bt esp_driver_gpio esp_event esp_http_server
                  esp_netif esp_timer esp_wifi esp_psram spi_flash mbedtls nvs_flash mqtt lwip mdns
)
