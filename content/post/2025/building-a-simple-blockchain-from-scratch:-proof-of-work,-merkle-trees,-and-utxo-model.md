---
title: "Building A Simple Blockchain From Scratch: Proof Of Work, Merkle Trees, And Utxo Model"
description: "A comprehensive technical exploration of building a simple blockchain from scratch: proof of work, merkle trees, and utxo model, covering key concepts, practical implementations, and real-world applications."
date: "2025-06-13"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Building-A-Simple-Blockchain-From-Scratch-Proof-Of-Work,-Merkle-Trees,-And-Utxo-Model.png"
coverAlt: "Technical visualization representing building a simple blockchain from scratch: proof of work, merkle trees, and utxo model"
---

## Introduction: Demystifying the Machine Behind the Hype

It’s one of the most fascinating paradoxes of modern technology: a system that promises total transparency while leaving most of its users in the dark. When Satoshi Nakamoto’s white paper landed on the cypherpunk mailing list in late 2008, it described something deceptively simple—a peer-to-peer electronic cash system. Fifteen years later, blockchain has become a buzzword that means everything and nothing. Startups claim to “blockchain” their supply chains, artists mint NFTs, and financial institutions whisper about “distributed ledger technology.” Yet beneath the hype, the core machinery remains remarkably compact. You can understand it, and better yet, you can build it.

For developers and engineers, the temptation to treat blockchain as a black box is strong. There are SDKs, APIs, and enterprise platforms that abstract away the messy details. But abstraction comes at a cost: you lose the ability to reason about security, performance, and true decentralization. A blockchain that isn’t built on a solid understanding of its primitives is just a slow database wearing a disguise. The moment you need to design a custom consensus, audit a smart contract, or even explain to a colleague why your system isn’t “really” a blockchain, that abstraction shatters. The only cure is to roll up your sleeves and write the code yourself.

That is exactly what this blog series will do. Over the next few sections, we will construct a minimal but functional blockchain from scratch. No frameworks, no libraries, no magic. Just Python, a few hashing functions, and a deep appreciation for the elegance that makes Bitcoin and its descendants tick. By the end, you will have a running prototype that implements Proof of Work, organizes transactions into Merkle Trees, and tracks ownership using the Unspent Transaction Output (UTXO) model. But before we write a single line of code, let’s step back and understand why this journey matters on a deeper level.

---

### Why Build a Blockchain from Scratch?

You might ask: “Why not just use an existing blockchain platform like Ethereum, Hyperledger, or even a cloud service?” The answer lies in the difference between using a tool and understanding the machine. When you rely on a high-level SDK, you are trusting someone else’s design decisions—choices about consensus protocols, data structures, and security assumptions that may not fit your use case. Consider these scenarios:

- **Customizing consensus**: You need a blockchain for a private supply chain with low latency. Nakamoto consensus (Proof of Work) is too slow; you want a Byzantine Fault Tolerant (BFT) variant. If you only know how to call `mine_block()` on a library, you’re stuck. But if you understand the core loop—broadcast, validate, finalize—you can adapt it.

- **Auditing smart contracts**: You are asked to review a contract on a custom chain. The contract runs on a virtual machine that you don’t understand. Without deep knowledge of the underlying ledger’s transaction model, you cannot assess if the contract can double-spend or manipulate state.

- **Explaining decentralization to your CTO**: You’re pitching a blockchain solution. The CTO asks: “How is this different from a distributed database?” If you can only wave hands about cryptography and immutability, you lose credibility. But if you can walk through the block structure, the hashing chain, and the consensus rules, you win trust.

Building from scratch forces you to confront every abstraction. You will implement each piece—hashing, blocks, transactions, Merkle trees, UTXOs, mining—and in doing so, you will internalize the invariants that make blockchains secure. You will appreciate why Bitcoin uses SHA-256, why Merkle proofs exist, and why the UTXO model prevents double-spending. By the end, you won’t just be a user of blockchains; you will be a builder.

---

### Core Concepts: The Anatomy of a Blockchain

Before we write a single line of Python, let’s establish a shared vocabulary. At its heart, a blockchain is an append-only ledger of transactions grouped into blocks. Each block is linked to the previous one via a cryptographic hash, forming a chain that is tamper-evident. Let’s break down the components:

- **Block**: A container that holds a list of transactions, a timestamp, a reference to the previous block’s hash, a nonce (for Proof of Work), and a Merkle root (a hash of all transactions). The block’s own hash is computed from these fields.

- **Chain**: A sequence of blocks where each block’s `previous_hash` equals the hash of the block before it. This chain is stored redundantly across many nodes (peers) in a peer-to-peer network.

- **Node**: A participant that maintains a copy of the blockchain, validates new blocks, and relays transactions. Nodes run the consensus protocol to agree on the canonical chain.

- **Consensus**: The mechanism by which nodes agree on which block to add next. Bitcoin uses Proof of Work (PoW): miners compete to find a hash below a target difficulty. Other chains use Proof of Stake, PBFT, or Raft.

- **Transaction**: A transfer of value or data from one address to another. In the UTXO model, transactions consume previous outputs and create new outputs. Each output can be spent only once.

- **Merkle Tree**: A binary tree of hashes where each leaf is a transaction hash. The root is stored in the block header. It allows efficient verification that a transaction is included in a block without downloading the whole block.

- **Wallet**: A private/public key pair that signs transactions. The public key (or its hash) serves as the address. Only the owner of the private key can spend outputs locked to that address.

These concepts are not just theoretical. They translate directly into data structures in code. For example, a block in Python might look like:

```python
class Block:
    def __init__(self, index, transactions, previous_hash, nonce=0):
        self.index = index
        self.timestamp = time.time()
        self.transactions = transactions
        self.previous_hash = previous_hash
        self.nonce = nonce
        self.merkle_root = self.compute_merkle_root()
        self.hash = self.compute_hash()
```

We will flesh out each method in later sections. The point is: by implementing these classes, you internalize why each field exists and how they interact to produce security.

---

### Cryptographic Foundations: Hashing and Signatures

Blockchains are built on two cryptographic primitives: hash functions and digital signatures. Without them, the ledger would be neither tamper-proof nor permissionless.

#### Hash Functions

A cryptographic hash function takes an input of arbitrary length and produces a fixed-size output that appears random. The key properties:

- **Deterministic**: Same input always yields same hash.
- **Fast to compute**: For any input, the hash is quick.
- **Preimage resistant**: Given a hash, finding an input that produces it is computationally infeasible.
- **Collision resistant**: Finding two different inputs that hash to the same value is infeasible.
- **Avalanche effect**: A small change in input drastically changes the hash.

Bitcoin uses SHA-256. In Python, using the `hashlib` library:

```python
import hashlib

def sha256(data: str) -> str:
    return hashlib.sha256(data.encode()).hexdigest()
```

This function will be the workhorse of our blockchain. It links blocks together: each block contains the hash of the previous block, so changing any part of a block changes its hash, which breaks the chain unless all subsequent blocks are rehashed—a computationally expensive task in PoW.

#### Digital Signatures

To prove ownership of an output, a transaction must be signed by the private key corresponding to the address. Standard algorithms include ECDSA (Elliptic Curve Digital Signature Algorithm) used in Bitcoin. For our prototype, we can use the `ecdsa` library (or implement a stub). The flow:

1. Generate key pair: `sk` (private key), `vk` (public key).
2. Sign a message (e.g., transaction data) with `sk` → signature.
3. Verify with `vk` and signature.

In Python:

```python
from ecdsa import SigningKey, VerifyingKey, SECP256k1

sk = SigningKey.generate(curve=SECP256k1)
vk = sk.verifying_key
message = b"send 1 BTC to Alice"
signature = sk.sign(message)
assert vk.verify(signature, message)  # True
```

Public keys are hashed to produce addresses (e.g., using SHA-256 then RIPEMD-160). For simplicity, we can treat the public key itself as the address in our prototype.

---

### Data Structures: Blocks, Transactions, and UTXOs

Let’s dive deeper into the core data structures that make up a functional blockchain.

#### Block Structure

A block header typically contains:

- **Version**: To upgrade rules.
- **Previous Block Hash**: Links to parent.
- **Merkle Root**: Hash of all transactions.
- **Timestamp**: Unix time (seconds since epoch).
- **Difficulty Target**: For PoW, the number of leading zeros required.
- **Nonce**: Counter varied during mining.

The block body contains the list of transactions. In our implementation, we’ll store both header and transactions together.

#### Transaction Structure (UTXO Model)

In the UTXO model, there is no concept of “balance”. Instead, each transaction spends _unspent transaction outputs_ (UTXOs) and creates new UTXOs. A transaction input references a previous output by its transaction ID and output index. The input also includes a script that proves ownership (typically a signature). A transaction output specifies an amount and a locking script (e.g., a public key hash). The sum of inputs must equal sum of outputs (plus optional fee for miners).

Example transaction structure:

```python
class TransactionInput:
    def __init__(self, tx_id, output_index, signature):
        self.tx_id = tx_id
        self.output_index = output_index
        self.signature = signature  # scriptSig

class TransactionOutput:
    def __init__(self, amount, public_key_hash):
        self.amount = amount
        self.public_key_hash = public_key_hash  # scriptPubKey

class Transaction:
    def __init__(self, inputs, outputs):
        self.inputs = inputs
        self.outputs = outputs
        self.tx_id = self.compute_hash()
```

#### Merkle Tree

A Merkle tree allows efficient verification that a transaction is included in a block. Each leaf is a transaction hash, and internal nodes are hashes of concatenated children. The Merkle root is stored in the block header. To prove a transaction is in a block, you only need the path from the leaf to the root (the Merkle proof).

Implementation:

```python
def merkle_root(hashes):
    if not hashes:
        return ""
    if len(hashes) == 1:
        return hashes[0]
    new_hashes = []
    for i in range(0, len(hashes), 2):
        left = hashes[i]
        right = hashes[i+1] if i+1 < len(hashes) else left
        new_hashes.append(sha256(left + right))
    return merkle_root(new_hashes)
```

We will use this to compute the `merkle_root` for each block.

#### UTXO Set

The UTXO set is the set of all unspent transaction outputs at a given point. It is not stored in the blockchain itself but is derived by scanning all transactions from genesis. For performance, nodes maintain a database of UTXOs. In our prototype, we can simulate it with a dictionary mapping `(tx_id, output_index)` to `TransactionOutput`.

When processing a new block, we remove inputs (marking them spent) and add new outputs. This is where double-spending prevention occurs: if a transaction tries to spend an already spent UTXO, it’s invalid.

---

### Consensus Mechanism: Proof of Work

Proof of Work is the engine that secures the blockchain without a central authority. Miners compete to find a nonce such that the block’s hash is less than a target value. The target is adjusted periodically to keep the block time constant (e.g., 10 minutes for Bitcoin).

In our Python prototype, we will implement a simple PoW:

```python
class Blockchain:
    def __init__(self):
        self.chain = []
        self.difficulty = 4  # number of leading zeros
        self.create_genesis_block()

    def create_genesis_block(self):
        genesis = Block(0, [], "0"*64)  # previous hash = 64 zeros
        genesis.hash = self.mine_block(genesis)
        self.chain.append(genesis)

    def mine_block(self, block):
        target = "0" * self.difficulty
        while block.hash[:self.difficulty] != target:
            block.nonce += 1
            block.hash = block.compute_hash()
        return block.hash
```

The `compute_hash` method serializes the block header fields into a string and computes SHA-256. By adjusting `difficulty`, we control the average number of hashes required. For demonstration, a difficulty of 4 means the hash must start with four zeros (probability 1/16^4 = 1/65536). This is trivially fast on a laptop but illustrates the concept.

---

### Implementation Walkthrough: Building the Prototype Step by Step

Now we will assemble all the pieces into a working blockchain. We’ll write code that runs in a single Python script, but the design can be scaled to a network.

#### Step 1: Utility Functions

Start with hashing and key generation.

```python
import hashlib
import time
import json
from ecdsa import SigningKey, VerifyingKey, SECP256k1

def sha256(data):
    return hashlib.sha256(data.encode()).hexdigest()

def generate_keypair():
    sk = SigningKey.generate(curve=SECP256k1)
    vk = sk.verifying_key
    return sk, vk
```

#### Step 2: Block Class

```python
class Block:
    def __init__(self, index, transactions, previous_hash, nonce=0):
        self.index = index
        self.timestamp = time.time()
        self.transactions = transactions  # list of Transaction objects
        self.previous_hash = previous_hash
        self.nonce = nonce
        self.merkle_root = self.compute_merkle_root()
        self.hash = self.compute_hash()

    def compute_merkle_root(self):
        tx_hashes = [tx.tx_id for tx in self.transactions]
        return merkle_root(tx_hashes) if tx_hashes else "0"*64

    def compute_hash(self):
        header = (str(self.index) + str(self.timestamp) +
                  self.previous_hash + self.merkle_root +
                  str(self.nonce))
        return sha256(header)
```

#### Step 3: Transaction and UTXO Classes

```python
class TransactionInput:
    def __init__(self, tx_id, output_index, signature):
        self.tx_id = tx_id
        self.output_index = output_index
        self.signature = signature

class TransactionOutput:
    def __init__(self, amount, public_key_hash):
        self.amount = amount
        self.public_key_hash = public_key_hash

class Transaction:
    def __init__(self, inputs, outputs):
        self.inputs = inputs
        self.outputs = outputs
        self.tx_id = self.compute_hash()

    def compute_hash(self):
        data = json.dumps([(inp.tx_id, inp.output_index) for inp in self.inputs] +
                          [(out.amount, out.public_key_hash) for out in self.outputs])
        return sha256(data)
```

#### Step 4: Blockchain Class with PoW and UTXO Validation

```python
class Blockchain:
    def __init__(self, difficulty=4):
        self.chain = []
        self.difficulty = difficulty
        self.utxo_set = {}  # key: (tx_id, output_index) -> TransactionOutput
        self.miner_reward = 50  # coinbase reward
        self.create_genesis_block()

    def create_genesis_block(self):
        # Genesis transaction: coinbase
        coinbase_tx = self.create_coinbase_tx()
        genesis = Block(0, [coinbase_tx], "0"*64)
        genesis.hash = self.proof_of_work(genesis)
        self.chain.append(genesis)
        self.update_utxo_set(genesis)

    def create_coinbase_tx(self, miner_address="genesis"):
        # For simplicity, reward goes to a dummy address
        output = TransactionOutput(self.miner_reward, miner_address)
        return Transaction([], [output])

    def proof_of_work(self, block):
        target = "0" * self.difficulty
        while block.hash[:self.difficulty] != target:
            block.nonce += 1
            block.hash = block.compute_hash()
        return block.hash

    def add_block(self, block):
        previous_block = self.chain[-1]
        if block.previous_hash != previous_block.hash:
            return False
        if not self.validate_transactions(block.transactions):
            return False
        block.hash = self.proof_of_work(block)
        self.chain.append(block)
        self.update_utxo_set(block)
        return True

    def validate_transactions(self, transactions):
        # Check each transaction inputs are valid
        for tx in transactions:
            input_sum = 0
            output_sum = sum(out.amount for out in tx.outputs)
            for inp in tx.inputs:
                key = (inp.tx_id, inp.output_index)
                utxo = self.utxo_set.get(key)
                if utxo is None:
                    return False
                # Verify signature (simplified)
                # In practice, check signature against utxo.public_key_hash
                input_sum += utxo.amount
            if input_sum < output_sum:  # allow fee
                return False
            # Ensure no double spend within same block
        return True

    def update_utxo_set(self, block):
        for tx in block.transactions:
            # Remove spent inputs
            for inp in tx.inputs:
                key = (inp.tx_id, inp.output_index)
                if key in self.utxo_set:
                    del self.utxo_set[key]
            # Add new outputs
            for i, out in enumerate(tx.outputs):
                key = (tx.tx_id, i)
                self.utxo_set[key] = out
```

#### Step 5: Simple Wallet and Creating Transactions

A wallet holds a private key and can create signed transactions.

```python
class Wallet:
    def __init__(self):
        self.sk, self.vk = generate_keypair()
        self.address = self.vk.to_string().hex()  # use public key as address

    def create_transaction(self, outputs, utxo_set):
        # Collect enough UTXOs
        inputs = []
        total_input = 0
        needed = sum(out.amount for out in outputs)
        for (tx_id, idx), utxo in utxo_set.items():
            if utxo.public_key_hash == self.address:
                inputs.append(TransactionInput(tx_id, idx, None))
                total_input += utxo.amount
                if total_input >= needed:
                    break
        if total_input < needed:
            raise Exception("Insufficient funds")
        # Sign inputs
        for inp in inputs:
            # Sign the transaction data (simplified: sign hash of all outputs)
            message = sha256(json.dumps([(out.amount, out.public_key_hash) for out in outputs]))
            inp.signature = self.sk.sign(message.encode())
        # Create change output if needed
        change = total_input - needed
        if change > 0:
            outputs.append(TransactionOutput(change, self.address))
        return Transaction(inputs, outputs)
```

#### Step 6: Putting It All Together

Let’s simulate a simple scenario: create a blockchain, mine a genesis block, create a wallet, send coins.

```python
if __name__ == "__main__":
    blockchain = Blockchain(difficulty=4)

    # Create Alice's wallet (she gets coinbase reward)
    alice = Wallet()
    # Add a transaction from genesis to Alice (simplified: we manually spend the coinbase)
    # In a real system, the first transaction after genesis would be a normal transaction.
    # For demo, we'll just create a simple block.

    # Let's mine a new block with a coinbase transaction sending reward to Alice
    coinbase_tx = blockchain.create_coinbase_tx(alice.address)
    block1 = Block(1, [coinbase_tx], blockchain.chain[-1].hash)
    success = blockchain.add_block(block1)
    print("Block 1 mined:", success)
    print("Alice UTXOs:", [(k,v.amount) for k,v in blockchain.utxo_set.items() if v.public_key_hash == alice.address])

    # Now Alice sends 10 coins to Bob
    bob = Wallet()
    tx = alice.create_transaction([TransactionOutput(10, bob.address)], blockchain.utxo_set)
    block2 = Block(2, [tx], blockchain.chain[-1].hash)
    success = blockchain.add_block(block2)
    print("Block 2 mined:", success)
    print("Bob UTXOs:", [(k,v.amount) for k,v in blockchain.utxo_set.items() if v.public_key_hash == bob.address])
```

This prototype, though minimal, captures the essence of a blockchain. It implements PoW, UTXO management, transaction validation, and block linking. Of course, many real-world details are omitted: peer-to-peer networking, mempool for unconfirmed transactions, script verification, difficulty adjustment, and more. But the core logic is exactly what runs in Bitcoin Core.

---

### Testing and Running the Prototype

To run the code, ensure you have the `ecdsa` library installed (`pip install ecdsa`). The script will produce output showing the chain growth and UTXO updates. You can experiment with:

- Changing the difficulty to see mining times.
- Creating multiple wallets and transactions.
- Attempting to double-spend (the validation should reject).
- Adding invalid blocks (e.g., wrong previous hash) to see rejection.

Here’s an extended test that checks double-spend prevention:

```python
# Attempt double spend: create two transactions spending same UTXO
tx1 = alice.create_transaction([TransactionOutput(5, bob.address)], blockchain.utxo_set)
tx2 = alice.create_transaction([TransactionOutput(5, bob.address)], blockchain.utxo_set)  # same UTXO!
block3 = Block(3, [tx1, tx2], blockchain.chain[-1].hash)
success = blockchain.add_block(block3)
print("Block 3 (double-spend) mined:", success)  # Should be False
```

Our validation checks that each input UTXO exists in the UTXO set at the time of block validation. Since both transactions spend the same UTXO, after processing the first transaction, the UTXO is removed, so the second transaction’s input is invalid. However, note that our current `validate_transactions` processes all transactions in a block sequentially within the loop; we need to ensure that within a block, we also check for duplicate inputs. We can add a set of spent keys during validation. That’s a refinement left as an exercise.

---

### Security Considerations and Limitations

Our prototype is functional but not production-ready. Here are key security gaps:

- **No signature verification**: We only check UTXO existence, not that the signature matches the owner. An attacker could forge transactions if they know the public key hash. We must implement full ECDSA verification.
- **No difficulty adjustment**: In Bitcoin, difficulty adjusts every 2016 blocks to maintain 10-minute blocks. Without it, constant difficulty leads to inconsistent block times.
- **No peer-to-peer network**: Our blockchain is single-node. Real chains require gossip protocols, block relay, and fork resolution (longest chain rule).
- **No mempool**: Unconfirmed transactions are not broadcast or stored; our blockchain only processes transactions included directly in blocks.
- **No transaction fees**: Miners are not incentivized to include transactions beyond the coinbase reward.
- **No script system**: Bitcoin uses Script for locking conditions (e.g., multi-sig, timelocks). We use simple public key hash.
- **Block size limits**: We don’t enforce a maximum number of transactions per block.
- **Orphan blocks**: No handling for blocks that arrive out of order.

Addressing these would turn our minimal prototype into a real blockchain client. However, the foundational understanding you gain from building this simplistic version is invaluable. You now know why chains are called chains, why nonces exist, and how UTXOs prevent double-spending.

---

### Conclusion: From Black Box to Builder’s Toolkit

We started with a paradox: blockchain, the technology of transparency, remains opaque to most developers. By peeling back the layers and writing code from scratch, we turned that opacity into clarity. You now have a running prototype that encapsulates the core ideas: blocks chained by hashes, transactions that consume and create UTXOs, and a Proof of Work mechanism that secures the ledger.

But this is just the beginning. The real power of understanding these primitives lies in what you can build next. Want a private permissioned chain? Replace PoW with a simple PBFT. Need to store arbitrary data? Extend the transaction output to include a data field. Crave privacy? Integrate zero-knowledge proofs. Each modification builds on the foundation we laid here.

As you move forward, remember: every blockchain, from Bitcoin to the newest DeFi chain, is just a set of carefully chosen trade-offs implemented with the same basic tools—hashing, signing, and consensus. The next time someone tells you they’re “blockchain-ing” something, ask them to show you their Merkle tree. If they can’t, you’ll know they’re just using a slow database.

Now, go build something that matters. The chain is yours to extend.

---

_This post is part of a series on building blockchains from scratch. In the next installment, we will add networking, implement a simple gossip protocol, and run a multi-node blockchain. Stay tuned._
