---
title: "The Algorithmic Foundations Of Blockchain Consensus: Proof Of Work, Proof Of Stake, And Dag Based Approaches"
description: "A comprehensive technical exploration of the algorithmic foundations of blockchain consensus: proof of work, proof of stake, and dag based approaches, covering key concepts, practical implementations, and real-world applications."
date: "2019-03-24"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/the-algorithmic-foundations-of-blockchain-consensus-proof-of-work,-proof-of-stake,-and-dag-based-approaches.png"
coverAlt: "Technical visualization representing the algorithmic foundations of blockchain consensus: proof of work, proof of stake, and dag based approaches"
---

# The Clock, The Stake, and the Tangle: Why Your Digital Trust Depends on an Algorithm

## Part I: The Foundational Crisis of Decentralized Money

Imagine, for a moment, that you are not a person, but a digital dollar. You exist as a shimmering line of code, a unique sequence of ones and zeros residing on a distributed ledger. Your entire existence is a fleeting transaction, a record of value passed from one anonymous wallet to another. The system that cradles you, the blockchain, promises you are immutable, secure, and singular. But there is a threat lurking in the digital shadows: the double-spend. What if your sender, the moment after dispatching you, could whisper to the network, "No, I never sent that. Here is the same dollar again." The entire economic premise of decentralized money would collapse into a chaotic soup of counterfeited records.

This is not merely a theoretical concern. It is the foundational existential crisis that every blockchain must solve. It is not a problem of cryptography alone, nor simply one of networking. It is a problem of distributed agreement—a consensus on the single, canonical version of history. How do thousands of independent, mutually distrustful computers, scattered across the globe and potentially controlled by adversaries, agree on one, and only one, order of events? Without a central bank, a trusted notary, or a single server to verify transactions, how is a shared truth forged from a cacophony of competing claims? The answer, the beating heart of every decentralized network, is the consensus algorithm.

The choice of this algorithm is the single most consequential decision in the architecture of a blockchain. It dictates the network's security budget, its throughput (how many transactions per second), its energy consumption, its latency (how long you wait for confirmation), and its fundamental philosophical orientation toward decentralization. The consensus algorithm is not merely a technical detail; it is the constitution of a digital nation, embedding its core values—whether that be absolute security at any cost, energetic efficiency, or the radical democratization of participation.

To understand why this matters, we must first understand the problem these algorithms solve. The double-spend problem is deceptively simple: in a digital world where information can be copied perfectly and instantaneously, how do you ensure that a unit of digital value can only be spent once? In the physical world, this problem solves itself. If I hand you a twenty-dollar bill, I no longer have it. The act of transfer is atomic and self-evident. But a digital file is not a physical object. It is a pattern of bits that can be duplicated without any degradation. Before Bitcoin, the only solution was a trusted third party—a bank, a payment processor, a central ledger keeper—who maintained the single source of truth. Satoshi Nakamoto's breakthrough was proving that this trust could be distributed algorithmically.

### The Byzantine Generals Problem: A Parable for Our Time

The double-spend problem is a specific instance of a much deeper challenge in distributed computing known as the Byzantine Generals Problem. This thought experiment, first formulated by Leslie Lamport, Robert Shostak, and Marshall Pease in 1982, captures the essence of distributed consensus in the presence of faulty or malicious actors.

The parable goes like this: Several divisions of the Byzantine army are camped outside an enemy city. Each division is commanded by its own general, and the generals can only communicate via messengers. They must agree on a common plan of action—either to attack or to retreat. If all generals attack, they win. If all generals retreat, they live to fight another day. But if some attack while others retreat, the result is catastrophic defeat. The complication is that one or more generals may be traitors, actively attempting to subvert the consensus by sending conflicting messages to different recipients.

The generals need an algorithm—a protocol—that guarantees that:

1. All loyal generals agree on the same plan.
2. The plan they agree upon is the one proposed by a loyal general (or is at least a plan that a sufficient number of loyal generals support).

Lamport proved that in a system with `n` generals, consensus can only be guaranteed if there are at least `3f + 1` loyal generals, where `f` is the number of traitors. In other words, you need more than two-thirds of the participants to be honest. This is the Byzantine Fault Tolerance (BFT) threshold, and it underpins virtually every consensus algorithm in existence.

Now, translate this to a blockchain. The generals are the nodes in the network. The plan of action is the next block of transactions to be added to the chain. The traitors are malicious actors attempting to double-spend, censor transactions, or reorg the chain. The messengers are the peer-to-peer communication channels. And the algorithm is the consensus mechanism that ensures all honest nodes eventually agree on a single, canonical blockchain history.

The genius of Bitcoin's Proof of Work was not that it solved the Byzantine Generals Problem outright—it didn't. Instead, it introduced a crucial innovation: it made the cost of being a traitor (or a Byzantine general) economically prohibitive. In Nakamoto's model, you don't need to identify and expel traitors. You just need to make sure that the cost of their treachery exceeds any possible benefit. This is the shift from Byzantine Fault Tolerance to economic Byzantine Fault Tolerance, and it fundamentally changed the landscape of distributed systems.

## Part II: Proof of Work—The Original Digital Constitution

### The Physics of Trust

When Satoshi Nakamoto released the Bitcoin whitepaper in October 2008, the world was in the grip of a financial crisis centered on trust—or rather, the catastrophic failure of centralized trust. Banks had failed, governments had bailed them out, and the public had learned that the institutions they trusted with their life savings were, at best, incompetent and, at worst, corrupt. Bitcoin was not just a technological innovation; it was a political one. Its consensus mechanism, Proof of Work (PoW), was designed to replace human trust with physical proof.

Proof of Work is elegantly simple in concept. To add a new block to the blockchain, a node (called a miner) must solve a computationally difficult puzzle. The puzzle is to find a number (called a nonce) such that the hash of the block header is less than a target value. Since cryptographic hash functions are one-way, the only way to find such a nonce is through brute force—trying trillions of possibilities until one works. This is the "work" in Proof of Work. It requires real-world energy expenditure, and that expenditure is what makes the system secure.

The key insight is that this work is difficult to produce but trivially easy to verify. Any node in the network can check whether a proposed block's hash meets the target in microseconds. This asymmetry is crucial. It means that while creating a valid block is expensive, verifying it is essentially free. This creates a fundamental economic barrier: to rewrite history (i.e., to create an alternative chain that undoes a transaction), an attacker would need to redo all the work for every block from the point of divergence to the present. This is computationally infeasible for a single attacker unless they control more than 50% of the total network hash rate.

### The Security Budget: How Mining Pays for Protection

But why would anyone spend real electricity and hardware costs to secure a network? This is where the incentive structure, the "security budget" of the blockchain, comes into play. Miners are rewarded with newly minted coins and transaction fees for successfully mining a block. This reward must exceed their operational costs—electricity, hardware depreciation, cooling, maintenance, and bandwidth—or they will stop mining and the network's security will collapse.

Bitcoin's security budget is both its greatest strength and its most critiqued weakness. As of 2024, Bitcoin miners collectively consume approximately 120-150 terawatt-hours of electricity per year, comparable to the annual energy consumption of countries like Argentina or the Netherlands. This is not a bug; it is the feature. The energy expenditure is the physical anchor that grounds digital value. Every Bitcoin transaction is backed by a verifiable amount of real-world energy expenditure, making it prohibitively expensive to attack.

Consider the math. At Bitcoin's peak, the total network hash rate exceeded 400 exahashes per second (400 quintillion hashes per second). To achieve a 51% attack—to rewrite the blockchain history and double-spend coins—an attacker would need to acquire and operate more than 200 exahashes per second of mining hardware. The capital expenditure alone would be in the tens of billions of dollars. The ongoing operational cost would be hundreds of millions of dollars per month in electricity. And even then, the attacker would only be able to rewrite the most recent blocks, not the entire chain. Older blocks remain secure because they are buried under an increasingly massive mountain of work.

This is the "thermodynamic security" that Proof of Work provides. It is not theoretical; it is physical. An attacker cannot forge the past because they cannot re-spend the electricity that was already consumed. This is why Bitcoin has never been successfully 51% attacked, despite being the most valuable target in the cryptocurrency ecosystem. The cost of the attack exceeds the potential reward.

### The Scalability Trilemma

However, Proof of Work has a fundamental limitation: it is slow. Bitcoin can process approximately 7 transactions per second (tps). Ethereum, also PoW-based, could handle about 15-30 tps. Compare this to Visa, which processes approximately 1,700 tps on average and claims a peak capacity of 24,000 tps. The reason for this limitation is deeply embedded in the consensus mechanism.

Bitcoin's block time is approximately 10 minutes. This is a deliberate design choice. A shorter block time would increase the probability of multiple miners finding valid blocks simultaneously, leading to more frequent orphaned blocks and reducing security. The 10-minute interval ensures that the network has time to propagate blocks globally and that the probability of a race condition (two miners solving the block at nearly the same time) is acceptably low.

But this creates a trilemma, first articulated by Ethereum's Vitalik Buterin: blockchain systems can only achieve two of three properties simultaneously—security, scalability, and decentralization. Security requires many nodes validating every transaction. Decentralization requires that these nodes can run on modest hardware (otherwise, only wealthy entities can participate). Scalability requires high throughput. Proof of Work, as implemented in Bitcoin, prioritizes security and decentralization at the expense of scalability.

### Real-World Attacks and Their Implications

Despite its theoretical robustness, Proof of Work is not invulnerable. Several altcoins with lower hash rates have been successfully attacked. In January 2019, the Ethereum Classic network suffered a 51% attack that allowed the attacker to double-spend approximately $1.1 million worth of ETC. The attacker rented hash power from a cloud mining service, executed the attack, and profited before the network could respond. This demonstrates a crucial weakness: small PoW chains are vulnerable to "rental attacks" where an adversary temporarily acquires hash power from the market.

Bitcoin itself is not immune to this threat, but the scale makes it impractical. To rent enough hash power to attack Bitcoin, an attacker would need to purchase ASICs (Application-Specific Integrated Circuits) months in advance, as the global supply is limited and manufacturing capacity is constrained. There is no rental market for Bitcoin ASIC hash power at the scale required for a successful attack.

Another attack vector is the selfish mining strategy, first described by Ittay Eyal and Emin Gün Sirer in their 2013 paper "Majority is not Enough: Bitcoin Mining is Vulnerable." In this attack, a miner with less than 50% of the network hash rate can increase their revenue by selectively withholding and revealing blocks. The attack exploits the fact that honest miners waste resources on blocks that are later orphaned. While selfish mining does not break the consensus entirely, it undermines the fairness and economic assumptions of the system. Researchers have shown that a selfish miner with as little as 25% of the total hash rate can gain a competitive advantage, destabilizing the network.

## Part III: Proof of Stake—The Algorithm as Economic Game

### The Philosophical Shift

If Proof of Work is about proving your trustworthiness through external resource expenditure, Proof of Stake (PoS) is about proving it through internal economic commitment. Instead of spending electricity, validators (the PoS equivalent of miners) lock up their own cryptocurrency as collateral—their "stake." In exchange for this commitment, they are randomly selected to propose and validate blocks. If they behave honestly, they earn rewards. If they misbehave—if they propose conflicting blocks, validate invalid transactions, or are consistently offline—they are "slashed," meaning a portion of their stake is destroyed.

This represents a fundamental philosophical shift. PoW is a physics-based security model: trust is anchored in the physical laws of thermodynamics. PoS is an economics-based security model: trust is anchored in the rational self-interest of economic actors. The security is not in the energy consumed, but in the capital at risk.

### The Nothing-at-Stake Problem

PoS introduces a unique challenge that PoW does not face: the nothing-at-stake problem. In PoW, if a miner discovers a block, they immediately broadcast it to the network. If they choose to mine on a different, conflicting chain, they must split their hash power, reducing their probability of finding the next block on either chain. The physical constraint of limited hash power enforces chain selection.

In PoS, a validator can vote on multiple conflicting chains simultaneously without any additional cost. If the protocol allows validators to vote on any block they see, rational validators might vote on every chain, ensuring they receive rewards regardless of which chain ultimately wins. This would break the consensus mechanism entirely, as there would be no mechanism to converge on a single canonical chain.

The solution, implemented in modern PoS systems like Ethereum's Casper FFG (Friendly Finality Gadget), is conditional slashing. The protocol defines clear rules about what constitutes misbehavior. For example, if a validator votes on two different blocks at the same epoch height, that is detectable and punishable. The validator's stake is slashed, and they are ejected from the validator set. The threat of capital destruction re-aligns incentives: validators have "something at stake" and will not risk their collateral for a small potential gain.

### Ethereum's Migration: A Case Study in Consensus Evolution

The transition of Ethereum from Proof of Work to Proof of Stake, known as "The Merge" (completed in September 2022), is perhaps the most significant event in the history of consensus algorithm evolution. Ethereum was the second-largest cryptocurrency by market capitalization, with a vibrant ecosystem of decentralized applications (dApps), DeFi protocols, and NFTs. Its PoW consensus consumed approximately 112 terawatt-hours per year at its peak—roughly equivalent to the energy consumption of Poland.

The Merge was not a simple software update. It required years of research, development, and testing. The process revealed several critical insights about the nature of consensus algorithms:

**First, the reduction in energy consumption was dramatic and almost immediate.** After transitioning to PoS, Ethereum's energy consumption dropped by approximately 99.95%. The network went from consuming as much electricity as a medium-sized European country to consuming roughly the same amount as a small town. This was not a marginal improvement; it was a fundamental change in the environmental footprint of the network.

**Second, the security assumptions changed.** In PoW, security depends on the cost of acquiring and operating mining hardware. In PoS, security depends on the total value staked and the cost of acquiring that stake. To mount a 51% attack on Ethereum PoS, an attacker would need to acquire approximately 51% of all staked ETH. As of 2024, that would require acquiring approximately 16 million ETH, worth roughly $40 billion at historical prices. Unlike PoW hardware, which can be repurposed or rented, this ETH would be directly exposed to slashing. The attacker would lose a significant portion of their capital if the attack failed.

**Third, the economic finality changed.** In Bitcoin PoW, finality is probabilistic. After six confirmations (approximately one hour), the probability of a reorganization is extremely low but never mathematically zero. In Ethereum PoS, finality is economic and deterministic. Once a block is finalized by the Casper FFG mechanism, reversing it would require burning a significant portion of all staked ETH, making it economically irrational to attempt. This provides stronger guarantees for high-value transactions.

### The Long-Range Attack Threat

PoS systems face a unique vulnerability that PoW does not: the long-range attack. In PoW, the chain with the most cumulative work is always the canonical chain. A new node joining the network can verify this by checking the block headers. In PoS, a sophisticated attacker could create an alternative chain starting from genesis, using old validators' keys that have since been unstaked and are no longer penalizable. An unwitting new node might accept this alternative chain as valid.

The standard defense against this is the "weak subjectivity" checkpoint. New nodes do not start from genesis; they start from a trusted, recent block. This checkpoint can be obtained from a block explorer, a trusted community member, or a social consensus. This centralizes the initial trust assumption but allows the rest of the consensus to remain fully decentralized. It is a pragmatic compromise that acknowledges the impossibility of perfect trustless bootstrapping.

### Delegated Proof of Stake and Its Trade-offs

A variation on Proof of Stake is Delegated Proof of Stake (DPoS), pioneered by systems like EOS and TRON. In DPoS, token holders vote for a small number of "delegates" (typically 21-101) who are responsible for producing blocks. This dramatically increases throughput—EOS claims 4,000 tps—because the delegate set is small and geographically distributed, allowing for faster consensus rounds.

However, DPoS sacrifices decentralization for performance. The small delegate set is vulnerable to cartelization, bribery, and regulatory pressure. In the EOS ecosystem, accusations of vote buying and delegate collusion have been persistent. The system also creates a fundamentally plutocratic structure: those with the most tokens have the most voting power, and small token holders have little incentive to participate in governance.

## Part IV: The Tangle and Directed Acyclic Graphs

### Breaking the Chain

Both PoW and PoS share a fundamental architectural assumption: transactions are organized into linear blocks, and those blocks form a chain. This linearity is the source of both security and limitation. Every transaction must wait for a block to be mined or validated, creating a natural bottleneck. What if we could eliminate blocks entirely?

This is the premise of the Tangle, the underlying data structure of the IOTA cryptocurrency. Instead of a chain, the Tangle is a Directed Acyclic Graph (DAG). In the Tangle, each new transaction must validate two previous transactions before it can be accepted. There are no miners, no validators, and no blocks. Every participant is both a user and a validator.

The implications are profound. As more transactions are added to the Tangle, the network becomes more secure and processes transactions faster. There are no transaction fees because there are no miners to pay. The throughput is theoretically unlimited because transactions can be added in parallel, not just sequentially. The Tangle is designed for the Internet of Things (IoT), where billions of devices might perform microtransactions worth fractions of a cent.

### The Confirmation Mechanism

How does the Tangle achieve consensus? Each new transaction chooses two previous transactions to approve. The weight of a transaction is determined by the amount of "work" done to create it (a lightweight PoW, typically a few seconds on a smartphone). As transactions approve one another, they form a DAG. The consensus rule is: a transaction is considered confirmed when it is directly or indirectly approved by a sufficiently large portion of the total network weight.

A simple heuristic for determining whether a transaction is confirmed is to run a random walk from a "tip" (an unconfirmed transaction) to the transaction in question. The number of walks that pass through the transaction is proportional to its cumulative weight. If a sufficiently high percentage of random walks reach the transaction, it is considered confirmed.

This mechanism has a beautiful property: it naturally resists attacks. To double-spend, an attacker would need to create a subtangle that eventually gains more weight than the honest subtangle. But because new honest transactions consistently approve honest tips (which point to honest history), the honest subtangle consistently gains more weight. The attacker must continuously create valid transactions to keep their subtangle alive, and the cost of doing so grows linearly with time.

### The Coordinator Problem

The Tangle's theoretical properties are elegant, but the practical implementation has faced significant challenges. For the first several years of its existence, IOTA relied on a "Coordinator"—a central node operated by the IOTA Foundation that issued "milestones" to confirm transactions. This completely undermined the claimed decentralization of the system. Critics argued that IOTA was essentially a centralized database with a DAG aesthetic.

This critique was valid. The Coordinator was a training wheel, a necessary compromise to bootstrap the network and protect against attacks during its early, low-usage phase. The IOTA Foundation promised to phase out the Coordinator once the network was sufficiently mature and decentralized—a shift known as "Coordicide." As of 2024, Coordicide is still ongoing, with a phased deployment of new algorithms that replace the Coordinator's role.

The Coordinator problem highlights a crucial lesson about consensus algorithms: theoretical elegance must be weighed against practical deployment constraints. A perfectly decentralized consensus mechanism is useless if it cannot survive the bootstrapping phase, when the network has few nodes, low transaction volume, and is vulnerable to Sybil attacks.

### Comparison: Hashgraph and DAG-Based BFT

IOTA is not the only DAG-based consensus system. Swirlds' Hashgraph, used by the Hedera Hashgraph network, takes a different approach. In Hashgraph, each node continuously gossips with random other nodes, sharing the events they know about. The protocol achieves consensus through "virtual voting," where each node can calculate what every other node would vote for based on the communication history. This eliminates the need for explicit voting messages.

Hashgraph achieves throughputs of thousands of transactions per second with deterministic finality—once a transaction is confirmed, it cannot be reversed. However, like IOTA, it has faced centralization concerns. The Hashgraph algorithm is patented, and while the Hedera network is permissioned, the core team maintains significant control. The protocol's reliance on a small set of "permissioned" nodes for initial deployment raises questions about whether decentralized consensus can truly be achieved without permissionless participation.

### The Throughput vs. Finality Trade-off

One of the central tensions in DAG-based systems is the trade-off between throughput and finality. In a linear blockchain, finality is clear: a block is either included in the chain or it isn't. In a DAG, transactions can be approved inconsistently, and the concept of "finality" becomes probabilistic. Different DAG implementations handle this differently.

In the IOTA Tangle, finality is probabilistic and asymptotic. A transaction becomes increasingly unlikely to be reversed as it gains cumulative weight. In Hashgraph, finality is deterministic once a consensus round completes. In Avalanche's DAG-based consensus, finality is achieved through repeated sub-sampling of validators, with the probability of reversal decreasing exponentially with each round.

This spectrum of finality guarantees has real-world implications. For high-value financial transactions, deterministic finality (or close to it) is essential. For microtransactions in IoT, probabilistic finality with rapid confirmation times may be acceptable. The optimal consensus algorithm depends on the specific use case.

## Part V: The Emerging Synthesis

### Hybrid Approaches and Layer 2

The evolution of consensus algorithms has not stopped with PoW, PoS, or DAGs. The most sophisticated modern blockchain architectures recognize that no single consensus mechanism is optimal for all purposes. Instead, they are building hybrid systems that layer different consensus mechanisms on top of each other.

Bitcoin's Lightning Network is a prime example. The base layer (Layer 1) uses PoW with its slow, expensive, but extremely secure consensus. On top of this, the Lightning Network (Layer 2) uses a form of Byzantine Fault Tolerance among a small group of participants in payment channels. Transactions within channels can be instant and nearly free, while disputes are settled by reverting to the secure PoW base layer.

This layered architecture recognizes a fundamental truth: there is no universal optimal consensus algorithm. Instead, there are trade-offs along multiple dimensions—security, speed, decentralization, energy efficiency, latency, finality, and cost. A well-designed system chooses the right consensus algorithm for each layer, optimizing the overall system for its specific use case.

### The Future: Proof of Humanity and Proof of Personhood

Looking further ahead, researchers are exploring radically different approaches to consensus. Proof of Humanity systems attempt to anchor consensus in human identity rather than capital or computation. Each participant must prove they are a unique human being, through video verification, social connections, or other methods. This would create a "one person, one vote" system, potentially solving the plutocratic tendencies of PoS while being drastically more energy-efficient than PoW.

The practical challenges are enormous. How do you prevent Sybil attacks at scale? How do you preserve privacy while verifying unique humanity? How do you handle lost access, identity theft, and jurisdiction-specific regulations? Projects like Proof of Humanity, Worldcoin, and BrightID are exploring these questions, but none have achieved widespread adoption.

### The Final Frontier: Quantum Resistance and Post-Quantum Consensus

The consensus algorithms discussed so far assume that the underlying cryptographic primitives (hash functions and digital signatures) remain secure. The advent of quantum computing threatens this assumption. Grover's algorithm speeds up brute-force searches, potentially undermining PoW by making hash collisions easier to find. Shor's algorithm breaks the discrete logarithm and RSA cryptosystems that underpin most digital signatures.

Quantum-resistant consensus algorithms are an active area of research. Some proposals use lattice-based cryptography or hash-based signatures. Others develop entirely new consensus mechanisms that don't rely on the security assumptions of current cryptographic primitives. The transition to post-quantum security will not be trivial—it may require a complete rethinking of the foundational assumptions of blockchain consensus.

## Conclusion: The Algorithmic Constitution

Let us return to the image we started with: you are a digital dollar, a shimmering line of code on a distributed ledger. Your existence depends on trust—but not the trust of a bank, a government, or a legal system. Your existence depends on trust in an algorithm.

The consensus algorithm is the constitution of the digital nation-state. It defines who can participate, how decisions are made, what constitutes legitimate authority, and how disputes are resolved. It embeds values: PoW values physical proof and energy expenditure as the foundation of security. PoS values economic commitment and rational self-interest. DAGs value participation and parallelism. Hybrid systems value pragmatic optimization for specific use cases.

But unlike human constitutions, which are written in language that can be interpreted, contested, and amended through political processes, the consensus algorithm is written in mathematics. It is unforgiving, precise, and deterministic. If the algorithm is flawed, the token fails. There are no appeals to a higher authority, no constitutional amendments, no political compromises. The code is the law, and the law is the code.

This is simultaneously the greatest strength and the greatest vulnerability of blockchain systems. The algorithmic constitution provides consistency and predictability, but it lacks the flexibility of human governance. When a bug is discovered, when economic incentives misalign, when the protocol must adapt to changing conditions, the community must fork—a messy, contentious process that often results in permanent splits and acrimony.

The choice of consensus algorithm, then, is not merely a technical decision. It is a philosophical and political one. It reflects a fundamental belief about how trust should be established, how value should be secured, and how power should be distributed. As we build the infrastructure for the decentralized future, we must understand not just how these algorithms work, but what values they embody. Because in the end, the algorithm is not just a mechanism for reaching agreement—it is the foundation of the digital trust that will underpin our economic and social lives for generations to come.

The clock continues ticking. The stake remains committed. The tangle grows ever more complex. And the algorithm endures, quietly governing the flow of digital value across an increasingly trustless world. The question is not whether we can build better algorithms—we can. The question is whether we can build algorithms that encode the values we want to see in the world. That is the true challenge of the consensus age.
