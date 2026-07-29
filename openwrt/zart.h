/*
 * zart.h - Kernel-space header for zart (Linux kernel module)
 *
 * Uses kernel types instead of stdint.h to avoid typedef conflicts.
 */
#ifndef _ZART_H_
#define _ZART_H_

#include <linux/types.h>

struct zart_table;

void zart_init(
    void *(*alloc_fn)(size_t size, size_t alignment),
    void (*free_fn)(void *ptr, size_t size)
);

struct zart_table *zart_table_create(void);
void zart_table_destroy(struct zart_table *t);

void zart_table_insert4(struct zart_table *t, const u8 *addr,
    u8 prefix_len, size_t value);
void zart_table_insert6(struct zart_table *t, const u8 *addr,
    u8 prefix_len, size_t value);

bool zart_table_lookup4(const struct zart_table *t, const u8 *addr,
    size_t *result);
bool zart_table_lookup6(const struct zart_table *t, const u8 *addr,
    size_t *result);

void zart_table_delete4(struct zart_table *t, const u8 *addr, u8 prefix_len);
void zart_table_delete6(struct zart_table *t, const u8 *addr, u8 prefix_len);

s32 zart_table_size(const struct zart_table *t);

#endif /* _ZART_H_ */
