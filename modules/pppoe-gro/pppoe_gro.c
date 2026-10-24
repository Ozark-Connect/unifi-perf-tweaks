// SPDX-License-Identifier: GPL-2.0
/*
 * pppoe_gro.c - GRO/GSO for PPPoE session frames as a standalone add-on module.
 *
 * Backport of "net: pppoe: implement GRO/GSO support" by Felix Fietkau and
 * Qingfang Deng, merged in Linux 7.2 as commit 55a5d8fca836
 * ("net: pppoe: implement GRO/GSO support", applied by Paolo Abeni,
 * Tested-by Pablo Neira Ayuso). Targets the UniFi UCG-Fiber / UCG-Ultra vendor
 * kernels 5.4.213-ui-ipq9574 / -ipq5322 (QSDK based).
 *
 * Why an add-on module instead of a patched pppoe.ko: the vendor pppoe.ko
 * exports QCA-specific symbols (pppoe_channel_addressing_get, ...) that
 * qca-nss-sfe, ecm and qca-nss-ppe-pppoe-mgr import, and its source is not
 * public. This module only registers a packet_offload for ETH_P_PPP_SES; the
 * vendor pppoe_rcv() stays untouched. Because gro_complete() rewrites
 * phdr->length to the aggregated payload length, pppoe_rcv()'s
 * pskb_trim_rcsum(skb, ph->length) becomes a no-op on aggregated skbs
 * (upstream instead adjusted pppoe_rcv() itself).
 *
 * Differences to the upstream commit:
 *  - 5.4 API: skb_gro_header_fast()/skb_gro_header_slow() instead of
 *    skb_gro_header(), callbacks called directly instead of INDIRECT_CALL_INET
 *  - gro_complete refuses (-E2BIG) instead of clamping an aggregate whose
 *    payload would not fit the u16 length field; on 5.4 GRO caps skb->len
 *    at 64 KiB so this never triggers, but a clamped length would make the
 *    vendor pppoe_rcv() trim the aggregate
 *  - gso_segment clears all GSO feature bits, not only NETIF_F_GSO_SOFTWARE
 *  - wan_dev parameter: only frames received on this netdev are aggregated
 *  - per-CPU diagnostic counters in debugfs (pppoe_gro/stats)
 *
 * gso_segment (new in v0.4, from upstream): segments PPPoE aggregates that
 * leave the box still PPPoE-encapsulated (bridged or relayed PPPoE). Inner
 * segmentation is forced to complete software segmentation (all GSO feature
 * bits cleared; upstream clears NETIF_F_GSO_SOFTWARE, which on 5.4 would
 * leave GSO_PARTIAL): a driver must not TSO a PPPoE frame.
 * Locally terminated PPPoE (the UCG-Fiber WAN case) never reaches this path.
 *
 * Status: v0.3 in production on a UCG-Fiber since 2026-10-24 (Telekom PPPoE
 * over VLAN 7, Smart Queues on). v0.4 adds gso_segment; test status and
 * measurements are in docs/pppoe-gro.md of unifi-perf-tweaks.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/netdevice.h>
#include <linux/skbuff.h>
#include <linux/if_pppox.h>
#include <linux/ppp_defs.h>
#include <linux/if_ether.h>
#include <linux/moduleparam.h>
#include <linux/string.h>
#include <linux/percpu.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>

#define PPPOE_GRO_HLEN (sizeof(struct pppoe_hdr) + 2)	/* 6 B header + 2 B PPP proto */

static char *wan_dev = "eth6";
module_param(wan_dev, charp, 0444);
MODULE_PARM_DESC(wan_dev, "Only aggregate PPPoE frames received on this netdev (default eth6, required)");

/* ---- diagnostics: per-CPU counters, read via debugfs, no hot-path atomics ---- */
struct pppoe_gro_stats {
	u64 seen;		/* frames handed to gro_receive */
	u64 skip_dev;		/* wrong receive device */
	u64 skip_hdr;		/* header not pullable / not a session frame */
	u64 skip_len;		/* padding or bad length */
	u64 skip_proto;		/* not IPv4/IPv6 */
	u64 skip_noptype;	/* no inner GRO handler */
	u64 passed_v4;		/* handed to inet_gro_receive */
	u64 passed_v6;		/* handed to ipv6_gro_receive */
	u64 complete;		/* gro_complete calls (aggregates leaving GRO) */
	u64 complete_bytes;	/* sum of aggregated skb->len at completion */
	u64 complete_segs;	/* sum of gso_segs at completion */
	u64 complete_err;	/* inner gro_complete failed */
	u64 complete_toolong;	/* would overflow the u16 length field */
	u64 csum_complete;	/* ip_summed == CHECKSUM_COMPLETE on entry */
	u64 csum_unnecessary;	/* ip_summed == CHECKSUM_UNNECESSARY on entry */
	u64 csum_none;		/* ip_summed == CHECKSUM_NONE on entry */
	u64 gso;		/* gso_segment calls (PPPoE-encapsulated egress) */
	u64 gso_err;		/* gso_segment failed */
};
static DEFINE_PER_CPU(struct pppoe_gro_stats, pppoe_gro_stats);
/* GRO callbacks run in NAPI context with BH disabled, so the cheaper
 * __this_cpu ops suffice there. The GSO path can be reached from more
 * contexts (qdisc, nfqueue, ...); it is rare, so it uses the preempt-safe op. */
#define PGS_INC(f) do { __this_cpu_inc(pppoe_gro_stats.f); } while (0)
#define PGS_ADD(f, v) do { __this_cpu_add(pppoe_gro_stats.f, (v)); } while (0)
#define PGS_INC_ANY(f) do { this_cpu_inc(pppoe_gro_stats.f); } while (0)

static struct dentry *pppoe_gro_dbg;

static int pppoe_gro_stats_show(struct seq_file *m, void *v)
{
	struct pppoe_gro_stats sum = {};
	int cpu;

	for_each_possible_cpu(cpu) {
		const struct pppoe_gro_stats *s = per_cpu_ptr(&pppoe_gro_stats, cpu);
		u64 *d = (u64 *)&sum;
		const u64 *src = (const u64 *)s;
		unsigned int i;

		for (i = 0; i < sizeof(sum) / sizeof(u64); i++)
			d[i] += src[i];
	}
#define P(f) seq_printf(m, "%-18s %llu\n", #f, (unsigned long long)sum.f)
	P(seen); P(skip_dev); P(skip_hdr); P(skip_len); P(skip_proto); P(skip_noptype);
	P(passed_v4); P(passed_v6);
	P(complete); P(complete_bytes); P(complete_segs); P(complete_err); P(complete_toolong);
	P(csum_complete); P(csum_unnecessary); P(csum_none);
	P(gso); P(gso_err);
#undef P
	if (sum.complete)
		seq_printf(m, "%-18s %llu\n%-18s %llu\n", "avg_bytes",
			   (unsigned long long)(sum.complete_bytes / sum.complete),
			   "avg_segs",
			   (unsigned long long)(sum.complete_segs / sum.complete));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pppoe_gro_stats);

/* ---- GRO ---- */

static bool pppoe_gro_dev_allowed(const struct sk_buff *skb)
{
	return skb->dev && !strcmp(skb->dev->name, wan_dev);
}

static u16 compare_pppoe_header(const struct pppoe_hdr *a,
				const struct pppoe_hdr *b)
{
	const __be16 *pa = (const __be16 *)(a + 1);	/* PPP protocol behind the header */
	const __be16 *pb = (const __be16 *)(b + 1);

	return (__force __u16)((a->sid ^ b->sid) | (*pa ^ *pb));
}

static __be16 pppoe_hdr_proto(const struct pppoe_hdr *phdr)
{
	switch (*(const __be16 *)(phdr + 1)) {
	case cpu_to_be16(PPP_IP):
		return cpu_to_be16(ETH_P_IP);
	case cpu_to_be16(PPP_IPV6):
		return cpu_to_be16(ETH_P_IPV6);
	default:
		return 0;
	}
}

/*
 * Called from dev_gro_receive(), which already holds rcu_read_lock() around
 * the offload callback (verified in the QSDK 5.4 dev.c), so no nested RCU here.
 */
static struct sk_buff *pppoe_gro_receive(struct list_head *head,
					 struct sk_buff *skb)
{
	const struct packet_offload *ptype;
	unsigned int hlen, off_pppoe;
	struct sk_buff *pp = NULL;
	struct pppoe_hdr *phdr;
	struct sk_buff *p;
	__be16 type;
	int flush = 1;

	PGS_INC(seen);
	if (!pppoe_gro_dev_allowed(skb)) {
		PGS_INC(skip_dev);
		goto out;
	}

	off_pppoe = skb_gro_offset(skb);
	hlen = off_pppoe + PPPOE_GRO_HLEN;
	phdr = skb_gro_header_fast(skb, off_pppoe);
	if (skb_gro_header_hard(skb, hlen)) {
		phdr = skb_gro_header_slow(skb, hlen, off_pppoe);
		if (unlikely(!phdr)) {
			PGS_INC(skip_hdr);
			goto out;
		}
	}

	/* only session packets (ver 1, type 1, code 0) */
	if (*(const __be16 *)phdr != cpu_to_be16(0x1100)) {
		PGS_INC(skip_hdr);
		goto out;
	}

	/* ignore packets with padding or invalid length */
	if (skb_gro_len(skb) != be16_to_cpu(phdr->length) + sizeof(*phdr)) {
		PGS_INC(skip_len);
		goto out;
	}

	type = pppoe_hdr_proto(phdr);
	if (!type) {
		PGS_INC(skip_proto);
		goto out;
	}

	ptype = gro_find_receive_by_type(type);
	if (!ptype) {
		PGS_INC(skip_noptype);
		goto out;
	}

	switch (skb->ip_summed) {
	case CHECKSUM_COMPLETE:    PGS_INC(csum_complete); break;
	case CHECKSUM_UNNECESSARY: PGS_INC(csum_unnecessary); break;
	default:                   PGS_INC(csum_none); break;
	}

	flush = 0;

	list_for_each_entry(p, head, list) {
		const struct pppoe_hdr *phdr2;

		if (!NAPI_GRO_CB(p)->same_flow)
			continue;

		phdr2 = (const struct pppoe_hdr *)(p->data + off_pppoe);
		if (compare_pppoe_header(phdr, phdr2))
			NAPI_GRO_CB(p)->same_flow = 0;
	}

	skb_gro_pull(skb, PPPOE_GRO_HLEN);
	skb_gro_postpull_rcsum(skb, phdr, PPPOE_GRO_HLEN);

	if (type == cpu_to_be16(ETH_P_IP))
		PGS_INC(passed_v4);
	else
		PGS_INC(passed_v6);

	pp = ptype->callbacks.gro_receive(head, skb);

out:
	skb_gro_flush_final(skb, pp, flush);
	return pp;
}

/* Called from napi_gro_complete(), also under rcu_read_lock(). */
static int pppoe_gro_complete(struct sk_buff *skb, int nhoff)
{
	struct pppoe_hdr *phdr = (struct pppoe_hdr *)(skb->data + nhoff);
	const struct packet_offload *ptype;
	__be16 type = pppoe_hdr_proto(phdr);
	unsigned int payload;
	int err = -ENOENT;

	ptype = gro_find_complete_by_type(type);
	if (ptype)
		err = ptype->callbacks.gro_complete(skb, nhoff + PPPOE_GRO_HLEN);

	if (err) {
		PGS_INC(complete_err);
		return err;
	}

	/*
	 * Rewrite the PPPoE length field so the (unmodified, vendor) pppoe_rcv()
	 * sees a consistent header and does not trim the aggregate back to the
	 * first segment's length. Payload = everything after the 6-byte header,
	 * including the 2-byte PPP protocol field. GRO on 5.4 caps aggregates at
	 * 65535 bytes of skb->len, so the u16 field fits; guard anyway.
	 */
	payload = skb->len - nhoff - sizeof(*phdr);
	if (unlikely(payload > 0xffff)) {
		PGS_INC(complete_toolong);
		return -E2BIG;
	}
	phdr->length = cpu_to_be16(payload);

	PGS_INC(complete);
	PGS_ADD(complete_bytes, skb->len);
	PGS_ADD(complete_segs, skb_is_gso(skb) ? skb_shinfo(skb)->gso_segs : 1);
	return 0;
}

/*
 * GSO for PPPoE-encapsulated aggregates, ported from Linux 7.2
 * pppoe_gso_segment(). Called from skb_mac_gso_segment() under
 * rcu_read_lock() with skb->data at the PPPoE header.
 */
static struct sk_buff *pppoe_gso_segment(struct sk_buff *skb,
					 netdev_features_t features)
{
	struct sk_buff *segs = ERR_PTR(-EINVAL);
	const struct packet_offload *ptype;
	struct pppoe_hdr *phdr;
	__be16 orig_type, type;
	int len, nhoff;

	PGS_INC_ANY(gso);
	skb_reset_network_header(skb);
	nhoff = skb_network_header(skb) - skb_mac_header(skb);

	if (unlikely(!pskb_may_pull(skb, PPPOE_GRO_HLEN)))
		goto out;

	phdr = (struct pppoe_hdr *)skb_network_header(skb);
	type = pppoe_hdr_proto(phdr);
	ptype = gro_find_complete_by_type(type);
	if (!ptype || !ptype->callbacks.gso_segment)
		goto out;

	orig_type = skb->protocol;
	__skb_pull(skb, PPPOE_GRO_HLEN);
	/* Upstream clears NETIF_F_GSO_SOFTWARE. On 5.4 that leaves
	 * NETIF_F_GSO_PARTIAL, with which skb_segment() can still emit large
	 * segments; clear every GSO bit so segmentation is complete. */
	features &= ~NETIF_F_GSO_MASK;
	segs = ptype->callbacks.gso_segment(skb, features);
	if (IS_ERR_OR_NULL(segs))
		goto out;

	skb = segs;
	do {
		phdr = (struct pppoe_hdr *)(skb_mac_header(skb) + nhoff);
		len = skb->len - (nhoff + sizeof(*phdr));
		phdr->length = cpu_to_be16(len);
		skb->network_header = (u8 *)phdr - skb->head;
		skb->protocol = orig_type;
		skb_reset_mac_len(skb);
	} while ((skb = skb->next));

out:
	if (IS_ERR_OR_NULL(segs))
		PGS_INC_ANY(gso_err);
	return segs;
}

static struct packet_offload pppoe_packet_offload __read_mostly = {
	.type = cpu_to_be16(ETH_P_PPP_SES),
	.priority = 20,
	.callbacks = {
		.gro_receive = pppoe_gro_receive,
		.gro_complete = pppoe_gro_complete,
		.gso_segment = pppoe_gso_segment,
	},
};

static int __init pppoe_gro_init(void)
{
	if (!wan_dev || !wan_dev[0] || strlen(wan_dev) >= IFNAMSIZ) {
		pr_err("pppoe_gro: wan_dev must name the PPPoE receive device\n");
		return -EINVAL;
	}
	pppoe_gro_dbg = debugfs_create_dir("pppoe_gro", NULL);
	if (!IS_ERR_OR_NULL(pppoe_gro_dbg))
		debugfs_create_file("stats", 0444, pppoe_gro_dbg, NULL,
				    &pppoe_gro_stats_fops);
	dev_add_offload(&pppoe_packet_offload);
	pr_info("pppoe_gro: GRO/GSO offload for ETH_P_PPP_SES registered (v0.4, prio %d, wan_dev=%s)\n",
		pppoe_packet_offload.priority, wan_dev);
	return 0;
}

static void __exit pppoe_gro_exit(void)
{
	dev_remove_offload(&pppoe_packet_offload);
	debugfs_remove_recursive(pppoe_gro_dbg);
	pr_info("pppoe_gro: GRO/GSO offload for ETH_P_PPP_SES removed\n");
}

module_init(pppoe_gro_init);
module_exit(pppoe_gro_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Felix Fietkau, Qingfang Deng (upstream GRO/GSO); 5.4 add-on backport by Ben Busche");
MODULE_DESCRIPTION("PPPoE session GRO/GSO offload (backport of Linux 7.2 commit 55a5d8fca836)");
MODULE_VERSION("0.4");
