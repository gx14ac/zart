#ifndef _ZART_H_
#define _ZART_H_

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/*
 * zart - High-performance IP routing table (freestanding kernel module)
 *
 * Usage:
 *   1. Call zart_init() with kernel alloc/free functions
 *   2. Create table with zart_table_create()
 *   3. Insert/lookup/delete prefixes
 *   4. Destroy table with zart_table_destroy()
 */

struct zart_table;

/* Initialize the kernel allocator binding. Must be called before any other function. */
void zart_init(
    void *(*alloc_fn)(size_t size, size_t alignment),
    void (*free_fn)(void *ptr, size_t size)
);

/* Create a new routing table. Returns NULL on allocation failure. */
struct zart_table *zart_table_create(void);

/* Destroy a routing table and free all resources. */
void zart_table_destroy(struct zart_table *t);

/* Insert an IPv4 prefix. addr must point to 4 bytes in network order. */
void zart_table_insert4(struct zart_table *t, const uint8_t *addr,
    uint8_t prefix_len, size_t value);

/* Insert an IPv6 prefix. addr must point to 16 bytes in network order. */
void zart_table_insert6(struct zart_table *t, const uint8_t *addr,
    uint8_t prefix_len, size_t value);

/* Longest-prefix-match lookup for IPv4. Returns true if found. */
bool zart_table_lookup4(const struct zart_table *t, const uint8_t *addr,
    size_t *result);

/* Longest-prefix-match lookup for IPv6. Returns true if found. */
bool zart_table_lookup6(const struct zart_table *t, const uint8_t *addr,
    size_t *result);

/* Delete an IPv4 prefix. */
void zart_table_delete4(struct zart_table *t, const uint8_t *addr,
    uint8_t prefix_len);

/* Delete an IPv6 prefix. */
void zart_table_delete6(struct zart_table *t, const uint8_t *addr,
    uint8_t prefix_len);

/* Return the total number of prefixes in the table. */
int32_t zart_table_size(const struct zart_table *t);

#endif /* _ZART_H_ */
