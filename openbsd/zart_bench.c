/*
 * zart_bench.c - Kernel-space LPM benchmark
 *
 * Measures zart lookup performance with realistic routing table sizes.
 * Outputs cycles/lookup and lookups/sec to dmesg at boot time.
 *
 * Place in: /usr/src/sys/net/zart_bench.c
 * Add to conf/files: file net/zart_bench.c
 * Call from rtable.c after art_boot()
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/malloc.h>
#include <machine/cpu.h>

/* zart C ABI */
extern void zart_init(void *(*)(size_t, size_t), void (*)(void *, size_t));
extern void *zart_table_create(void);
extern void zart_table_destroy(void *);
extern void zart_table_insert4(void *, const uint8_t *, uint8_t, size_t);
extern int  zart_table_lookup4(const void *, const uint8_t *, size_t *);
extern int  zart_table_size(const void *);

static void *
bench_alloc(size_t size, size_t alignment)
{
	(void)alignment;
	return malloc(size, M_TEMP, M_NOWAIT | M_ZERO);
}

static void
bench_free(void *ptr, size_t size)
{
	free(ptr, M_TEMP, size);
}

/*
 * Simple PRNG for deterministic benchmark addresses
 */
static uint32_t bench_seed = 0x12345678;

static uint32_t
bench_rand(void)
{
	bench_seed ^= bench_seed << 13;
	bench_seed ^= bench_seed >> 17;
	bench_seed ^= bench_seed << 5;
	return bench_seed;
}

/*
 * Read TSC for cycle counting on amd64
 */
static inline uint64_t
rdtsc_bench(void)
{
	uint32_t lo, hi;
	__asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
	return ((uint64_t)hi << 32) | lo;
}

void zart_bench_run(void);

void
zart_bench_run(void)
{
	void *t;
	uint64_t start, end, total_cycles;
	int i, found;
	size_t result;
	uint32_t n_prefixes;
	uint32_t n_lookups = 100000;

	printf("zart_bench: starting kernel LPM benchmark\n");

	zart_init(bench_alloc, bench_free);
	t = zart_table_create();
	if (t == NULL) {
		printf("zart_bench: FAILED to create table\n");
		return;
	}

	/*
	 * Benchmark 1: Small table (100 prefixes, like a home router)
	 */
	bench_seed = 0x12345678;
	for (i = 0; i < 100; i++) {
		uint32_t r = bench_rand();
		uint8_t addr[4];
		uint8_t plen;

		addr[0] = (r >> 24) & 0xff;
		addr[1] = (r >> 16) & 0xff;
		addr[2] = (r >> 8) & 0xff;
		addr[3] = 0;
		plen = 8 + (r % 25); /* /8 to /32 */

		zart_table_insert4(t, addr, plen, (size_t)(i + 1));
	}
	n_prefixes = zart_table_size(t);

	/* Warm up */
	bench_seed = 0xdeadbeef;
	for (i = 0; i < 1000; i++) {
		uint32_t r = bench_rand();
		uint8_t addr[4] = {
		    (r >> 24) & 0xff, (r >> 16) & 0xff,
		    (r >> 8) & 0xff, r & 0xff
		};
		zart_table_lookup4(t, addr, &result);
	}

	/* Timed lookups */
	bench_seed = 0xcafebabe;
	found = 0;
	start = rdtsc_bench();
	for (i = 0; i < (int)n_lookups; i++) {
		uint32_t r = bench_rand();
		uint8_t addr[4] = {
		    (r >> 24) & 0xff, (r >> 16) & 0xff,
		    (r >> 8) & 0xff, r & 0xff
		};
		found += zart_table_lookup4(t, addr, &result);
	}
	end = rdtsc_bench();
	total_cycles = end - start;

	printf("zart_bench: [small] %u prefixes, %u lookups, "
	    "%llu cycles total, %llu cycles/lookup, %d hits\n",
	    n_prefixes, n_lookups,
	    (unsigned long long)total_cycles,
	    (unsigned long long)(total_cycles / n_lookups),
	    found);

	zart_table_destroy(t);

	/*
	 * Benchmark 2: Full BGP table (~900k prefixes)
	 */
	t = zart_table_create();
	if (t == NULL) {
		printf("zart_bench: FAILED to create large table\n");
		return;
	}

	bench_seed = 0xfeedface;
	for (i = 0; i < 100000; i++) {
		uint32_t r = bench_rand();
		uint8_t addr[4];
		uint8_t plen;

		addr[0] = (r >> 24) & 0xff;
		addr[1] = (r >> 16) & 0xff;
		addr[2] = (r >> 8) & 0xff;
		addr[3] = r & 0xff;
		plen = 8 + (r % 25);

		zart_table_insert4(t, addr, plen, (size_t)(i + 1));
	}
	n_prefixes = zart_table_size(t);

	/* Warm up */
	bench_seed = 0xbaadf00d;
	for (i = 0; i < 1000; i++) {
		uint32_t r = bench_rand();
		uint8_t addr[4] = {
		    (r >> 24) & 0xff, (r >> 16) & 0xff,
		    (r >> 8) & 0xff, r & 0xff
		};
		zart_table_lookup4(t, addr, &result);
	}

	/* Timed lookups */
	bench_seed = 0xdeadc0de;
	found = 0;
	start = rdtsc_bench();
	for (i = 0; i < (int)n_lookups; i++) {
		uint32_t r = bench_rand();
		uint8_t addr[4] = {
		    (r >> 24) & 0xff, (r >> 16) & 0xff,
		    (r >> 8) & 0xff, r & 0xff
		};
		found += zart_table_lookup4(t, addr, &result);
	}
	end = rdtsc_bench();
	total_cycles = end - start;

	printf("zart_bench: [large] %u prefixes, %u lookups, "
	    "%llu cycles total, %llu cycles/lookup, %d hits\n",
	    n_prefixes, n_lookups,
	    (unsigned long long)total_cycles,
	    (unsigned long long)(total_cycles / n_lookups),
	    found);

	zart_table_destroy(t);
	printf("zart_bench: done\n");
}
