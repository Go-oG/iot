#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define GW_REPORT_BYTES 512
#define GW_REPORT_DEPTH 8

typedef struct {
    uint16_t handle;
    uint16_t len;
    uint8_t address_type;
    bool broadcast;
    bool indicate;
    int rssi;
    int64_t received_ms;
    uint8_t data[GW_REPORT_BYTES];
} gw_report_t;

typedef struct {
    gw_report_t items[GW_REPORT_DEPTH];
    unsigned head;
    unsigned count;
    uint64_t received;
    uint64_t coalesced;
    uint64_t dropped;
    uint64_t published;
    int64_t next_send_ms;
} gw_report_buffer_t;

static inline bool gw_report_push(gw_report_buffer_t *q, const gw_report_t *item, bool latest) {
    ++q->received;
    if (item->len > GW_REPORT_BYTES) { ++q->dropped; return false; }
    if (latest) {
        for (unsigned i = 0; i < q->count; ++i) {
            gw_report_t *old = &q->items[(q->head + i) % GW_REPORT_DEPTH];
            if (old->handle == item->handle && old->broadcast == item->broadcast) {
                *old = *item;
                ++q->coalesced;
                return true;
            }
        }
    }
    if (q->count == GW_REPORT_DEPTH) { ++q->dropped; return false; }
    q->items[(q->head + q->count++) % GW_REPORT_DEPTH] = *item;
    return true;
}

static inline bool gw_report_pop(gw_report_buffer_t *q, int64_t now, uint32_t interval, gw_report_t *out) {
    if (!q->count || now < q->next_send_ms) return false;
    *out = q->items[q->head];
    q->head = (q->head + 1) % GW_REPORT_DEPTH;
    --q->count;
    q->next_send_ms = now + interval;
    return true;
}
