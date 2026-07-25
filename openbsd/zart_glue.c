/*
 * zart_glue.c - Bridge between OpenBSD ART API and zart kernel module
 *
 * This file replaces the core art_match/art_insert/art_delete with zart
 * implementations while keeping the OpenBSD art_node/art API signatures intact.
 *
 * Integration strategy:
 *   - art_match() → zart_table_lookup4/6 (LPM)
 *   - art_insert() → zart_table_insert4/6
 *   - art_delete() → zart_table_delete4/6
 *   - art_alloc/art_init → create zart_table, store in art struct
 *
 * Place in: /usr/src/sys/net/zart_glue.c
 * Link: zart_kernel.o (from zig build kernel)
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/malloc.h>
#include <sys/pool.h>
#include <sys/socket.h>
#include <net/art.h>

/* zart C ABI - from include/zart.h */
extern void zart_init(void *(*)(size_t, size_t), void (*)(void *, size_t));
extern void *zart_table_create(void);
extern void zart_table_destroy(void *);
extern void zart_table_insert4(void *, const uint8_t *, uint8_t, size_t);
extern void zart_table_insert6(void *, const uint8_t *, uint8_t, size_t);
extern int  zart_table_lookup4(const void *, const uint8_t *, size_t *);
extern int  zart_table_lookup6(const void *, const uint8_t *, size_t *);
extern void zart_table_delete4(void *, const uint8_t *, uint8_t);
extern void zart_table_delete6(void *, const uint8_t *, uint8_t);
extern int  zart_table_size(const void *);

/* kernel_panic binding for zart's panic handler */
void
kernel_panic(const char *msg)
{
	panic("zart: %s", msg);
}

/* Pool-based allocator for zart */
static void *
zart_kern_alloc(size_t size, size_t alignment)
{
	return malloc(size, M_RTABLE, M_NOWAIT | M_ZERO);
}

static void
zart_kern_free(void *ptr, size_t size)
{
	free(ptr, M_RTABLE, size);
}

static int zart_initialized = 0;

/*
 * Extended art struct: stores zart table pointer alongside original fields.
 * We store the zart opaque table pointer in art_root (reusing the field).
 */
#define ART_ZART_TABLE(a)	((void *)(a)->art_root)
#define ART_SET_ZART(a, t)	((a)->art_root = (art_heap_entry *)(t))

void
art_boot(void)
{
	if (!zart_initialized) {
		zart_init(zart_kern_alloc, zart_kern_free);
		zart_initialized = 1;
	}
}

struct art *
art_alloc(unsigned int alen)
{
	struct art *a;

	a = malloc(sizeof(*a), M_RTABLE, M_NOWAIT | M_ZERO);
	if (a == NULL)
		return NULL;

	art_init(a, alen);
	return a;
}

void
art_init(struct art *a, unsigned int alen)
{
	void *zt;

	art_boot();

	zt = zart_table_create();
	if (zt == NULL)
		panic("zart: table creation failed");

	ART_SET_ZART(a, zt);
	a->art_alen = alen;
	/* alen: 4 = IPv4, 16 = IPv6 */
}

struct art_node *
art_insert(struct art *a, struct art_node *an)
{
	void *zt = ART_ZART_TABLE(a);

	if (a->art_alen == 4)
		zart_table_insert4(zt, an->an_addr + 12, an->an_plen,
		    (size_t)an->an_value);
	else
		zart_table_insert6(zt, an->an_addr, an->an_plen,
		    (size_t)an->an_value);

	return NULL; /* no previous entry replaced (simplified) */
}

struct art_node *
art_delete(struct art *a, const void *addr, unsigned int plen)
{
	void *zt = ART_ZART_TABLE(a);

	if (a->art_alen == 4)
		zart_table_delete4(zt, addr, plen);
	else
		zart_table_delete6(zt, addr, plen);

	return NULL; /* TODO: return deleted node for GC */
}

struct art_node *
art_match(struct art *a, const void *addr)
{
	void *zt = ART_ZART_TABLE(a);
	size_t result;
	int found;

	if (a->art_alen == 4)
		found = zart_table_lookup4(zt, addr, &result);
	else
		found = zart_table_lookup6(zt, addr, &result);

	if (!found)
		return NULL;

	/* result is the stored art_node pointer (cast from usize) */
	return (struct art_node *)result;
}

struct art_node *
art_lookup(struct art *a, const void *addr, unsigned int plen)
{
	/*
	 * Exact prefix match. For now delegate to art_match.
	 * TODO: implement exact match via zart get() API.
	 */
	return art_match(a, addr);
}

int
art_is_empty(struct art *a)
{
	void *zt = ART_ZART_TABLE(a);
	return (zart_table_size(zt) == 0);
}
