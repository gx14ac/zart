#ifndef BART_H
#define BART_H

#include <stdint.h>
#ifdef __cplusplus
extern "C"
{
#endif

    // Routing table structure (forward declaration)
    typedef struct BartTable BartTable;

    // Table creation and destruction
    BartTable *bart_create(void);
    void bart_destroy(BartTable *table);

    // Prefix insertion (IPv4/IPv6 versions)
    // IPv4: ip is 32bit address in network byte order, prefix_len is length (0-32)
    int bart_insert4(BartTable *table, uint32_t ip, uint8_t prefix_len, uintptr_t value);
    // IPv6: addr is 16-byte address buffer, prefix_len is length (0-128)
    int bart_insert6(BartTable *table, const uint8_t addr[16], uint8_t prefix_len, uintptr_t value);

    // Lookup (IPv4/IPv6 versions)
    // If found, sets found to 1 and returns longest match value. If not found, sets found to 0 and return value is undefined (0).
    uintptr_t bart_lookup4(BartTable *table, uint32_t ip, int *found);
    uintptr_t bart_lookup6(BartTable *table, const uint8_t addr[16], int *found);

#ifdef __cplusplus
}
#endif
#endif // BART_H