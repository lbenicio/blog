---
title: "Network Topologies for HPC: Fat-Trees, Dragonfly, Torus, and the Cost-Diameter-Bandwidth Optimization"
description: "A rigorous survey of HPC network topologies—fat-tree (InfiniBand), Dragonfly (Cray Cascade), torus (Blue Gene), Slim Fly—analyzing the fundamental tradeoffs in cost, diameter, bisection bandwidth, and fault tolerance."
date: "2024-08-31"
author: "Leonardo Benicio"
tags: ["hpc", "network-topology", "fat-tree", "dragonfly", "torus", "interconnect"]
categories: ["theory", "systems"]
draft: false
cover: "/static/assets/images/blog/network-topologies-hpc-fat-trees-dragonfly-torus.png"
coverAlt: "Diagram comparing fat-tree, Dragonfly, torus, and Slim Fly network topologies, with cost, diameter, and bandwidth annotated."
---

The network is the defining component of a supercomputer. While CPU and GPU performance double every 2-3 years, network performance—bandwidth per link, latency per hop, and bisection bandwidth—improves much more slowly, limited by the physics of signal propagation and the economics of cabling and switching. As a result, the network topology—the pattern of connections between compute nodes—has become the primary determinant of application performance at scale.

A network topology for high-performance computing (HPC) must optimize multiple competing objectives: low diameter (maximum number of hops between any two nodes, which determines worst-case latency), high bisection bandwidth (the minimum bandwidth between two equal partitions of the network, which determines all-to-all communication throughput), low cost (fewer switches and cables), high fault tolerance (the network should degrade gracefully when components fail), and ease of physical layout (cables must fit within racks and across machine room floors).

This article surveys the major network topologies used in HPC systems from the 1990s to the present: the fat-tree (the workhorse of InfiniBand clusters), the torus (used in IBM Blue Gene and Fujitsu K), the Dragonfly (used in Cray Cascade systems), and the Slim Fly (a theoretical near-optimal topology that is beginning to appear in production). For each, we analyze the asymptotic properties—diameter, degree, bisection bandwidth—and the practical considerations that determine real-world performance.

## 1. Topology Fundamentals: Graphs, Radix, and Cost Models

A network is modeled as a graph \(G = (V, E)\) where vertices are switches (or compute nodes, depending on the abstraction level) and edges are links. The key graph-theoretic parameters are:

- **Degree \(\Delta\):** The maximum number of ports per switch. The switch radix (the number of physical ports) is a hard constraint determined by the switch ASIC; higher-radix switches are more expensive and consume more power, but they enable richer topologies.
- **Diameter \(D\):** The maximum shortest-path distance between any two vertices. Diameter determines worst-case latency under minimal routing.
- **Bisection bandwidth \(B\):** The minimum total bandwidth of edges that must be cut to separate the graph into two equal halves. Bisection bandwidth determines the throughput of all-to-all communication patterns (MPI_Alltoall, distributed FFT).

The **cost model** counts the number of switches and cables. For a network of \(N\) endpoints, we typically assume that each switch has \(r\) ports (radix \(r\)), that switches and cables have fixed cost per unit, and that the total cost is proportional to the number of switches plus the number of cables.

The **asymptotic optimality** of a topology is often measured against the Moore bound or the degree-diameter problem: given \(N\) nodes and maximum degree \(\Delta\), what is the minimum possible diameter? The Moore bound states that \(N \leq 1 + \Delta \sum*{i=0}^{D-1} (\Delta-1)^i\), which for large \(\Delta\) gives \(D \approx \log*\Delta N\). Topologies that achieve \(O(\log N)\) diameter with constant degree are considered asymptotically optimal.

## 2. Fat-Tree: The Universal HPC Topology

The fat-tree (Leiserson, 1985) is the dominant topology for InfiniBand-based HPC clusters and is used in roughly 60% of the TOP500 systems. It is a folded Clos network: a multi-stage interconnection network where each stage consists of switches of the same radix, and the bandwidth between stages increases ("fattens") toward the root to avoid congestion.

A \(k\)-ary \(n\)-tree (a common parameterization) has \(n\) levels of switches, each switch having \(2k\) ports (for a 2:1 oversubscription ratio at each level). The topology connects \(N = 2 \cdot k^n\) endpoints with \(n \cdot k^{n-1}\) switches. The diameter is \(2n\) (up from an endpoint to the root and back down), which is \(O(\log N)\)—asymptotically optimal.

The fat-tree's key property is **full bisection bandwidth**: for any partition of the endpoints into two equal halves, there is sufficient bandwidth in the upper-level links to support all-to-all communication between the halves. This is achieved by providing \(k\) parallel paths at each level, which ensures that the link bandwidth scales with the number of endpoints below that level.

### 2.1 Routing in Fat-Trees

Fat-tree routing uses **destination-based hashing** or **adaptive routing** to spread traffic across the multiple parallel paths. The canonical routing algorithm is \(D\)-module \(k\)-ary \(n\)-tree routing (Ohring et al., 1995): each switch forwards packets based on the destination's "tree address," moving up the tree until the destination's subtree is reached, then down. Multiple equal-cost paths are available at each level, and the routing selects among them to balance load.

InfiniBand fat-trees use **static routing** (configured by the OpenSM subnet manager) that computes deterministic routes to avoid deadlock, typically using the **up*/down*** routing algorithm (which prevents cycles by requiring that packets travel up the tree, then down, never going up again after going down). Adaptive routing (where switches dynamically select among multiple output ports based on local congestion information) can improve throughput on adversarial traffic patterns but risks deadlock if not implemented carefully.

### 2.2 Limitations

Fat-trees require a large number of switches and cables: for \(N\) endpoints and full bisection bandwidth, the number of switches is \(O(N \log N / r)\), where \(r\) is the switch radix, and the total cable count is roughly \(N \log_r N\). For large \(N\) (\(10^5\) endpoints, typical of a top-10 supercomputer), the cable count becomes enormous—tens of thousands of cables—which is a physical management challenge (cable weight, cable routing, connector density) and a reliability challenge (each cable is a potential point of failure). This is the primary motivation for exploring topologies with fewer cables, such as Dragonfly and Slim Fly.

## 3. Torus: The Physically Inspired Topology

The \(d\)-dimensional torus (or \(k\)-ary \(d\)-cube) connects nodes in a \(d\)-dimensional grid with wrap-around edges. Each node connects to \(2d\) neighbors (one in each direction along each dimension). A 3D torus was used in the IBM Blue Gene/L (2004) and Blue Gene/P (2007) systems; a 6D torus was used in Fujitsu's K computer (2011) and the Fugaku system (2020), which was the world's fastest supercomputer for several years.

The torus has diameter \(d \cdot \lfloor k/2 \rfloor\) where \(k\) is the number of nodes per dimension (\(k = N^{1/d}\)). The bisection bandwidth is \(2k^{d-1}\) (the cross-section of the torus orthogonal to one dimension). The key advantage of the torus is its **physical locality**: the topology maps naturally to a 3D physical layout (racks arranged in rows and columns), and most cables are short (nearest-neighbor), with only the wrap-around links being long. This reduces cable cost and complexity.

The torus's disadvantage is its high diameter (\(O(N^{1/d})\)), which means that worst-case latency grows as a root of the system size. For large systems, this requires **dimensional adaptive routing** (routing packets along different dimensions based on congestion) and may necessitate **circuit switching** or **wormhole routing** to reduce per-hop latency. The 6D torus of Fugaku uses a combination of virtual channels and adaptive routing to handle the 6-dimensional addressing while keeping the physical wiring manageable (the 6D topology is "folded" onto a 3D physical layout).

## 4. Dragonfly: The Cray Innovation

The Dragonfly topology (Kim, Dally, Scott, and Abts, 2008) was designed to reduce the cost of large HPC networks by using **high-radix switches** and a **hierarchical structure**. The topology is organized into **groups** of switches, with dense (all-to-all) connectivity within each group and a single link (or a few links) connecting each group to every other group. The "dragonfly" name comes from the pattern of inter-group links: each switch in a group connects to exactly one switch in every other group, forming a complete graph of groups.

A Dragonfly with \(a\) switches per group, each of radix \(r = 2a + g - 1\) (where \(g\) is the number of groups), connects \(N = a \cdot g \cdot p\) endpoints (where \(p\) is the number of endpoints per switch). The diameter is 3: endpoint → local switch → remote switch → endpoint. This is significantly lower than a fat-tree of comparable size and cost, because the Dragonfly exploits high-radix switches to achieve global connectivity in fewer hops.

Cray's Cascade systems (XC30, XC40, XC50, 2012-2018) used the Aries interconnect, a Dragonfly variant with 48-port switches organized into groups of 4 switches (192 ports per group). The Dragonfly's low diameter (3 hops) made it particularly effective for latency-sensitive HPC workloads like adaptive mesh refinement and discrete event simulation, where frequent small messages between random pairs of nodes dominated the communication pattern.

### 4.1 Routing Challenges

Dragonfly routing is challenging because the inter-group links are a scarce resource: each inter-group link is shared by many source-destination pairs. A naive routing algorithm (minimal routing, always using the direct inter-group link) creates hotspots on inter-group links that are heavily loaded by the traffic pattern. Dragonfly systems use **adaptive routing** with multiple virtual channels: packets can take indirect paths (going through an intermediate group) if the direct inter-group link is congested. The adaptive routing algorithm balances load across the inter-group links, achieving near-optimal throughput for random permutation traffic.

However, adaptive routing in Dragonfly is prone to **congestion spreading**: when one inter-group link becomes congested, packets that would have used it are diverted to alternative paths, potentially causing congestion on those alternative paths and creating a cascading congestion collapse. The Cray Aries system mitigates this with a sophisticated congestion control mechanism (based on credit-based flow control and explicit congestion notification) that detects incipient congestion and throttles traffic before it spreads.

## 5. Slim Fly: Near-Optimal Topology from Graph Theory

The Slim Fly (Besta et al., 2014) is a theoretical near-optimal topology based on the **McKay-Miller-Širáň graphs** from algebraic graph theory. The Slim Fly achieves diameter 2 (the minimum possible for a non-trivial topology) with switch radix \(r = O(\sqrt{N})\) and \(N\) endpoints. The bisection bandwidth is within a factor of 2 of the theoretically optimal value for a given diameter and radix.

The Slim Fly construction uses **finite fields** to define the connectivity: switches are identified with pairs \((x, y)\) from \(\mathbb{F}\_q \times \mathbb{F}\_q\) for a prime power \(q\), and two switches are connected if \(y_1 - y_2 = (x_1 + x_2) \cdot s\), where \(s\) is a generator of the field. This algebraic construction guarantees that the graph is vertex-transitive (all switches are equivalent) and has the desired diameter and degree properties.

Slim Fly has not seen widespread deployment because it requires switch radices that are not widely available (the optimal radix depends on the system size, and commercial switch ASICs have fixed radices—typically 36, 48, or 64 ports). However, with the emergence of high-radix switches (NVIDIA Quantum-2, 64 ports of 400 Gbps) and the growth of HPC systems to 10^5-10^6 endpoints, Slim Fly is becoming practically realizable. The Rockport Networks NC1225 (2022) uses a Slim Fly-inspired topology with 48-port switches for HPC clusters.

## 6. Topology Comparison and Practical Tradeoffs

| Topology  | Diameter       | Switch Radix       | Cable Count     | Bisection BW   | Physical Layout             |
| --------- | -------------- | ------------------ | --------------- | -------------- | --------------------------- |
| Fat-tree  | \(O(\log N)\)  | \(2k\)             | \(O(N \log N)\) | Full           | Requires structured cabling |
| 3D Torus  | \(O(N^{1/3})\) | 6                  | \(3N\)          | \(O(N^{2/3})\) | Natural 3D mapping          |
| 6D Torus  | \(O(N^{1/6})\) | 12                 | \(6N\)          | \(O(N^{5/6})\) | Challenging folding         |
| Dragonfly | 3              | \(r = 2a + g - 1\) | \(O(N)\)        | \(O(N)\)       | Group-based layout          |
| Slim Fly  | 2              | \(O(\sqrt{N})\)    | \(O(N^{3/2})\)  | Near-optimal   | Algebraic; non-intuitive    |

For current HPC system sizes (10^4-10^6 nodes), Dragonfly and fat-tree dominate because they provide the best balance of low diameter, manageable cost, and compatibility with available switch ASICs. Torus topologies excel at smaller scales or when physical layout constraints dominate (e.g., embedded systems, on-chip networks). Slim Fly is the topology of the future, waiting for high-radix switches and automated cable management to make its theoretical advantages practical.

## 7. The Future: Optical Circuit Switching and Topology Reconfiguration

A radical alternative to fixed topologies is **dynamically reconfigurable networks** using optical circuit switches (OCS). An OCS can establish a direct optical path between any two endpoints by mechanically or electronically steering mirrors (MEMS) or using wavelength-selective switches. The topology can be changed in milliseconds to match the communication pattern of the current workload.

Google's Jupiter network (2022) uses OCS in its data center fabric, dynamically reconfiguring the spine-layer connectivity to match traffic demands. While Jupiter is a data center network (not an HPC system), the technology is directly applicable to HPC. An OCS-based HPC network could present a Dragonfly topology for all-to-all workloads, a ring topology for pipeline-parallel workloads, and a hypercube for stencil computations—all on the same physical fiber plant.

The limiting factor is reconfiguration speed: current OCS technology (MEMS mirrors) has reconfiguration times of 10-100 ms, which is suitable for workload-level adaptation (matching the topology to the application's communication pattern for the duration of a job) but not for packet-level adaptation. Faster OCS technologies (silicon photonics with thermo-optic or electro-optic switching, nanoseconds to microseconds) could enable packet-level topology adaptation, effectively making the network a reconfigurable accelerator for the specific communication pattern of each application phase.

## 8. Dragonfly+: The Cray Cascade Architecture and Adaptive Routing

The Dragonfly topology, invented by Kim, Dally, Scott, and Abts (ISCA 2008) and commercialized in the Cray XC series (Cascade architecture), extends the Dragonfly concept with _adaptive routing_ that dynamically selects between minimal and non-minimal paths based on link congestion. Dragonfly+ is the topology that powers the world's largest supercomputers (Frontier at ORNL, LUMI at CSC), and its routing algorithm is the key to its scalability.

### 8.1 Dragonfly+ Topology Structure

A Dragonfly+ network is organized as a three-level hierarchy:

- **Groups:** The network is divided into \(G\) groups. Each group contains \(a\) routers, and each router connects to \(p\) compute nodes and to the inter-group fabric.
- **Intra-group connections:** Within a group, the \(a\) routers are fully connected (all-to-all) via electrical or short-reach optical links. This provides single-hop connectivity between any two nodes in the same group.
- **Inter-group connections:** Between groups, the network is a _virtual fully-connected graph_: each group has at least one link to every other group, but the number of physical links per group pair varies based on bandwidth requirements. The inter-group links are typically long-reach optical links.

The key property of Dragonfly+ is _diameter 3_: any compute node can reach any other compute node in at most 3 hops (source node -> source router -> destination router -> destination node). The intra-group hop and the two end-point hops are fixed; only the inter-group hop matters for path selection. With \(G\) groups, each router needs at most \(G-1\) inter-group links—more than the \(\log G\) or \(\sqrt{G}\) of fat-tree or torus, but the cost is manageable because inter-group links are longer and more expensive, and their count grows only linearly with \(G\).

### 8.2 Adaptive Routing: Minimal vs. Non-Minimal

Dragonfly+ routers implement _Universal Globally Adaptive Load-balanced_ (UGAL) routing. For each packet, the router computes two candidate output ports:

1. **Minimal path:** The direct link from the source group to the destination group. This path is 1 hop for inter-group traffic (plus the fixed intra-group hops).
2. **Non-minimal path:** A randomly selected intermediate group via its inter-group link. This path is 2 hops for inter-group traffic: source group -> intermediate group -> destination group.

The router estimates the queue occupancy (congestion) on each candidate output port and chooses the less congested one. The non-minimal path is one hop longer, but if the minimal path is congested (e.g., many jobs are sending data to the same destination group), the non-minimal path may deliver the packet sooner because it bypasses the congestion.

The key parameter is the _bias_ toward minimal paths: UGAL uses a threshold \(T\); if the minimal path's queue length is less than \(T\) plus the non-minimal path's queue length, the minimal path is chosen. \(T\) is typically set to 1-2 packets' worth of queue depth, reflecting the fact that the non-minimal path consumes twice the network bandwidth (it traverses two inter-group links instead of one) and should only be used when the minimal path is significantly more congested.

### 8.3 Performance Under Adversarial Traffic Patterns

The Dragonfly+ topology with UGAL routing achieves near-optimal throughput under benign traffic patterns (uniform random, permutation) but degrades under _adversarial_ traffic patterns (e.g., all-to-all communication with a single destination group). This degradation is inherent to any indirect network: when many sources send to the same destination, the destination's inbound links become congested, and no amount of non-minimal routing can help—the bottleneck is at the destination, not in the fabric. Dragonfly+ mitigates this with _local adaptive routing_ within the source and destination groups (if the destination group's routers have multiple inbound links, the packet can be routed to a less congested router in the destination group for last-hop delivery).

The theoretical throughput of Dragonfly+ under adversarial traffic is approximately \(1/(2p)\) of the ideal throughput, where \(p\) is the fraction of traffic that is adversarial. For real HPC workloads, \(p\) is typically 5-20%, so the throughput degradation is modest. Dragonfly+ achieves 70-85% of the ideal throughput across the spectrum of DOE/NNSA workloads (as measured on the Cray XC40 "Trinity" system), which is competitive with or superior to fat-tree and torus topologies at similar scale.

## 9. Jellyfish and Random Graph Topologies: Rethinking Structure

In 2012, Singla, Hong, Popa, and Godfrey (NSDI 2012) proposed the _Jellyfish_ topology, which abandons the hierarchical structure of fat-trees and Dragonfly entirely in favor of a random regular graph (RRG). Jellyfish is built by connecting switches in a random \(k\)-regular graph (each switch has \(k\) ports, connected to \(k\) other randomly chosen switches), with servers attached to the remaining switch ports. The radical simplicity of Jellyfish—no hierarchy, no special roles for different layers—challenges the long-held assumption that structured topologies are necessary for high-performance networking.

### 9.1 Jellyfish Properties

A random \(k\)-regular graph with \(N\) switches has several provable properties that make it attractive as a network topology:

- **Diameter:** The diameter of a random \(k\)-regular graph is \(O(\log*{k-1} N)\), which is near-optimal (the Moore bound, a general lower bound on diameter for a graph with \(N\) nodes and maximum degree \(k\), is \(\Omega(\log*{k-1} N)\)). For \(N = 1000\) switches and \(k = 32\), the expected diameter is 3-4, comparable to a 3-level fat-tree.
- **Bisection bandwidth:** A random \(k\)-regular graph has bisection bandwidth within a constant factor of optimal (the graph is an _expander_—any cut has roughly the expected number of crossing edges). This means that random graph topologies have near-optimal worst-case throughput under any traffic pattern, without the adversarial traffic bottlenecks that affect structured topologies.
- **Fault tolerance:** Random regular graphs are _expanders_, meaning that removing a fraction of edges or vertices leaves a connected component that contains almost all the remaining vertices. A Jellyfish network can survive the failure of 10-20% of switches or links without partitioning and with only modest throughput degradation.

### 9.2 The Routing Challenge

The primary disadvantage of random graph topologies is routing complexity: without the hierarchical structure of fat-trees or Dragonfly, computing shortest paths and detecting failures is more complex. Jellyfish uses _k-shortest-path routing_ with Equal-Cost Multi-Path (ECMP) load balancing: for each source-destination pair, the routing protocol computes the \(k\) shortest paths (using Yen's algorithm, which extends Dijkstra's to find multiple shortest paths) and distributes traffic across them in proportion to path capacity. This requires \(O(N^2 \log N + k N^2)\) computation, which is tractable for up to ~10,000 switches (the pre-computation is done offline and loaded into the switches at boot time).

Google's Jupiter datacenter network (Singh et al., SIGCOMM 2015) uses a topology that is structurally equivalent to a random regular graph, built on a Clos fabric with optical circuit switching between aggregation blocks. Jupiter achieves 1.3 Pbps of bisection bandwidth across 40,000 servers, demonstrating that random-graph-like topologies are practical at the largest scales. Jupiter's routing uses a custom Software-Defined Networking (SDN) controller that computes paths centrally and programs them into the switches, sidestepping the distributed routing challenges that historically favored structured topologies.

## 10. Optical Circuit Switching and Topology Reconfiguration

All the topologies discussed so far are _static_: the physical links are fixed at deployment time and cannot be changed without physically recabling. _Optical circuit switching_ (OCS) introduces a new dimension: the network topology can be reconfigured dynamically, on millisecond or microsecond timescales, by steering optical signals through MEMS mirrors or wavelength-selective switches. This converts the topology from a fixed cost to a tunable parameter, enabling networks that adapt to traffic patterns in real time.

### 10.1 MEMS-Based Optical Circuit Switching

Micro-Electro-Mechanical Systems (MEMS) optical switches use arrays of tiny movable mirrors (typically 100-500 μm in diameter) to redirect optical beams from input fibers to output fibers. A MEMS mirror has two degrees of freedom (tip and tilt), allowing it to steer a beam to any output position. A switch with \(N\) input fibers and \(N\) output fibers uses \(N\) mirrors on the input side and \(N\) mirrors on the output side, with a control system that positions each input mirror to point at the desired output mirror.

Google's Jupiter Evolving network (2022) uses MEMS OCS to dynamically reconfigure the topology between data center aggregation blocks. The OCS switches (from Calient, now Luna Innovations) support 128-384 ports with switching times of 10-100 ms—too slow for packet-level switching but fast enough for _topology reconfiguration_ on the timescale of traffic pattern changes (which evolve over seconds to minutes in data center workloads).

The key advantage of OCS is energy: an OCS switch consumes 1-5 watts per port, compared to 10-50 watts per port for an electrical packet switch at equivalent bandwidth, because the optical signal passes through the switch without O-E-O (optical-electrical-optical) conversion. At 400G per port, a 384-port OCS switch consumes ~1 kW, while an equivalent electrical switch (e.g., Broadcom Tomahawk 5, 64x400G) consumes ~5 kW—a 5x energy advantage for OCS, plus lower cooling requirements.

### 10.2 Wavelength-Selective Switching and ROADMs

For even faster reconfiguration (microsecond timescales), _wavelength-selective switches_ (WSS) using liquid crystal on silicon (LCoS) or fiber Bragg gratings can steer individual wavelengths independently. In a _Reconfigurable Optical Add-Drop Multiplexer_ (ROADM), each wavelength can be independently routed to any output port, enabling a _wavelength-switched optical network_ where the topology at wavelength \(\lambda*1\) is different from the topology at wavelength \(\lambda_2\). This enables \_topology multiplexing*: multiple virtual topologies share the same physical fiber plant, each carrying a different traffic class or job.

The NTT Optical Network (2023) demonstrated a 64x64 WSS with 1 μs switching time, enabling burst-level topology reconfiguration. In this network, the topology can be reconfigured between packets—effectively enabling _optical packet switching_ without O-E-O conversion, provided the destination is on the same wavelength. The limiting factor is the control plane latency: determining the optimal topology for the current traffic pattern and programming the WSS takes ~1 ms, so the reconfiguration granularity is ~1 ms rather than the ~1 μs achievable by the optical hardware.

### 10.3 Topology Optimization with OCS

With OCS, the network operator can run a _topology optimization_ algorithm periodically (e.g., every second or every minute) to compute the optimal topology for the current or predicted traffic matrix. The optimization problem is: given a physical fiber plant (a set of nodes and fiber links with capacities), a set of OCS switches at each node, and a traffic matrix \(T\) (the bandwidth demand between each pair of nodes), find the mapping of wavelengths to paths that maximizes the minimum throughput (max-min fairness) or minimizes the maximum link utilization (load balancing).

This is a mixed-integer linear program (MILP) that is NP-hard in general, but heuristics based on matching and multi-commodity flow approximations achieve 80-95% of the optimal throughput in polynomial time. Google's Jupiter Evolving uses a heuristic called _Solis_ that greedily allocates OCS connections to the highest-demand source-destination pairs, then uses a linear program to allocate remaining capacity.

The long-term vision, articulated by Google's "Aurora" and Microsoft's "Sirius" projects, is a fully optical data center where the network topology is a software-defined, dynamically reconfigurable resource, optimized in real time for the workload. Combined with Jellyfish-like random graph overlays for resilience and load balancing, OCS-based reconfiguration could achieve near-optimal throughput for any traffic pattern without the static topology's cost and energy overhead.

## 11. Software-Defined Networking and Topology-Aware Job Scheduling

The topology determines the worst-case and average-case communication performance, but the _mapping_ of jobs to nodes determines whether a given topology is used efficiently. Topology-aware scheduling—placing communicating processes close together in the topology—can reduce the effective diameter, increase the effective bisection bandwidth, and reduce contention, sometimes by factors of 2-5x compared to random placement.

### 11.1 The Allocation Problem: Contiguous vs. Discontiguous

HPC systems traditionally allocate nodes contiguously (a block of consecutive node IDs) to minimize fragmentation, analogous to memory allocation in an operating system. Contiguous allocation is simple but topology-oblivious: consecutive node IDs may be physically distant in the network topology (e.g., in a Dragonfly, consecutive IDs may span different groups), causing unnecessary inter-group traffic for tightly coupled MPI jobs.

Topology-aware allocators (e.g., the Slurm `topology/tree` plugin, IBM's LoadLeveler topology-aware scheduler, and Cray's ALPS) model the network topology as a graph and allocate nodes to minimize the _communication diameter_ of the allocated subgraph—the maximum distance (in hops) between any two allocated nodes. For a Dragonfly topology, this means allocating nodes within a single group whenever possible, and when a job spans multiple groups, allocating contiguous groups (groups that have direct links to each other). For a fat-tree, this means allocating nodes within a single leaf switch, then within a single spine switch's subtree, etc.

The allocation problem is NP-hard (it reduces to the subgraph isomorphism problem), but greedy heuristics (allocate the largest connected component of unallocated nodes that fits the job size) achieve near-optimal placement for most job sizes. The practical impact is significant: topology-aware placement reduces the average MPI allreduce latency by 15-40% and the tail latency (99th percentile) by 30-60% on Dragonfly systems, because most communication stays within a single group (1 hop) rather than traversing inter-group links (3 hops).

### 11.2 SDN-Controlled Topologies for HPC

Software-Defined Networking (SDN) decouples the control plane (routing decisions) from the data plane (packet forwarding), enabling centralized, programmable control of the network. In HPC, SDN enables:

- **Per-job topology optimization:** Before launching a job, the SDN controller computes optimal routes for that job's communication pattern (which may be known from previous runs or from a static analysis of the MPI code) and installs forwarding rules that minimize contention between the job's flows.
- **Elephant flow detection and rerouting:** The SDN controller monitors link utilization and detects "elephant flows" (large, long-lived data transfers, e.g., MPI collective operations or I/O bursts). When an elephant flow congests a link, the controller reroutes it onto a less congested path, even if that path is non-minimal.
- **Quality-of-Service (QoS) for latency-sensitive traffic:** The SDN controller can assign different DSCP (Differentiated Services Code Point) tags to different MPI communicators, ensuring that latency-sensitive collective operations (e.g., `MPI_Barrier` for synchronization) get priority over bandwidth-intensive collective operations (e.g., `MPI_File_write` for checkpointing).

The deployment of SDN in HPC is limited by the reluctance of HPC operators to adopt "complex" software-defined control planes (fearing reliability issues) and by the closed nature of some HPC interconnect stacks (Cray's Aries and Slingshot interconnects have proprietary control planes that are not easily opened to SDN). However, the trend toward Ethernet-based HPC interconnects (e.g., HPE's Slingshot, which uses Ethernet at the link layer) is opening the door to SDN integration.

## 12. Topology-Aware Collective Algorithms: Tuning MPI for the Wire

The MPI collective operations (broadcast, reduce, allreduce, gather/scatter) are the communication backbone of HPC applications. The performance of these operations depends critically on the topology: an allreduce algorithm that is optimal for a fat-tree (recursive doubling, which requires \(\log_2 P\) steps) may perform poorly on a torus, where a ring-based algorithm (requiring \(P-1\) steps but with all communication between neighbors) may be faster because it avoids contention on long-distance links. Topology-aware collective algorithms tune the communication pattern to the underlying topology, and their design is a rich subfield of HPC research.

### 12.1 Recursive Halving and Distance-Based Tuning

The standard `MPI_Allreduce` algorithm for large messages is _recursive halving_ with distance doubling: in step \(s\), each process exchanges data with the process at distance \(2^s\) in the logical rank ordering. On a fat-tree, this is near-optimal because the recursive halving pattern maps naturally to the tree structure—early steps (small distances) communicate within a leaf switch, later steps (larger distances) communicate across spine switches, and the bandwidth of the tree is fully utilized.

On a Dragonfly, however, recursive halving can be disastrous if the logical rank ordering does not match the group topology. Step \(s\) may pair processes in different groups, requiring inter-group links, and if many steps do so, the inter-group links become a bottleneck. The _Dragonfly-aware allreduce_ algorithm (Klenk and Froening, 2017) instead groups processes by their group membership, performs a local reduce within each group (using shared memory or intra-group communication), then performs an inter-group allreduce across groups, and finally broadcasts the result within each group. This reduces the inter-group communication to a single allreduce among the groups, rather than the \(\log_2 P\) all-to-all exchanges of naive recursive halving.

### 12.2 Topology Discovery and Auto-Tuning

Modern MPI libraries (MPICH, Open MPI, Cray MPICH) perform _topology discovery_ at job startup: they query the network topology from the resource manager (Slurm, PBS, ALPS) or via direct hardware queries (switch-level topology daemons) and construct a graph model of the allocated nodes. The collective algorithm selection engine then uses this graph to choose the optimal algorithm for each collective operation. On a torus, it selects a ring reduce; on a fat-tree, recursive halving; on a Dragonfly, group-aware reduce; and on a random graph (Jellyfish), it falls back to a bandwidth-optimal recursive halving but with topological ranking (assigning logical ranks to minimize the distance between communicating pairs).

The auto-tuning is performed once per job and cached for subsequent runs. On the Cray XC40 "Theta" system (Dragonfly topology, 4,392 nodes), topology-aware collective tuning improved `MPI_Allreduce` performance by 35% (average) and 60% (99th percentile) compared to topology-oblivious recursive halving, reducing the average time for a 1 MB allreduce from 45 μs to 29 μs.

## 13. Summary

Network topology is where graph theory meets systems engineering. The asymptotic properties—diameter \(O(\log N)\), constant degree, full bisection bandwidth—are dictated by information-theoretic bounds and algebraic constructions. The practical properties—cable length, connector density, physical layout, compatibility with 19-inch racks and raised-floor cooling—are dictated by the messy reality of machine rooms and the economics of manufacturing.

The Dragonfly, with its low diameter and economical use of inter-group links, represents the current sweet spot for large HPC systems. The Slim Fly represents the theoretical frontier, waiting for high-radix switches to catch up. Optical circuit switching promises to make topology a runtime-variable parameter, eliminating the need to choose a single topology for all workloads.

For the systems researcher, network topology is a rich domain that combines discrete mathematics (graph theory, algebraic constructions), queuing theory (congestion modeling, adaptive routing), and physical engineering (cable management, signal integrity, optical transceivers). The best topologies are those that not only optimize the mathematical objective but also respect the physical and economic constraints of real-world deployment. As HPC systems grow toward exascale and beyond, topology innovation will be as critical to performance as processor and memory innovation—the network is the computer, and the topology is its architecture.
