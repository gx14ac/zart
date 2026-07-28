/*
 * zart_ktest.c - Kernel test for zart routing table
 *
 * Runs zart insert/lookup/delete tests at boot time and prints results
 * to the console. This proves zart works in kernel space without
 * replacing the production routing table.
 *
 * Place in: /usr/src/sys/net/zart_ktest.c
 * Add to files.conf: file net/zart_ktest.c
 * Link with: zart_kernel_amd64.o
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/malloc.h>

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

/* kernel_panic is defined in art.c (zart_glue) */

static void *
zart_alloc(size_t size, size_t alignment)
{
	return malloc(size, M_TEMP, M_NOWAIT | M_ZERO);
}

static void
zart_free(void *ptr, size_t size)
{
	free(ptr, M_TEMP, size);
}

void zart_ktest_run(void);

void
zart_ktest_run(void)
{
	void *t;
	size_t result;
	int found;
	int pass = 0, fail = 0;

	printf("zart: kernel test starting\n");

	/* Initialize */
	zart_init(zart_alloc, zart_free);

	/* Create table */
	t = zart_table_create();
	if (t == NULL) {
		printf("zart: FAIL - table creation returned NULL\n");
		return;
	}
	printf("zart: table created OK\n");

	/* Test 1: Insert and lookup 10.0.0.0/8 */
	{
		uint8_t addr[] = { 10, 0, 0, 0 };
		zart_table_insert4(t, addr, 8, 100);
	}
	{
		uint8_t addr[] = { 10, 1, 2, 3 };
		found = zart_table_lookup4(t, addr, &result);
		if (found && result == 100) {
			printf("zart: PASS - 10.1.2.3 matched 10.0.0.0/8 (val=%lu)\n",
			    (unsigned long)result);
			pass++;
		} else {
			printf("zart: FAIL - 10.1.2.3 lookup (found=%d, val=%lu)\n",
			    found, (unsigned long)result);
			fail++;
		}
	}

	/* Test 2: More specific prefix wins */
	{
		uint8_t addr[] = { 10, 1, 0, 0 };
		zart_table_insert4(t, addr, 16, 200);
	}
	{
		uint8_t addr[] = { 10, 1, 2, 3 };
		found = zart_table_lookup4(t, addr, &result);
		if (found && result == 200) {
			printf("zart: PASS - 10.1.2.3 matched 10.1.0.0/16 (val=%lu)\n",
			    (unsigned long)result);
			pass++;
		} else {
			printf("zart: FAIL - LPM 10.1.2.3 (found=%d, val=%lu)\n",
			    found, (unsigned long)result);
			fail++;
		}
	}

	/* Test 3: Non-matching address */
	{
		uint8_t addr[] = { 192, 168, 1, 1 };
		found = zart_table_lookup4(t, addr, &result);
		if (!found) {
			printf("zart: PASS - 192.168.1.1 no match (correct)\n");
			pass++;
		} else {
			printf("zart: FAIL - 192.168.1.1 unexpected match (val=%lu)\n",
			    (unsigned long)result);
			fail++;
		}
	}

	/* Test 4: Delete and verify */
	{
		uint8_t addr[] = { 10, 1, 0, 0 };
		zart_table_delete4(t, addr, 16);
	}
	{
		uint8_t addr[] = { 10, 1, 2, 3 };
		found = zart_table_lookup4(t, addr, &result);
		if (found && result == 100) {
			printf("zart: PASS - after delete /16, falls back to /8 (val=%lu)\n",
			    (unsigned long)result);
			pass++;
		} else {
			printf("zart: FAIL - after delete (found=%d, val=%lu)\n",
			    found, (unsigned long)result);
			fail++;
		}
	}

	/* Test 5: IPv6 basic */
	{
		/* 2001:db8::/32 */
		uint8_t addr6[] = { 0x20, 0x01, 0x0d, 0xb8,
		    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		zart_table_insert6(t, addr6, 32, 600);
	}
	{
		uint8_t addr6[] = { 0x20, 0x01, 0x0d, 0xb8,
		    0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1 };
		found = zart_table_lookup6(t, addr6, &result);
		if (found && result == 600) {
			printf("zart: PASS - 2001:db8::1:1 matched /32 (val=%lu)\n",
			    (unsigned long)result);
			pass++;
		} else {
			printf("zart: FAIL - IPv6 lookup (found=%d, val=%lu)\n",
			    found, (unsigned long)result);
			fail++;
		}
	}

	/* Test 6: Table size */
	{
		int sz = zart_table_size(t);
		/* Should have: 10.0.0.0/8 + 2001:db8::/32 = 2 */
		if (sz == 2) {
			printf("zart: PASS - table size=%d\n", sz);
			pass++;
		} else {
			printf("zart: FAIL - table size=%d (expected 2)\n", sz);
			fail++;
		}
	}

	/* Cleanup */
	zart_table_destroy(t);

	printf("zart: kernel test done: %d passed, %d failed\n", pass, fail);
}
