/*
 * zart_glue.c - Hybrid ART replacement using zart for fast LPM lookups
 *
 * Strategy: Keep the original ART data structure for node lifecycle
 * management, iteration, and exact-prefix operations. Shadow all
 * insert/delete into a parallel zart table so that art_match() can
 * use zart's fixed-stride 8-bit trie (4 memory accesses for IPv4)
 * instead of ART's variable-stride tree.
 *
 * This gives us:
 *   - O(4) IPv4 LPM (vs O(7) with ART)
 *   - O(16) IPv6 LPM (vs O(32) with ART)
 *   - Full compatibility with existing art_node/rtentry lifecycle
 *   - No changes to rtable.c or route.c
 *
 * Place in: /usr/src/sys/net/zart_glue.c
 * Link with: zart_kernel.o
 * Replaces: art.c (rename original to art_orig.c as reference)
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/malloc.h>
#include <sys/pool.h>
#include <sys/task.h>
#include <sys/socket.h>
#include <sys/smr.h>

#include <net/art.h>

/* zart C ABI */
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

/*
 * Kernel allocator binding for zart.
 * Uses M_RTABLE with M_NOWAIT for non-blocking allocation.
 */
static void *
zart_kern_alloc(size_t size, size_t alignment)
{
	(void)alignment;
	return malloc(size, M_RTABLE, M_NOWAIT | M_ZERO);
}

static void
zart_kern_free(void *ptr, size_t size)
{
	free(ptr, M_RTABLE, size);
}

/*
 * Pool and GC infrastructure - kept from original art.c for node
 * lifecycle compatibility.
 */
static struct pool	 an_pool, at_pool, at_heap_4_pool, at_heap_8_pool;

static struct art_table	*art_table_gc_list = NULL;
static struct mutex	 art_table_gc_mtx = MUTEX_INITIALIZER(IPL_SOFTNET);
static struct task	 art_table_gc_task =
			     TASK_INITIALIZER(art_table_gc, NULL);

static struct art_node	*art_node_gc_list = NULL;
static struct mutex	 art_node_gc_mtx = MUTEX_INITIALIZER(IPL_SOFTNET);
static struct task	 art_node_gc_task = TASK_INITIALIZER(art_gc, NULL);

static int zart_initialized = 0;

/*
 * We store the zart opaque table pointer in a per-art structure.
 * Since struct art has limited fields, we use a simple mapping.
 * For simplicity, store it as a tagged pointer in art_root when
 * the ART tree is empty, or maintain a parallel side table.
 *
 * Better approach: extend struct art with a void* via a wrapper.
 * But to avoid modifying art.h, we use a fixed-size hash table.
 */
#define ZART_MAP_SIZE	64
static struct {
	struct art	*art;
	void		*zt;
} zart_map[ZART_MAP_SIZE];

static void *
zart_get_table(struct art *a)
{
	unsigned int i;
	uintptr_t h = ((uintptr_t)a >> 4) & (ZART_MAP_SIZE - 1);

	for (i = 0; i < ZART_MAP_SIZE; i++) {
		unsigned int idx = (h + i) & (ZART_MAP_SIZE - 1);
		if (zart_map[idx].art == a)
			return zart_map[idx].zt;
	}
	return NULL;
}

static void
zart_set_table(struct art *a, void *zt)
{
	unsigned int i;
	uintptr_t h = ((uintptr_t)a >> 4) & (ZART_MAP_SIZE - 1);

	for (i = 0; i < ZART_MAP_SIZE; i++) {
		unsigned int idx = (h + i) & (ZART_MAP_SIZE - 1);
		if (zart_map[idx].art == NULL || zart_map[idx].art == a) {
			zart_map[idx].art = a;
			zart_map[idx].zt = zt;
			return;
		}
	}
	panic("zart: map full");
}

static void
zart_clear_table(struct art *a)
{
	unsigned int i;
	uintptr_t h = ((uintptr_t)a >> 4) & (ZART_MAP_SIZE - 1);

	for (i = 0; i < ZART_MAP_SIZE; i++) {
		unsigned int idx = (h + i) & (ZART_MAP_SIZE - 1);
		if (zart_map[idx].art == a) {
			zart_map[idx].art = NULL;
			zart_map[idx].zt = NULL;
			return;
		}
	}
}

/*
 * Forward declarations for original ART internals we still use.
 */
static void		 art_allot(struct art_table *at, unsigned int,
			     art_heap_entry, art_heap_entry);
struct art_table	*art_table_get(struct art *, struct art_table *,
			     unsigned int);
struct art_table	*art_table_put(struct art *, struct art_table *);
struct art_table	*art_table_ref(struct art *, struct art_table *);
int			 art_table_free(struct art *, struct art_table *);
void			 art_table_gc(void *);
void			 art_gc(void *);

/*
 * Level configurations - same as original.
 */
static const unsigned int art_plen32_levels[] = {
	8, 4, 4, 4, 4, 4, 4
};

static const unsigned int art_plen128_levels[] = {
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4
};

static const unsigned int art_plen20_levels[] = {
	4, 4, 4, 4, 4
};

/*
 * ============================================================
 * PUBLIC API
 * ============================================================
 */

void
art_boot(void)
{
	pool_init(&an_pool, sizeof(struct art_node), 0, IPL_SOFTNET, 0,
	    "art_node", NULL);
	pool_init(&at_pool, sizeof(struct art_table), 0, IPL_SOFTNET, 0,
	    "art_table", NULL);
	pool_init(&at_heap_4_pool, AT_HEAPSIZE(4), 0, IPL_SOFTNET, 0,
	    "art_heap4", NULL);
	pool_init(&at_heap_8_pool, AT_HEAPSIZE(8), 0, IPL_SOFTNET, 0,
	    "art_heap8", &pool_allocator_single);

	if (!zart_initialized) {
		zart_init(zart_kern_alloc, zart_kern_free);
		zart_initialized = 1;
		memset(zart_map, 0, sizeof(zart_map));
		printf("zart: initialized (hybrid ART+zart mode)\n");
	}
}

void
art_init(struct art *art, unsigned int alen)
{
	const unsigned int *levels;
	unsigned int nlevels;
	void *zt;
#ifdef DIAGNOSTIC
	unsigned int i;
	unsigned int bits = 0;
#endif

	switch (alen) {
	case 32:
		levels = art_plen32_levels;
		nlevels = nitems(art_plen32_levels);
		break;
	case 128:
		levels = art_plen128_levels;
		nlevels = nitems(art_plen128_levels);
		break;
	case 20:
		levels = art_plen20_levels;
		nlevels = nitems(art_plen20_levels);
		break;
	default:
		panic("no configuration for alen %u", alen);
	}

#ifdef DIAGNOSTIC
	for (i = 0; i < nlevels; i++)
		bits += levels[i];
	if (alen != bits)
		panic("sum of levels %u != address len %u", bits, alen);
#endif

	art->art_root = NULL;
	art->art_levels = levels;
	art->art_nlevels = nlevels;
	art->art_alen = alen;

	/* Create parallel zart table for fast LPM */
	zt = zart_table_create();
	if (zt != NULL)
		zart_set_table(art, zt);
}

struct art *
art_alloc(unsigned int alen)
{
	struct art *art;

	art = malloc(sizeof(*art), M_RTABLE, M_NOWAIT | M_ZERO);
	if (art == NULL)
		return NULL;

	art_init(art, alen);
	return art;
}

/*
 * art_match - Longest Prefix Match (HOT PATH)
 *
 * This is the primary lookup function called on every packet.
 * We use zart for O(4) IPv4 / O(16) IPv6 lookups instead of
 * traversing the ART tree.
 */
struct art_node *
art_match(struct art *art, const void *addr)
{
	void *zt;
	size_t result;
	int found;

	zt = zart_get_table(art);
	if (zt == NULL)
		goto fallback;

	if (art->art_alen == 32)
		found = zart_table_lookup4(zt, addr, &result);
	else if (art->art_alen == 128)
		found = zart_table_lookup6(zt, addr, &result);
	else
		goto fallback;

	if (found)
		return (struct art_node *)result;

	return NULL;

fallback:
	/* Fall through to ART tree walk for MPLS or if zart unavailable */
	return art_match_art(art, addr);
}

/*
 * Original ART tree match - used as fallback for MPLS (alen=20)
 * and when zart table is unavailable.
 */
static struct art_node *
art_match_art(struct art *art, const void *addr)
{
	art_heap_entry *heap;
	struct art_node *dflt = NULL;
	const uint8_t *k = addr;
	unsigned int j, offset = 0;

	heap = SMR_PTR_GET(&art->art_root);
	if (heap == NULL)
		return NULL;

	for (j = 0; j < art->art_nlevels; j++) {
		art_heap_entry ahe;
		unsigned int bits = art->art_levels[j];
		unsigned int minfringe = (1 << bits);
		unsigned int i;

		/* Compute index */
		i = art_bindex(offset, bits, k);
		offset += bits;

		/* Walk up from fringe to find best match */
		i += minfringe;
		while (i > 1) {
			ahe = SMR_PTR_GET_LOCKED(&heap[i]);
			if (art_heap_entry_is_node(ahe)) {
				struct art_node *an;
				an = art_heap_entry_to_node(ahe);
				if (an != NULL)
					dflt = an;
			}
			i >>= 1;
		}

		/* Check default */
		ahe = SMR_PTR_GET_LOCKED(&heap[ART_HEAP_IDX_DEFAULT]);
		if (ahe != 0) {
			struct art_node *an = art_heap_entry_to_node(ahe);
			if (an != NULL)
				dflt = an;
		}

		/* Descend if fringe points to subtable */
		i = art_bindex(offset - bits, bits, k) + minfringe;
		ahe = SMR_PTR_GET_LOCKED(&heap[i]);
		if (!art_heap_entry_is_node(ahe) && ahe != 0) {
			heap = art_heap_entry_to_heap(ahe);
		} else {
			break;
		}
	}

	return dflt;
}

static unsigned int
art_bindex(unsigned int offset, unsigned int bits, const uint8_t *key)
{
	unsigned int idx = 0;
	unsigned int b;

	for (b = 0; b < bits; b++) {
		unsigned int byte_pos = (offset + b) / 8;
		unsigned int bit_pos = 7 - ((offset + b) % 8);
		idx = (idx << 1) | ((key[byte_pos] >> bit_pos) & 1);
	}
	return idx;
}

/*
 * Exact prefix lookup.
 * Walk the ART tree to find the node with exact (addr, plen).
 */
struct art_node *
art_lookup(struct art *art, const void *addr, unsigned int plen)
{
	art_heap_entry *heap;
	const uint8_t *k = addr;
	unsigned int j, offset = 0;

	heap = SMR_PTR_GET(&art->art_root);
	if (heap == NULL)
		return NULL;

	for (j = 0; j < art->art_nlevels; j++) {
		art_heap_entry ahe;
		unsigned int bits = art->art_levels[j];
		unsigned int minfringe = (1 << bits);
		unsigned int i;

		if (plen <= offset + bits) {
			/* Node lives in this table's non-fringe area */
			unsigned int consumed = plen - offset;
			i = art_bindex(offset, consumed, k);
			i += (1 << consumed);

			ahe = SMR_PTR_GET_LOCKED(&heap[i]);
			if (art_heap_entry_is_node(ahe) && ahe != 0) {
				struct art_node *an;
				an = art_heap_entry_to_node(ahe);
				if (an != NULL && an->an_plen == plen)
					return an;
			}
			return NULL;
		}

		/* Descend */
		i = art_bindex(offset, bits, k) + minfringe;
		offset += bits;
		ahe = SMR_PTR_GET_LOCKED(&heap[i]);
		if (art_heap_entry_is_node(ahe) || ahe == 0)
			return NULL;
		heap = art_heap_entry_to_heap(ahe);
	}

	return NULL;
}

int
art_is_empty(struct art *art)
{
	return (art->art_root == NULL);
}

/*
 * Insert a node into the ART tree AND the zart shadow table.
 * Returns the existing node if the prefix already exists (for mpath).
 */
struct art_node *
art_insert(struct art *art, struct art_node *an)
{
	struct art_node *prev;
	void *zt;

	/* Do the real ART insert first */
	prev = art_insert_art(art, an);

	/* Shadow insert into zart for fast LPM */
	zt = zart_get_table(art);
	if (zt != NULL) {
		struct art_node *target = (prev != NULL) ? prev : an;
		if (art->art_alen == 32)
			zart_table_insert4(zt, target->an_addr,
			    target->an_plen, (size_t)target);
		else if (art->art_alen == 128)
			zart_table_insert6(zt, target->an_addr,
			    target->an_plen, (size_t)target);
	}

	return prev;
}

/*
 * Delete from ART tree AND zart shadow.
 */
struct art_node *
art_delete(struct art *art, const void *addr, unsigned int plen)
{
	struct art_node *an;
	void *zt;

	an = art_delete_art(art, addr, plen);

	/* Remove from zart shadow */
	zt = zart_get_table(art);
	if (zt != NULL && an != NULL) {
		if (art->art_alen == 32)
			zart_table_delete4(zt, addr, plen);
		else if (art->art_alen == 128)
			zart_table_delete6(zt, addr, plen);
	}

	return an;
}

/*
 * Node allocation and lifecycle - unchanged from original.
 */
struct art_node *
art_get(const uint8_t *addr, unsigned int plen)
{
	struct art_node *an;

	an = pool_get(&an_pool, PR_NOWAIT | PR_ZERO);
	if (an == NULL)
		return NULL;

	art_node_init(an, addr, plen);
	return an;
}

void
art_node_init(struct art_node *an, const uint8_t *addr, unsigned int plen)
{
	size_t len;

	len = roundup(plen, 8) / 8;
	KASSERT(len <= sizeof(an->an_addr));
	memcpy(an->an_addr, addr, len);
	an->an_plen = plen;
}

void
art_put(struct art_node *an)
{
	mtx_enter(&art_node_gc_mtx);
	an->an_gc = art_node_gc_list;
	art_node_gc_list = an;
	mtx_leave(&art_node_gc_mtx);

	task_add(systqmp, &art_node_gc_task);
}

void
art_gc(void *null)
{
	struct art_node *an;

	mtx_enter(&art_node_gc_mtx);
	an = art_node_gc_list;
	art_node_gc_list = NULL;
	mtx_leave(&art_node_gc_mtx);

	smr_barrier();

	while (an != NULL) {
		struct art_node *next = an->an_gc;
		pool_put(&an_pool, an);
		an = next;
	}
}

/*
 * ============================================================
 * ITERATION API - delegates to ART tree (not zart)
 * ============================================================
 */

struct art_node *
art_iter_open(struct art *art, struct art_iter *ai)
{
	art_heap_entry *heap = SMR_PTR_GET(&art->art_root);
	struct art_node *an;

	ai->ai_art = art;

	if (heap == NULL) {
		ai->ai_table = NULL;
		return NULL;
	}

	an = art_iter_descend(ai, heap, 0);
	if (an != NULL)
		return an;

	return art_iter_next(ai);
}

static struct art_node *
art_iter_descend(struct art_iter *ai, art_heap_entry *heap,
    art_heap_entry pahe)
{
	struct art_table *at;
	art_heap_entry ahe;

	at = art_heap_to_table(heap);
	ai->ai_table = art_table_ref(ai->ai_art, at);

	ai->ai_j = 1;
	ai->ai_i = 2;

	ahe = SMR_PTR_GET_LOCKED(&heap[ART_HEAP_IDX_DEFAULT]);
	if (ahe != 0 && ahe != pahe)
		return art_heap_entry_to_node(ahe);

	return NULL;
}

struct art_node *
art_iter_next(struct art_iter *ai)
{
	struct art_table *at = ai->ai_table;
	art_heap_entry *heap = at->at_heap;
	art_heap_entry ahe, pahe;
	unsigned int i;

descend:
	if (ai->ai_j < at->at_minfringe) {
		for (;;) {
			while ((i = ai->ai_i) < at->at_minfringe) {
				ai->ai_i = i << 1;
				pahe = SMR_PTR_GET_LOCKED(&heap[i >> 1]);
				ahe = SMR_PTR_GET_LOCKED(&heap[i]);
				if (ahe != 0 && ahe != pahe)
					return art_heap_entry_to_node(ahe);
			}
			ai->ai_j += 2;
			if (ai->ai_j < at->at_minfringe)
				ai->ai_i = ai->ai_j;
			else {
				ai->ai_i = at->at_minfringe;
				break;
			}
		}
	}

	for (;;) {
		unsigned int maxfringe = at->at_minfringe << 1;
		struct art_table *parent;

		while ((i = ai->ai_i) < maxfringe) {
			ai->ai_i = i + 1;
			pahe = SMR_PTR_GET_LOCKED(&heap[i >> 1]);
			ahe = SMR_PTR_GET_LOCKED(&heap[i]);
			if (art_heap_entry_is_node(ahe)) {
				if (ahe != 0 && ahe != pahe)
					return art_heap_entry_to_node(ahe);
			} else {
				struct art_node *an;
				heap = art_heap_entry_to_heap(ahe);
				an = art_iter_descend(ai, heap, pahe);
				if (an != NULL)
					return an;
				at = art_heap_to_table(heap);
				goto descend;
			}
		}

		parent = at->at_parent;
		ai->ai_i = at->at_index + 1;
		art_table_free(ai->ai_art, at);

		ai->ai_table = parent;
		if (parent == NULL)
			break;

		at = parent;
		ai->ai_j = at->at_minfringe;
		heap = at->at_heap;
	}

	return NULL;
}

void
art_iter_close(struct art_iter *ai)
{
	struct art_table *at, *parent;

	for (at = ai->ai_table; at != NULL; at = parent) {
		parent = at->at_parent;
		art_table_free(ai->ai_art, at);
	}
	ai->ai_table = NULL;
}

int
art_walk(struct art *art, int (*f)(struct art_node *, void *), void *arg)
{
	struct art_iter ai;
	struct art_node *an;
	int error = 0;

	ART_FOREACH(an, art, &ai) {
		error = f(an, arg);
		if (error != 0) {
			art_iter_close(&ai);
			return error;
		}
	}
	return 0;
}

/*
 * ============================================================
 * ART TREE INTERNALS - insert/delete/table management
 * These are kept from original art.c, slightly refactored.
 * ============================================================
 */

static struct art_node *
art_insert_art(struct art *art, struct art_node *an)
{
	art_heap_entry *heap;
	struct art_table *at;
	const uint8_t *k = an->an_addr;
	unsigned int plen = an->an_plen;
	unsigned int j, offset = 0;

	if (art->art_root == NULL) {
		at = art_table_get(art, NULL, -1);
		if (at == NULL)
			return NULL;
		art->art_root = at->at_heap;
	}

	heap = art->art_root;

	for (j = 0; j < art->art_nlevels; j++) {
		unsigned int bits = art->art_levels[j];
		unsigned int minfringe = (1 << bits);
		unsigned int i;

		if (plen <= offset + bits) {
			unsigned int consumed = plen - offset;
			i = art_bindex(offset, consumed, k);
			i += (1 << consumed);

			art_heap_entry ahe;
			ahe = SMR_PTR_GET_LOCKED(&heap[i]);
			if (art_heap_entry_is_node(ahe) && ahe != 0) {
				return art_heap_entry_to_node(ahe);
			}

			art_allot(art_heap_to_table(heap), i,
			    heap[i], art_node_to_heap_entry(an));
			return an;
		}

		i = art_bindex(offset, bits, k) + minfringe;
		offset += bits;

		art_heap_entry ahe;
		ahe = SMR_PTR_GET_LOCKED(&heap[i]);
		if (art_heap_entry_is_node(ahe) || ahe == 0) {
			at = art_table_get(art, art_heap_to_table(heap), i);
			if (at == NULL)
				return NULL;
			heap[i] = art_heap_to_heap_entry(at->at_heap);
			heap = at->at_heap;
		} else {
			heap = art_heap_entry_to_heap(ahe);
		}
	}

	return NULL;
}

static struct art_node *
art_delete_art(struct art *art, const void *addr, unsigned int plen)
{
	art_heap_entry *heap;
	const uint8_t *k = addr;
	unsigned int j, offset = 0;

	heap = art->art_root;
	if (heap == NULL)
		return NULL;

	for (j = 0; j < art->art_nlevels; j++) {
		art_heap_entry ahe;
		unsigned int bits = art->art_levels[j];
		unsigned int minfringe = (1 << bits);
		unsigned int i;

		if (plen <= offset + bits) {
			unsigned int consumed = plen - offset;
			struct art_node *an;

			i = art_bindex(offset, consumed, k);
			i += (1 << consumed);

			ahe = SMR_PTR_GET_LOCKED(&heap[i]);
			if (!art_heap_entry_is_node(ahe) || ahe == 0)
				return NULL;

			an = art_heap_entry_to_node(ahe);

			art_allot(art_heap_to_table(heap), i,
			    art_node_to_heap_entry(an), 0);

			/* Try to collapse empty subtables */
			/* TODO: art_table_put for cleanup */

			return an;
		}

		i = art_bindex(offset, bits, k) + minfringe;
		offset += bits;

		ahe = SMR_PTR_GET_LOCKED(&heap[i]);
		if (art_heap_entry_is_node(ahe) || ahe == 0)
			return NULL;
		heap = art_heap_entry_to_heap(ahe);
	}

	return NULL;
}

/*
 * Table management - from original art.c
 */
struct art_table *
art_table_get(struct art *art, struct art_table *parent, unsigned int j)
{
	struct art_table *at;
	art_heap_entry *heap;
	unsigned int level;
	unsigned int bits;
	art_heap_entry dflt;

	if (parent == NULL) {
		level = 0;
		bits = art->art_levels[0];
		dflt = 0;
	} else {
		level = parent->at_level + 1;
		bits = art->art_levels[level];
		dflt = parent->at_heap[j >> 1];
	}

	at = pool_get(&at_pool, PR_NOWAIT | PR_ZERO);
	if (at == NULL)
		return NULL;

	if (bits == 4)
		heap = pool_get(&at_heap_4_pool, PR_NOWAIT | PR_ZERO);
	else
		heap = pool_get(&at_heap_8_pool, PR_NOWAIT | PR_ZERO);

	if (heap == NULL) {
		pool_put(&at_pool, at);
		return NULL;
	}

	at->at_heap = heap;
	at->at_parent = parent;
	at->at_index = j;
	at->at_minfringe = (1 << bits);
	at->at_level = level;
	at->at_bits = bits;
	at->at_refcnt = 1;

	if (parent != NULL)
		at->at_offset = parent->at_offset + parent->at_bits;

	heap[ART_HEAP_IDX_TABLE] = (art_heap_entry)at;
	heap[ART_HEAP_IDX_DEFAULT] = dflt;

	/* Fill all fringe entries with default */
	{
		unsigned int i;
		for (i = 2; i < (at->at_minfringe << 1); i++)
			heap[i] = dflt;
	}

	return at;
}

struct art_table *
art_table_ref(struct art *art, struct art_table *at)
{
	at->at_refcnt++;
	return at;
}

int
art_table_free(struct art *art, struct art_table *at)
{
	if (--at->at_refcnt > 0)
		return 0;

	/* Queue for GC */
	mtx_enter(&art_table_gc_mtx);
	at->at_parent = art_table_gc_list;
	art_table_gc_list = at;
	mtx_leave(&art_table_gc_mtx);

	task_add(systqmp, &art_table_gc_task);
	return 1;
}

void
art_table_gc(void *null)
{
	struct art_table *at;

	mtx_enter(&art_table_gc_mtx);
	at = art_table_gc_list;
	art_table_gc_list = NULL;
	mtx_leave(&art_table_gc_mtx);

	smr_barrier();

	while (at != NULL) {
		struct art_table *next = at->at_parent;
		if (at->at_bits == 4)
			pool_put(&at_heap_4_pool, at->at_heap);
		else
			pool_put(&at_heap_8_pool, at->at_heap);
		pool_put(&at_pool, at);
		at = next;
	}
}

/*
 * art_allot - propagate a new entry through the heap
 */
static void
art_allot(struct art_table *at, unsigned int i,
    art_heap_entry old, art_heap_entry new)
{
	art_heap_entry *heap = at->at_heap;
	unsigned int maxfringe = at->at_minfringe << 1;

	KASSERT(i > 0 && i < maxfringe);

	if (heap[i] != old)
		return;

	heap[i] = new;

	/* Propagate to children in the heap */
	if (i < at->at_minfringe) {
		unsigned int l = i << 1;
		unsigned int r = l + 1;
		if (l < maxfringe) {
			art_allot(at, l, old, new);
			art_allot(at, r, old, new);
		}
	}
}
