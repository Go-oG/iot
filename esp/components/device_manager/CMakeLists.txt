idf_component_register(
    SRCS "gateway_manager.c"
    INCLUDE_DIRS "include"
    EMBED_TXTFILES "dashboard.html"
    REQUIRES device_registry esp_http_server
    PRIV_REQUIRES bt esp_timer nvs_flash
)
