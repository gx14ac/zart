/*
 * zart_fib6.c - Linux IPv6 FIB accelerator using zart
 *
 * Replaces the kernel's fib6 tree walk with zart's fixed 8-bit stride trie.
 * IPv6 LPM resolves in exactly 16 memory accesses.
 *
 * Strategy:
 *   - Netfilter PREROUTING hook resolves dst via zart before kernel routing
 *   - FIB notifier shadows all route add/del into the zart table
 *   - Fallback to stock fib6 on zart miss (NF_ACCEPT without dst set)
 *
 * Build: as a kernel module (.ko) linked with zart_kernel_amd64.o
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/netdevice.h>
#include <linux/ipv6.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv6.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <net/ipv6.h>
#include <net/ip6_fib.h>
#include <net/ip6_route.h>
#include <net/addrconf.h>
#include <net/fib_notifier.h>
#include <net/dst.h>
#include <net/dst_metadata.h>

/* zart C ABI (kernel types) */
extern void zart_init(void *(*)(size_t, size_t), void (*)(void *, size_t));
extern void *zart_table_create(void);
extern void zart_table_destroy(void *);
extern void zart_table_insert6(void *, const u8 *, u8, size_t);
extern bool zart_table_lookup6(const void *, const u8 *, size_t *);
extern void zart_table_delete6(void *, const u8 *, u8);
extern s32  zart_table_size(const void *);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("gx14ac");
MODULE_DESCRIPTION("zart IPv6 FIB accelerator for OpenWrt");

static void *zart_table;
static struct notifier_block zart_fib6_nb;
static struct nf_hook_ops zart_nf_hooks[2];
static atomic64_t zart_hits;
static atomic64_t zart_misses;

void
kernel_panic(const char *msg)
{
	panic("zart: %s", msg);
}

static void *
zart_kmalloc(size_t size, size_t alignment)
{
	(void)alignment;
	return kzalloc(size, GFP_ATOMIC);
}

static void
zart_kfree(void *ptr, size_t size)
{
	(void)size;
	kfree(ptr);
}

/*
 * Netfilter PREROUTING hook.
 *
 * Fires before the kernel does ip6_route_input(). If zart finds the
 * destination prefix, we resolve the dst_entry from fib6_info's per-cpu
 * cache and attach it to the skb. The kernel then skips its own FIB6
 * tree walk entirely.
 */
static unsigned int
zart_nf_prerouting(void *priv, struct sk_buff *skb,
		   const struct nf_hook_state *state)
{
	const struct ipv6hdr *hdr;
	struct fib6_info *f6i;
	struct fib6_nh *fib6_nh;
	struct rt6_info *pcpu_rt;
	size_t result;

	if (!zart_table)
		return NF_ACCEPT;

	hdr = ipv6_hdr(skb);
	if (!hdr)
		return NF_ACCEPT;

	/* Skip multicast/link-local — let the kernel handle those */
	if (ipv6_addr_is_multicast(&hdr->daddr))
		return NF_ACCEPT;
	if (ipv6_addr_type(&hdr->daddr) & IPV6_ADDR_LINKLOCAL)
		return NF_ACCEPT;

	if (skb_valid_dst(skb))
		return NF_ACCEPT;

	if (!zart_table_lookup6(zart_table, (const u8 *)&hdr->daddr, &result)) {
		atomic64_inc(&zart_misses);
		return NF_ACCEPT;
	}

	f6i = (struct fib6_info *)result;

	/* Validate the fib6_info is still alive */
	if (!refcount_read(&f6i->fib6_ref))
		return NF_ACCEPT;

	/* Get the nexthop — flexible array for simple routes, ->nh for nexthop obj */
	if (f6i->nh)
		return NF_ACCEPT; /* nexthop objects are complex; let kernel handle */
	fib6_nh = &f6i->fib6_nh[0];

	if (!fib6_nh->rt6i_pcpu)
		return NF_ACCEPT;

	/* Get per-cpu cached rt6_info */
	pcpu_rt = this_cpu_read(*fib6_nh->rt6i_pcpu);
	if (!pcpu_rt)
		return NF_ACCEPT;

	dst_hold(&pcpu_rt->dst);
	skb_dst_set(skb, &pcpu_rt->dst);

	atomic64_inc(&zart_hits);
	return NF_ACCEPT;
}

/*
 * FIB6 notifier callback.
 */
static int
zart_fib6_event(struct notifier_block *nb, unsigned long event, void *ptr)
{
	struct fib_notifier_info *fni = ptr;
	struct fib6_entry_notifier_info *info;
	struct fib6_info *f6i;
	const struct in6_addr *dst;
	int plen;

	if (fni->family != AF_INET6)
		return NOTIFY_DONE;

	if (event < FIB_EVENT_ENTRY_REPLACE || event > FIB_EVENT_ENTRY_DEL)
		return NOTIFY_DONE;

	if (!zart_table)
		return NOTIFY_DONE;

	info = ptr;
	f6i = info->rt;
	if (!f6i)
		return NOTIFY_DONE;

	dst = &f6i->fib6_dst.addr;
	plen = f6i->fib6_dst.plen;

	switch (event) {
	case FIB_EVENT_ENTRY_REPLACE:
	case FIB_EVENT_ENTRY_APPEND:
		zart_table_insert6(zart_table, (const u8 *)dst, plen,
		    (size_t)f6i);
		break;
	case FIB_EVENT_ENTRY_DEL:
		zart_table_delete6(zart_table, (const u8 *)dst, plen);
		break;
	}

	return NOTIFY_DONE;
}

/*
 * /proc/zart_stats — show hit/miss counters and table size.
 */
static int
zart_stats_show(struct seq_file *m, void *v)
{
	seq_printf(m, "table_size: %d\n", zart_table ? zart_table_size(zart_table) : 0);
	seq_printf(m, "hits: %lld\n", (long long)atomic64_read(&zart_hits));
	seq_printf(m, "misses: %lld\n", (long long)atomic64_read(&zart_misses));
	return 0;
}

static int zart_stats_open(struct inode *inode, struct file *file)
{
	return single_open(file, zart_stats_show, NULL);
}

static const struct proc_ops zart_stats_ops = {
	.proc_open = zart_stats_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

/*
 * /proc/zart_bench — read triggers an in-kernel lookup benchmark.
 * Inserts 1000 prefixes, runs 1M lookups, reports ns/lookup.
 */
static int
zart_bench_show(struct seq_file *m, void *v)
{
	void *bench_tbl;
	u8 prefix[16];
	size_t result;
	u64 start, end, elapsed;
	int i, hits_count = 0;
	const int NUM_PREFIXES = 1000;
	const int NUM_LOOKUPS = 1000000;

	bench_tbl = zart_table_create();
	if (!bench_tbl) {
		seq_printf(m, "error: cannot create table\n");
		return 0;
	}

	/* Insert 1000 /48 prefixes: 2001:db8:0000::/48 .. 2001:db8:03e7::/48 */
	for (i = 0; i < NUM_PREFIXES; i++) {
		memset(prefix, 0, 16);
		prefix[0] = 0x20; prefix[1] = 0x01;
		prefix[2] = 0x0d; prefix[3] = 0xb8;
		prefix[4] = (i >> 8) & 0xff;
		prefix[5] = i & 0xff;
		zart_table_insert6(bench_tbl, prefix, 48, (size_t)(i + 1));
	}

	/* Benchmark: lookup random-ish addresses within those prefixes */
	start = ktime_get_ns();
	for (i = 0; i < NUM_LOOKUPS; i++) {
		memset(prefix, 0, 16);
		prefix[0] = 0x20; prefix[1] = 0x01;
		prefix[2] = 0x0d; prefix[3] = 0xb8;
		prefix[4] = ((i * 7) % NUM_PREFIXES) >> 8;
		prefix[5] = (i * 7) % NUM_PREFIXES;
		prefix[6] = (i >> 8) & 0xff;
		prefix[7] = i & 0xff;
		if (zart_table_lookup6(bench_tbl, prefix, &result))
			hits_count++;
	}
	end = ktime_get_ns();
	elapsed = end - start;

	zart_table_destroy(bench_tbl);

	seq_printf(m, "prefixes: %d\n", NUM_PREFIXES);
	seq_printf(m, "lookups: %d\n", NUM_LOOKUPS);
	seq_printf(m, "hits: %d\n", hits_count);
	seq_printf(m, "total_ns: %llu\n", elapsed);
	seq_printf(m, "ns_per_lookup: %llu\n", elapsed / NUM_LOOKUPS);

	return 0;
}

static int zart_bench_open(struct inode *inode, struct file *file)
{
	return single_open(file, zart_bench_show, NULL);
}

static const struct proc_ops zart_bench_ops = {
	.proc_open = zart_bench_open,
	.proc_read = seq_read,
	.proc_lseek = seq_lseek,
	.proc_release = single_release,
};

static int __init
zart_fib6_init(void)
{
	struct net *net = &init_net;
	int err;

	zart_init(zart_kmalloc, zart_kfree);

	zart_table = zart_table_create();
	if (!zart_table) {
		pr_err("zart: failed to create table\n");
		return -ENOMEM;
	}

	/* Register FIB6 notifier to shadow route table */
	zart_fib6_nb.notifier_call = zart_fib6_event;
	err = register_fib_notifier(net, &zart_fib6_nb, NULL, NULL);
	if (err) {
		pr_err("zart: failed to register fib notifier: %d\n", err);
		zart_table_destroy(zart_table);
		zart_table = NULL;
		return err;
	}

	/* Register Netfilter hooks to intercept IPv6 routing */
	zart_nf_hooks[0].hook = zart_nf_prerouting;
	zart_nf_hooks[0].pf = NFPROTO_IPV6;
	zart_nf_hooks[0].hooknum = NF_INET_PRE_ROUTING;
	zart_nf_hooks[0].priority = NF_IP6_PRI_FIRST;

	zart_nf_hooks[1].hook = zart_nf_prerouting;
	zart_nf_hooks[1].pf = NFPROTO_IPV6;
	zart_nf_hooks[1].hooknum = NF_INET_LOCAL_OUT;
	zart_nf_hooks[1].priority = NF_IP6_PRI_FIRST;

	err = nf_register_net_hooks(net, zart_nf_hooks, 2);
	if (err) {
		pr_err("zart: failed to register nf hooks: %d\n", err);
		unregister_fib_notifier(net, &zart_fib6_nb);
		zart_table_destroy(zart_table);
		zart_table = NULL;
		return err;
	}

	atomic64_set(&zart_hits, 0);
	atomic64_set(&zart_misses, 0);

	proc_create("zart_stats", 0444, NULL, &zart_stats_ops);
	proc_create("zart_bench", 0444, NULL, &zart_bench_ops);

	pr_info("zart: IPv6 FIB accelerator loaded (16-access LPM, nf hook active)\n");
	return 0;
}

static void __exit
zart_fib6_exit(void)
{
	struct net *net = &init_net;

	remove_proc_entry("zart_bench", NULL);
	remove_proc_entry("zart_stats", NULL);

	nf_unregister_net_hooks(net, zart_nf_hooks, 2);
	unregister_fib_notifier(net, &zart_fib6_nb);

	pr_info("zart: unloaded (hits=%lld misses=%lld)\n",
	    (long long)atomic64_read(&zart_hits),
	    (long long)atomic64_read(&zart_misses));

	if (zart_table) {
		zart_table_destroy(zart_table);
		zart_table = NULL;
	}
}

module_init(zart_fib6_init);
module_exit(zart_fib6_exit);
