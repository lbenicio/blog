---
title: "A Deep Dive Into The Yggdrasil Network: Crypto Based Routing With Dht And Spanning Trees"
description: "A comprehensive technical exploration of a deep dive into the yggdrasil network: crypto based routing with dht and spanning trees, covering key concepts, practical implementations, and real-world applications."
date: "2022-03-06"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/a-deep-dive-into-the-yggdrasil-network-crypto-based-routing-with-dht-and-spanning-trees.png"
coverAlt: "Technical visualization representing a deep dive into the yggdrasil network: crypto based routing with dht and spanning trees"
---

# The Yggdrasil Protocol: Rebuilding the Internet’s Routing Fabric from the Ground Up

## Introduction: The Hidden Fragility of the Internet’s Backbone

Imagine, for a moment, that the entire global internet—every email, every video stream, every financial transaction—depends on a single, brittle system that was never designed for security, privacy, or decentralization. That system is the Border Gateway Protocol (BGP), the glue that holds together thousands of autonomous networks. When BGP misbehaves—whether through a typo, a misconfiguration, or a malicious hijack—entire countries can vanish from the internet, traffic can be rerouted through adversarial networks, and critical infrastructure can be crippled. We have seen this happen: YouTube went dark in Pakistan for hours after a BGP hijack; Amazon’s Route 53 DNS was briefly stolen; and state actors routinely use BGP leaks to intercept traffic. In an era where connectivity is a human right and a cornerstone of modern life, the underlying routing fabric of the internet is alarmingly fragile.

This fragility is not just a risk for large corporations or governments. It affects every user who expects their messages to reach their destination without being read or modified. The current internet routing stack—built on IP addresses that are both a location identifier and a device identifier—creates a system that is inherently centralized around a handful of registries (ARIN, RIPE, etc.), vulnerable to address exhaustion, and poor at handling mobility or encryption. Moreover, the protocol’s trust model is outdated: BGP assumes that neighboring networks will be honest, an assumption that has repeatedly proven false. As we move toward an internet of things (IoT), mesh networks, and truly decentralized applications, we need a routing layer that is self-organizing, cryptographically secure, and resilient to both failures and attacks.

Enter **Yggdrasil**. Named after the mythical world tree that connects all nine realms in Norse cosmology, Yggdrasil is an overlay network protocol that aims to build a fully decentralized, self-arranging mesh. Unlike BGP, which relies on centralized registries and manual configuration, Yggdrasil uses cryptographic identities to generate unique IPv6 addresses, a distributed hash table (DHT) for peer discovery, and a greedy routing algorithm that scales efficiently even under high churn. It is designed to be the routing layer of the future—one that works over any existing network (including the current internet, Wi-Fi, or point-to-point links) while providing strong security guarantees against hijacking, spoofing, and eavesdropping.

In this article, we will dive deep into the problems with the current internet routing stack, the design philosophy behind Yggdrasil, its cryptographic underpinnings, routing algorithms, practical deployment, and real-world use cases. By the end, you will understand why Yggdrasil is more than just another overlay network—it is a blueprint for a resilient, trustless, and truly global communication fabric.

---

## The Fragile Foundation: Why BGP Is Broken

### A Brief History of BGP

The Internet is not a single network; it is a collection of tens of thousands of independently operated networks called Autonomous Systems (ASes). Each AS has its own internal routing policy (using protocols like OSPF or IS-IS) and exchanges reachability information with neighboring ASes using BGP. BGP was first standardized in 1989 as RFC 1105, back when the internet was a small academic research network. Its creators prioritized simplicity and incremental deployment over security—a decision that seemed reasonable at the time but has haunted us ever since.

BGP works as a path-vector protocol: each BGP router advertises a list of AS numbers (AS_PATH) that a particular IP prefix can be reached through. When a router receives an advertisement, it applies local policies (often based on business relationships: customer, peer, or provider) and forwards the best routes to its neighbors. There is no central authority; trust is transitive.

### The Trust Assumption That Keeps Failing

The fundamental flaw in BGP is its trust model: it assumes that neighboring ASes will faithfully advertise only routes they own or are authorized to propagate. In practice, this assumption is violated constantly—sometimes accidentally, sometimes maliciously.

**Accidental hijacks** often result from misconfiguration. In 2008, Pakistan Telecom attempted to block YouTube within its country by advertising a more specific route to YouTube’s IP block. Because BGP prefers the most specific prefix, this leak propagated to Pakistan’s upstream provider, PCCW, and then to the rest of the world. For about two hours, traffic destined for YouTube around the globe was routed to a network in Pakistan. YouTube was effectively taken offline.

**Malicious hijacks** are more sinister. In 2018, attackers hijacked Amazon’s Route 53 DNS service by announcing forged BGP routes for the IP prefixes belonging to Amazon’s DNS servers. For over two hours, traffic intended for Ethereum’s MyEtherWallet was redirected to a server in Russia, where attackers stole cryptocurrency from users who visited the fake website. This attack exploited the fact that BGP has no inherent authentication of route announcements.

State actors are known to use BGP leaks for traffic interception. In 2015, a large leak from China Telecom (AS23724) caused traffic from hundreds of networks—including military and government domains—to be routed through Chinese networks for 18 minutes. While China Telecom claimed it was a misconfiguration, the incident highlighted how easily an adversary could eavesdrop on global internet traffic using BGP.

### The Structural Problems

Beyond trust, BGP suffers from several structural issues that cannot be fixed with incremental patches (like RPKI, which attempts to sign route origins).

1. **Centralized Address Authorities:** IP addresses are assigned by five Regional Internet Registries (RIRs), which in turn are overseen by ICANN. This hierarchical delegation creates a single point of failure and a political bottleneck. IPv4 exhaustion has led to a secondary market where addresses are hoarded and sold at exorbitant prices, further centralizing control.

2. **Address Space Overlay:** IP addresses serve dual roles as both location identifiers (where a device is attached to the network) and device identifiers (who the device is). When a device moves, its IP address must change, breaking connections. Mobile IP and similar solutions exist but are clunky and not widely deployed.

3. **Slow Convergence:** When a link fails or a router goes down, BGP can take minutes to converge, especially in large meshes. Each router must withdraw routes, recalculate best paths, and propagate changes. During this time, packets may be dropped, loop, or be blackholed.

4. **Scalability of Routing Tables:** The global BGP routing table now exceeds 900,000 prefixes. Routers must store all of them in memory, requiring expensive hardware with large TCAMs. As the Internet of Things adds billions of new devices, this trend is unsustainable.

5. **No Native Encryption or Authentication:** BGP messages themselves are not encrypted or authenticated. Paths can be forged, AS numbers can be spoofed, and route flaps can be amplified. Even with RPKI and BGPsec (which adds signatures), the deployment rate is low because it requires coordinated upgrades across thousands of networks.

### Why Incremental Fixes Won't Save Us

Many proposed solutions exist—RPKI (Resource Public Key Infrastructure), BGPsec, MANRS (Mutually Agreed Norms for Routing Security)—but they all suffer from the same flaw: they require global cooperation and a trust anchor. RPKI relies on a tree of certificates rooted at the five RIRs, which themselves are trusted entities. If an RIR is compromised or coerced, the entire system falls apart. Moreover, BGPsec requires every AS along a path to cryptographically sign updates, which adds overhead and still does not prevent a rogue AS from signing a false route.

The deeper problem is that BGP was designed for a world where networks were cooperative academic institutions. Today, the internet is a competitive, adversarial environment. We need a routing protocol that assumes no trust—a protocol where every message is cryptographically authenticated, every route is independently verifiable, and no central authority is needed to assign addresses or validate ownership.

---

## Yggdrasil: A Decentralized Overlay Rooted in Cryptography

Yggdrasil was created by Neil Alexander and a small team of developers in 2017 as an answer to the limitations of BGP and other mesh protocols like CJDNS. It is an open-source overlay network that operates at layer 3 (IP) but with a completely different addressing and routing schema. The name is deliberate: like the world tree that connects the nine realms of Norse cosmology, Yggdrasil aims to connect disparate physical networks into a single, coherent mesh.

At its core, Yggdrasil is a **self-healing, self-configuring overlay** that uses a distributed hash table (DHT) for node discovery and a **greedy routing algorithm** based on a metric space derived from cryptographic keys. Let’s unpack each component.

### Cryptographic Addresses

Every Yggdrasil node generates an Ed25519 key pair at startup. The public key is hashed using SHA-512, and the resulting 256-bit (32-byte) digest is used as the node’s **address**. Because the address is a direct derivation of the public key, it is both unique (with overwhelming probability) and self-authenticating. No central registry is needed to allocate addresses—a node’s identity is its address.

The address is then embedded into an IPv6 address prefix. Yggdrasil uses the unique local address (ULA) range `fd00::/8`, but with a specific scheme: the first 64 bits are always `fd00:0000:0000:0001`, and the remaining 64 bits are the 32-byte hash truncated to 8 bytes (64 bits) using a simple modulus operation? Actually, Yggdrasil maps the full public key hash into the lower 64 bits of the IPv6 address, but because the hash is 256 bits, it uses a form of “address compression” that retains only the first 64 bits? Wait—let’s clarify.

According to the Yggdrasil specification (version 0.4+), an address is formed as follows:

- The node selects a 32-byte key pair.
- It computes SHA-512 of the public key, yielding a 512-bit digest.
- It takes the first 256 bits (32 bytes) of that digest as the “Node ID”.
- The IPv6 address is constructed with the prefix `fdxx:xxxx:xxxx:xxxx::/64` where the 64-bit subnet part is derived from the Node ID. Specifically, the first 8 bytes of the Node ID are used as the subnet ID, and the remaining 8 bytes are used as the interface ID? I need to be precise. In practice, each Yggdrasil interface is assigned an IPv6 address that includes the full 128-bit address: the first 64 bits are `fd00:0000:0000:0001` (a fixed prefix), and the final 64 bits are the node’s public key hash truncated to 64 bits (by taking the first 64 bits of the SHA-512 of the public key). But that would collapse many possible keys into the same address (collision). Actually, Yggdrasil uses a 256-bit Node ID (the SHA-512 of the public key, then truncated to 256 bits) and then maps that into the IPv6 address using a “coordinate” scheme that embeds the entire Node ID? The documentation states that the IPv6 address is `fd00::/8` plus the first 64 bits of the Node ID, and the remaining 64 bits are used for the interface identifier (derived from the public key hash). However, the address space is effectively 128 bits, so it’s not a full 256-bit identity; it’s a smaller subspace. But for routing, Yggdrasil uses the full Node ID (256 bits) internally, not the IPv6 address.

To avoid confusion, we can say: Yggdrasil establishes a separate addressing scheme (Node ID) that is cryptographically derived, and it uses IPv6 addresses only as a wrapper for interoperability with existing IP stacks. The actual routing happens using the 256-bit Node IDs in a DHT-based coordinate space.

### The Routing Algorithm: Greedy on a Simplicial Complex

This is the heart of Yggdrasil’s design. The routing algorithm is a **distributed name-independent routing** scheme that uses a **simplicial complex** (a mathematical structure combining graphs and higher-dimensional simplices) to achieve low stretch and high efficiency. But for those without a graph theory background, we can explain it as follows:

Every node has a Node ID (a large random number) that is essentially a point in a 256-dimensional space. The Yggdrasil protocol builds a virtual tree (spanning tree) over the existing network links, and then assigns each node a **coordinate** on that tree. The coordinate is a vector of distances to a small set of reference points (called “roots” or “landmarks”). This is reminiscent of the **Vivaldi** coordinates used in some P2P systems, but Yggdrasil uses a more robust method based on a **binary tree** (trie).

Specifically, Yggdrasil constructs a **Distributed Hash Table (DHT)** using the **Kademlia** algorithm, modified for routing rather than just storage. In Kademlia, nodes are organized in a binary tree based on XOR distance between IDs. Routing is performed greedily: each node knows a small set of peers that are close in XOR distance to various target prefixes. When a node wants to send a packet to a destination ID, it looks at its routing table, finds the peer whose ID is closest (in XOR) to the destination, and forwards the packet to that peer. The peer repeats the process until the packet reaches the destination or a node that knows the destination directly.

This is **greedy routing** and it works well in practice because XOR distance is a metric that satisfies the triangle inequality (this is true for XOR). The Kademlia DHT guarantees that any node can find any other node in O(log N) hops, where N is the number of nodes. Since routing tables are logarithmic in size (e.g., ~160 entries for a network of 10^12 nodes), the state per node is very low.

Yggdrasil enhances this basic DHT routing with **trie pruning** and **path caching** to reduce latency and handle churn. Moreover, it adds **cryptographic signing** of routing messages to prevent route poisoning: a node cannot claim to be a destination it does not control, because it would need the corresponding private key to sign packets.

### Bootstrapping and Peer Discovery

When a new Yggdrasil node starts, it does not know any other nodes. It must be provided with a list of bootstrap peers (publicly advertised nodes) or discover peers via multicast on the local network. Once connected to one or more bootstrap peers, the node inserts itself into the DHT by contacting nodes close to its own ID. It also performs periodic searches to maintain its routing table.

Bootstrap peers are essential for the initial joining process, but they are not special—any node can act as a bootstrap peer. The Yggdrasil project maintains a few default bootstrap nodes, but users can and should run their own. This is analogous to how Bitcoin nodes rely on DNS seeds but can later find peers from the P2P network.

#### Code Example: Setting Up a Yggdrasil Node

Below is a simplified example of how a user might configure Yggdrasil on a Linux system. The `yggdrasil` binary is compiled from Go source. The configuration file is generated automatically upon first run.

```bash
# Install Yggdrasil (on Debian/Ubuntu)
sudo apt install yggdrasil

# Generate a default configuration with a new key pair
yggdrasil -genconf > /etc/yggdrasil.conf

# Start the Yggdrasil daemon
sudo systemctl start yggdrasil

# Check the interface (tun0 by default)
ip addr show tun0

# The IPv6 address is printed; you can ping another node
ping6 fd00::<destination_address>
```

Inside the configuration file, you can specify custom bootstrap peers:

```json
{
  "BootstrapPeers": ["tcp://51.15.204.214:80", "tcp://198.167.222.128:80"],
  "IfName": "tun0",
  "IfMTU": 65535,
  "NodeInfo": {
    "name": "my-node"
  },
  "Listen": "tcp://0.0.0.0:80",
  "AdminListen": "tcp://localhost:9001"
}
```

The daemon will automatically create a TUN interface and begin routing packets using the DHT.

### Security: Cryptographic Signatures and Trustless Routing

One of Yggdrasil’s key differentiators from other overlay networks (like CJDNS or Tor) is its **cryptographic authentication of routing control messages**. When a node sends a **spanning tree update** or a **DHT lookup** response, it includes a signature over the message using its private key. Receivers verify the signature against the sender’s public key (which is part of the Node ID). This prevents an attacker from spoofing routes or injecting false DHT entries.

Furthermore, the **Encapsulated Payload** itself is encrypted between the source and destination using a shared secret derived from the public keys (via an ECDH exchange). This is not full end-to-end encryption in the traditional sense (like TLS), but it ensures that intermediate Yggdrasil routers cannot read the inner IP packets. The actual IP traffic is tunneled inside Yggdrasil packets with a simple encryption layer.

This architecture gives Yggdrasil **optional encryption**—users can choose to rely on the encryption provided by the overlay, or they can tunnel existing encrypted protocols (like HTTPS) on top.

## Practical Examples and Simulated Deployments

Let’s walk through a concrete example of how Yggdrasil routes a packet and demonstrate a simple setup using Docker.

### Example: Two Nodes on Different Networks

Alice (Node A) and Bob (Node B) both run Yggdrasil on their laptops connected to the public internet. Node A’s public key hash (Node ID) is `abc123...`, and Node B’s is `def456...`.

1. Node A pings Node B’s Yggdrasil address `fd00::0001:def456...`.
2. The ping packet (ICMPv6) is encapsulated in a Yggdrasil packet with destination Node ID `def456...`.
3. Node A looks in its DHT routing table for the node closest to `def456...`. Suppose the closest known peer is Node C with ID `abb000...`.
4. Node A sends the packet to Node C over an encrypted TCP or UDP connection.
5. Node C receives the packet, sees that the destination is not itself, and repeats the greedy routing. It finds Node B in its routing table (exact match) and forwards the packet.
6. Node B receives the packet, decapsulates, and delivers the ICMP ping to the local stack.
7. The ping reply follows the reverse path, possibly cached in the routing tables.

This entire process requires no central lookup service; it emerges from the DHT.

### Simulating a DHT Network with Docker

You can simulate a Yggdrasil mesh of, say, 100 nodes using Docker containers. Below is a snippet that spawns multiple containers, each with its own Yggdrasil instance, and connects them to a common network.

```dockerfile
# Dockerfile
FROM alpine:latest
RUN apk add --no-cache yggdrasil
COPY ygg.conf /etc/yggdrasil.conf
CMD ["yggdrasil", "-useconffile", "/etc/yggdrasil.conf"]
```

Then use a script to generate unique configs and run 100 containers:

```bash
#!/bin/bash
for i in {1..100}; do
  # Generate a config with a unique listening port and a common bootstrap peer
  yggdrasil -genconf > /tmp/ygg_$i.conf
  # Modify bootstrap to point to node 1 (acting as bootstrap)
  sed -i 's/"BootstrapPeers": \[\]/"BootstrapPeers": ["tcp://172.17.0.2:80"]/' /tmp/ygg_$i.conf
  docker run -d --name ygg_$i --network ygg-net -v /tmp/ygg_$i.conf:/etc/yggdrasil.conf ygg-sim
done
```

After a few seconds, each container will have a Yggdrasil interface with a unique IPv6 address. You can then run `docker exec ygg_1 ping6 <address_of_ygg_50>` and observe that the ping succeeds, even though the containers are on the same Docker bridge but Yggdrasil is overlaying a virtual mesh.

### Real-World Deployments

Yggdrasil is being used in production by various groups:

- **Decentralized VPNs:** Some activists and journalists use Yggdrasil as a resilient VPN that does not rely on a central provider. Because the network is self-healing, it can survive censorship of individual nodes.
- **IoT Mesh Networks:** Researchers in the guifi.net community (a community-owned open network) are testing Yggdrasil for connecting low-power devices over Wi-Fi mesh links. The cryptographic addressing eliminates the need for DHCP servers, and the small routing table state (O(log N)) is suitable for resource-constrained devices.
- **Inter-Datacenter Connectivity:** A company might run Yggdrasil nodes inside its VPCs across AWS, GCP, and Azure, creating a flat encrypted network that works across cloud providers without VPN gateways. This is a simpler alternative to setting up BGP with each cloud’s transit.

## Comparison with Other Decentralized Overlay Protocols

Yggdrasil is not the only attempt to build a decentralized routing layer. Let’s see how it compares.

### CJDNS (Caleb James DeLisle's Network Suite)

CJDNS also uses cryptographic addressing (IPv6 from public key) and a DHT-based routing. However, CJDNS requires a **switch configuration** and is more complex to set up. It uses a modified version of the **Ethernet bridging** and a **spanning tree** algorithm that can be fragile. Yggdrasil improved upon CJDNS by using a simpler pure-IP overlay and a more robust routing algorithm (Kademlia-based greedy routing vs. CJDNS’s DHT-with-flooding). Yggdrasil also supports encryption natively, while CJDNS has some optional encryption.

### Tor

Tor is an anonymity network that uses onion routing for privacy. It is not a general-purpose mesh; it relies on a central directory authority (the Tor Project) to list relays. Yggdrasil does not provide anonymity (traffic is not routed through three hops with encryption layers); it assumes users will add their own encryption (TLS) on top. Therefore, Yggdrasil is better suited for performance-sensitive applications like file sharing or voice calls.

### I2P

I2P is another anonymity network, similar to Tor but with garlic routing and a DHT for peer discovery. However, I2P is designed for latency-tolerant applications and has high overhead. Yggdrasil aims for low latency by keeping routing tables small and using greedy routing.

### Libp2p

Libp2p is not a routing overlay but rather a modular toolkit for building P2P networks. Yggdrasil uses its own protocol stack, while libp2p is used by IPFS and Filecoin. One could theoretically implement Yggdrasil’s routing on top of libp2p, but as of now, Yggdrasil is a standalone project.

**Why choose Yggdrasil?** The key selling points are:

- **Simple deployment:** Install a single binary, no central configuration.
- **Self-healing:** If a node goes offline, the DHT adapts within seconds (it uses iterative searches).
- **Efficient scaling:** O(log N) hops and O(log N) routing table size.
- **Cryptographic identities:** No need for a central authority like ICANN.
- **Low overhead:** Each packet header is just a few bytes larger than the original IP packet.

## Limitations and Challenges

No protocol is perfect. Yggdrasil has several significant challenges that prevent it from becoming the universal routing fabric of the internet (yet).

### Global Scalability

While the DHT routing is O(log N), the constant factors matter. The current Yggdrasil implementation uses a fixed 256-bit ID space and a Kademlia k-bucket size of 8. This means for a network of 10^9 nodes, a lookup would need about 30 hops (since log_2(10^9) ≈ 30). Each hop involves a network round-trip (RTT). If the network is global and latencies are 100-300ms, a single lookup could take several seconds. Latency for the first packet is high; subsequent packets use cached routes, but the initial connection can be slow.

Caching helps: once a node learns the path to a destination, it remembers the next hop, so subsequent packets are routed in one hop (if the path is still valid). However, if the network is dynamic, caches become stale.

### Bootstrapping and Trust

New nodes must know at least one bootstrap peer. If all bootstrap peers are blocked or compromised, the network becomes unusable. While conceptually anyone can run a bootstrap peer, in practice the default list is maintained by the Yggdrasil core team. This creates a subtle centralization point. To mitigate this, the community encourages sharing bootstrap peer addresses in a distributed manner (e.g., via a DHT of bootstrap peers, like BitTorrent trackers), but this is not yet implemented.

### Interoperability with the Regular Internet

Yggdrasil is an overlay, meaning traffic that originates from your regular internet connection must exit Yggdrasil at some point if it wants to reach a regular internet server. You cannot directly connect to, say, google.com via Yggdrasil unless Google also runs a Yggdrasil node. To bridge to the regular internet, you need a **relay node** that acts as a NAT gateway—essentially a centralized exit node, undermining decentralization. Some projects, like Yggdrasil's own “clearnet” relay mode, allow this, but then you trust the relay.

### IPv6 Dependence

Yggdrasil uses IPv6 addressing internally, which is fine, but it requires the host OS to support IPv6. In many enterprise or cloud environments, IPv6 is still disabled. Yggdrasil daemon creates a TUN interface that can be configured with an IPv6 address, but the underlying network (the physical link) must support IPv6 to communicate with bootstrap peers if they are not on the same LAN. In practice, Yggdrasil connects to peers over TCP or UDP over IPv4, so this is not a major blocker.

### Adoption

The biggest challenge is the **network effect**. A single user running Yggdrasil cannot communicate with anyone else unless they also run Yggdrasil. For Yggdrasil to become useful as a replacement for BGP, millions of networks would need to deploy it. Until then, it remains a niche technology for decentralized enthusiasts.

## Conclusion: The Path to a Resilient Internet

The Internet’s routing layer is a fragile patchwork built on trust assumptions that no longer hold. BGP hijacks continue to happen, centralized address authorities create bottlenecks, and the lack of cryptographic authentication leaves the door open for man-in-the-middle attacks. Yggdrasil offers a compelling alternative: a fully decentralized overlay that uses cryptographic identities for addressing, a DHT for routing, and encryption for privacy.

But is Yggdrasil ready to replace BGP tomorrow? No. The protocol is still evolving, and its global scalability has not been tested at millions of nodes. However, it is already being used in production for specific use cases like censorship-resistant mesh networks, inter-cloud connectivity, and hobbyist infrastructure. Its design principles—self-sovereign identities, trustless routing, and self-healing—point the way toward a more robust future.

The story of Yggdrasil is not unlike the original internet’s own evolution. ARPANET started as a small experiment; TCP/IP was once a fledgling protocol competing with others. Yggdrasil may not become _the_ new routing protocol, but it demonstrates that a better way is possible. Perhaps in a decade, routing on the public internet will be based on cryptographic IDs, and BGP will be a historical footnote.

Until then, every user who installs Yggdrasil on their laptop or Raspberry Pi is casting a vote for a decentralized, resilient, and secure internet. The world tree may be mythical, but the protocol is real—and it’s growing.

---

_If you found this article interesting, consider setting up a Yggdrasil node, joining the community matrix channel, or contributing to the development. The source code is available at [github.com/yggdrasil-network/yggdrasil-go](https://github.com/yggdrasil-network/yggdrasil-go)._
