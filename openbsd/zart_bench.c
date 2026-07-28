/*
 * zart_bench.c - ART vs zart direct comparison benchmark
 *
 * Both paths use the same routing table with identical prefixes.
 * art_match() -> zart (4 memory accesses for IPv4)
 * art_match_art_only() -> ART tree walk (up to 7 levels)
 *
 * Uses host addresses known to hit inserted prefixes for 100% hit rate,
 * eliminating hit-count differences between implementations.
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/malloc.h>
#include <machine/cpu.h>

#include <net/art.h>

extern struct art_node *art_match_art_only(struct art *, const void *);

static inline uint64_t
rdtsc_bench(void)
{
	uint32_t lo, hi;
	__asm__ __volatile__("lfence; rdtsc" : "=a"(lo), "=d"(hi) :: "memory");
	return ((uint64_t)hi << 32) | lo;
}

static uint32_t bench_seed;

static uint32_t
bench_rand(void)
{
	bench_seed ^= bench_seed << 13;
	bench_seed ^= bench_seed >> 17;
	bench_seed ^= bench_seed << 5;
	return bench_seed;
}

#define MAX_PREFIXES 1000
#define N_LOOKUPS    100000

struct prefix_entry {
	uint8_t addr[16];
	uint8_t plen;
};

void zart_bench_run(void);

static void
run_comparison(struct art *ar, struct prefix_entry *prefixes, int n_prefixes,
    const char *label)
{
	uint64_t start, end;
	uint64_t art_cycles1, zart_cycles1, art_cycles2, zart_cycles2;
	int i, art_hits, zart_hits;

	/* Warm up both paths equally */
	for (i = 0; i < 2000; i++) {
		int idx = i % n_prefixes;
		art_match(ar, prefixes[idx].addr);
		art_match_art_only(ar, prefixes[idx].addr);
	}

	/* Run 1: zart first, ART second */
	zart_hits = 0;
	bench_seed = 0xcafebabe;
	start = rdtsc_bench();
	for (i = 0; i < N_LOOKUPS; i++) {
		int idx = bench_rand() % n_prefixes;
		if (art_match(ar, prefixes[idx].addr) != NULL)
			zart_hits++;
	}
	end = rdtsc_bench();
	zart_cycles1 = end - start;

	art_hits = 0;
	bench_seed = 0xcafebabe;
	start = rdtsc_bench();
	for (i = 0; i < N_LOOKUPS; i++) {
		int idx = bench_rand() % n_prefixes;
		if (art_match_art_only(ar, prefixes[idx].addr) != NULL)
			art_hits++;
	}
	end = rdtsc_bench();
	art_cycles1 = end - start;

	/* Run 2: ART first, zart second (reverse order) */
	bench_seed = 0xcafebabe;
	start = rdtsc_bench();
	for (i = 0; i < N_LOOKUPS; i++) {
		int idx = bench_rand() % n_prefixes;
		art_match_art_only(ar, prefixes[idx].addr);
	}
	end = rdtsc_bench();
	art_cycles2 = end - start;

	bench_seed = 0xcafebabe;
	start = rdtsc_bench();
	for (i = 0; i < N_LOOKUPS; i++) {
		int idx = bench_rand() % n_prefixes;
		art_match(ar, prefixes[idx].addr);
	}
	end = rdtsc_bench();
	zart_cycles2 = end - start;

	printf("zart_bench: [%s] %d prefixes, %d lookups\n",
	    label, n_prefixes, N_LOOKUPS);
	printf("zart_bench:   run1 (zart,ART): zart=%llu ART=%llu cyc/lookup\n",
	    (unsigned long long)(zart_cycles1 / N_LOOKUPS),
	    (unsigned long long)(art_cycles1 / N_LOOKUPS));
	printf("zart_bench:   run2 (ART,zart): ART=%llu zart=%llu cyc/lookup\n",
	    (unsigned long long)(art_cycles2 / N_LOOKUPS),
	    (unsigned long long)(zart_cycles2 / N_LOOKUPS));
	printf("zart_bench:   avg: zart=%llu ART=%llu cyc/lookup\n",
	    (unsigned long long)((zart_cycles1 + zart_cycles2) / (2 * N_LOOKUPS)),
	    (unsigned long long)((art_cycles1 + art_cycles2) / (2 * N_LOOKUPS)));

	{
		uint64_t avg_zart = (zart_cycles1 + zart_cycles2) / 2;
		uint64_t avg_art = (art_cycles1 + art_cycles2) / 2;
		if (avg_zart > 0) {
			uint64_t ratio_x100 = avg_art * 100 / avg_zart;
			printf("zart_bench:   ratio: ART/zart = %llu.%02llu x\n",
			    (unsigned long long)(ratio_x100 / 100),
			    (unsigned long long)(ratio_x100 % 100));
		}
	}

	printf("zart_bench:   hits: zart=%d ART=%d\n", zart_hits, art_hits);
	if (art_hits != zart_hits)
		printf("zart_bench:   WARNING: hit mismatch!\n");
}

static void
zart_bench_ipv4(void)
{
	struct art *ar;
	struct art_node *an;
	struct prefix_entry *prefixes;
	int i, n_prefixes;

	printf("zart_bench: --- IPv4 (alen=32, ART: 8+4×6 levels) ---\n");

	prefixes = malloc(MAX_PREFIXES * sizeof(*prefixes),
	    M_RTABLE, M_NOWAIT | M_ZERO);
	if (prefixes == NULL) {
		printf("zart_bench: malloc failed\n");
		return;
	}

	ar = art_alloc(32);
	if (ar == NULL) {
		printf("zart_bench: art_alloc failed\n");
		free(prefixes, M_RTABLE, MAX_PREFIXES * sizeof(*prefixes));
		return;
	}

	bench_seed = 0x12345678;
	n_prefixes = 0;
	for (i = 0; i < MAX_PREFIXES; i++) {
		uint32_t r = bench_rand();
		uint8_t addr[4];
		uint8_t plen;

		addr[0] = (r >> 24) & 0xff;
		addr[1] = (r >> 16) & 0xff;
		addr[2] = (r >> 8) & 0xff;
		addr[3] = (r) & 0xff;
		plen = 8 + (r % 25); /* /8 to /32 */

		an = art_get(addr, plen);
		if (an == NULL)
			continue;
		an->an_value = (void *)(uintptr_t)(i + 1);
		if (art_insert(ar, an) == an) {
			prefixes[n_prefixes].addr[0] = addr[0];
			prefixes[n_prefixes].addr[1] = addr[1];
			prefixes[n_prefixes].addr[2] = addr[2];
			prefixes[n_prefixes].addr[3] = addr[3];
			prefixes[n_prefixes].plen = plen;
			n_prefixes++;
		} else {
			art_put(an);
		}
	}

	printf("zart_bench: inserted %d/%d prefixes\n", n_prefixes, MAX_PREFIXES);

	if (n_prefixes > 0)
		run_comparison(ar, prefixes, n_prefixes, "ipv4-full");

	if (n_prefixes > 50)
		run_comparison(ar, prefixes, 50, "ipv4-small-50");

	free(prefixes, M_RTABLE, MAX_PREFIXES * sizeof(*prefixes));
}

static void
zart_bench_ipv6(void)
{
	struct art *ar;
	struct art_node *an;
	struct prefix_entry *prefixes;
	int i, n_prefixes;

	printf("zart_bench: --- IPv6 (alen=128, ART: 4-bit×32 levels) ---\n");

	prefixes = malloc(MAX_PREFIXES * sizeof(*prefixes),
	    M_RTABLE, M_NOWAIT | M_ZERO);
	if (prefixes == NULL) {
		printf("zart_bench: malloc failed\n");
		return;
	}

	ar = art_alloc(128);
	if (ar == NULL) {
		printf("zart_bench: art_alloc(128) failed\n");
		free(prefixes, M_RTABLE, MAX_PREFIXES * sizeof(*prefixes));
		return;
	}

	bench_seed = 0xdeadbeef;
	n_prefixes = 0;
	for (i = 0; i < MAX_PREFIXES; i++) {
		uint8_t addr[16];
		uint8_t plen;
		uint32_t r;
		int b;

		for (b = 0; b < 16; b += 4) {
			r = bench_rand();
			addr[b]   = (r >> 24) & 0xff;
			addr[b+1] = (r >> 16) & 0xff;
			addr[b+2] = (r >> 8) & 0xff;
			addr[b+3] = (r) & 0xff;
		}
		r = bench_rand();
		plen = 16 + (r % 113); /* /16 to /128 */

		an = art_get(addr, plen);
		if (an == NULL)
			continue;
		an->an_value = (void *)(uintptr_t)(i + 1);
		if (art_insert(ar, an) == an) {
			memcpy(prefixes[n_prefixes].addr, addr, 16);
			prefixes[n_prefixes].plen = plen;
			n_prefixes++;
		} else {
			art_put(an);
		}
	}

	printf("zart_bench: inserted %d/%d prefixes\n", n_prefixes, MAX_PREFIXES);

	if (n_prefixes > 0)
		run_comparison(ar, prefixes, n_prefixes, "ipv6-full");

	if (n_prefixes > 50)
		run_comparison(ar, prefixes, 50, "ipv6-small-50");

	free(prefixes, M_RTABLE, MAX_PREFIXES * sizeof(*prefixes));
}

void
zart_bench_run(void)
{
	printf("zart_bench: === ART vs zart direct comparison ===\n");
	zart_bench_ipv4();
	zart_bench_ipv6();
	printf("zart_bench: === done ===\n");
}
