/*
 * zart_test.c - Minimal test module for zart on Linux/OpenWrt
 *
 * Just loads zart, creates a table, does insert+lookup, prints result.
 * No FIB integration - pure functionality test.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>

/* zart C ABI */
extern void zart_init(void *(*)(size_t, size_t), void (*)(void *, size_t));
extern void *zart_table_create(void);
extern void zart_table_destroy(void *);
extern void zart_table_insert6(void *, const u8 *, u8, size_t);
extern bool zart_table_lookup6(const void *, const u8 *, size_t *);
extern void zart_table_delete6(void *, const u8 *, u8);
extern void zart_table_insert4(void *, const u8 *, u8, size_t);
extern bool zart_table_lookup4(const void *, const u8 *, size_t *);
extern s32  zart_table_size(const void *);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("gx14ac");
MODULE_DESCRIPTION("zart minimal test module");

/*
 * Panic handler for zart.
 */
void
kernel_panic(const char *msg)
{
	panic("zart: %s", msg);
}

static void *
zart_kmalloc(size_t size, size_t alignment)
{
	(void)alignment;
	return kzalloc(size, GFP_KERNEL);
}

static void
zart_kfree(void *ptr, size_t size)
{
	(void)size;
	kfree(ptr);
}

static int __init
zart_test_init(void)
{
	void *tbl;
	size_t result;
	bool found;
	int pass = 0, fail = 0;

	/* IPv4: 10.1.2.3 */
	u8 addr4[] = { 10, 1, 2, 3 };
	/* IPv4 prefix: 10.0.0.0/8 */
	u8 pfx4[] = { 10, 0, 0, 0 };
	/* IPv6: 2001:db8::1 */
	u8 addr6[16] = { 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
	                 0, 0, 0, 0, 0, 0, 0, 1 };
	/* IPv6 prefix: 2001:db8::/32 */
	u8 pfx6[16] = { 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
	                0, 0, 0, 0, 0, 0, 0, 0 };

	pr_info("zart_test: initializing...\n");
	zart_init(zart_kmalloc, zart_kfree);

	tbl = zart_table_create();
	if (!tbl) {
		pr_err("zart_test: FAIL - table create returned NULL\n");
		return -ENOMEM;
	}
	pr_info("zart_test: table created\n");

	/* Test IPv4 */
	zart_table_insert4(tbl, pfx4, 8, 100);
	found = zart_table_lookup4(tbl, addr4, &result);
	if (found && result == 100) {
		pr_info("zart_test: PASS - IPv4 10.1.2.3 -> 10.0.0.0/8 (val=100)\n");
		pass++;
	} else {
		pr_err("zart_test: FAIL - IPv4 lookup (found=%d, val=%lu)\n",
		    found, (unsigned long)result);
		fail++;
	}

	/* Test IPv6 */
	zart_table_insert6(tbl, pfx6, 32, 600);
	found = zart_table_lookup6(tbl, addr6, &result);
	if (found && result == 600) {
		pr_info("zart_test: PASS - IPv6 2001:db8::1 -> 2001:db8::/32 (val=600)\n");
		pass++;
	} else {
		pr_err("zart_test: FAIL - IPv6 lookup (found=%d, val=%lu)\n",
		    found, (unsigned long)result);
		fail++;
	}

	/* Check size */
	if (zart_table_size(tbl) == 2) {
		pr_info("zart_test: PASS - table size = 2\n");
		pass++;
	} else {
		pr_err("zart_test: FAIL - table size = %d (expected 2)\n",
		    zart_table_size(tbl));
		fail++;
	}

	zart_table_destroy(tbl);

	pr_info("zart_test: done - %d passed, %d failed\n", pass, fail);
	return 0;
}

static void __exit
zart_test_exit(void)
{
	pr_info("zart_test: unloaded\n");
}

module_init(zart_test_init);
module_exit(zart_test_exit);
