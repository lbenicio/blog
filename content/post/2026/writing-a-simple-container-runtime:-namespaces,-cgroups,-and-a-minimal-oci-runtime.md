---
title: "Writing A Simple Container Runtime: Namespaces, Cgroups, And A Minimal Oci Runtime"
description: "A comprehensive technical exploration of writing a simple container runtime: namespaces, cgroups, and a minimal oci runtime, covering key concepts, practical implementations, and real-world applications."
date: "2026-03-02"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Writing-A-Simple-Container-Runtime-Namespaces,-Cgroups,-And-A-Minimal-Oci-Runtime.png"
coverAlt: "Technical visualization representing writing a simple container runtime: namespaces, cgroups, and a minimal oci runtime"
---

# The Illusion of Containers: Demystifying Linux Namespaces, Cgroups, and the Lies We Tell Ourselves

## Introduction: The Magic Trick That Changed the World

The command is deceptively simple:

```bash
docker run -it ubuntu:latest /bin/bash
```

You type it, and within seconds, you are dropped into what feels like a completely separate machine. A pristine filesystem appears as if from nowhere. A unique process tree stands alone, unaware of the thousands of sibling processes running on the host. A separate network stack with its own IP address, routing table, and even network interfaces. You can install packages, delete files, or bring the whole thing down with a malicious `rm -rf /`, and the host machine will remain utterly indifferent. It’s a magic trick that has redefined how we build, ship, and deploy software over the past decade.

But what if the trick broke? What if you needed to debug a network namespace leak that causes a container to lose connectivity? What if a rogue process inside a container consumes more memory than its cgroup limit allows, triggering the OOM killer? At that moment, the "magic" becomes a frustrating black box. You stare at `docker inspect`, `kubectl describe pod`, and `htop`, but nothing makes sense. The container appears to have memory usage well below its limit, yet it keeps getting killed. The network inside the container works fine, but external services cannot reach it. The filesystem inside the container is writable, but changes vanish on restart.

This feeling of magic is the single greatest barrier to mastery in the cloud-native ecosystem. We treat containers as if they are lightweight virtual machines, a mental model that is convenient but fundamentally incorrect. A VM runs a full guest operating system kernel on top of a hypervisor, accepting the overhead of a second kernel and all its subsystems. A container, on the other hand, is just a set of ordinary Linux processes, heavily cloaked in isolation. There is no container kernel. There is no container operating system. There is only the host kernel, the `clone()` syscall, a few carefully crafted files in `/proc` and `/sys/fs/cgroup`, and a lot of clever orchestration. The term "container" is a marketing abstraction – a convenient label for a bundle of Linux kernel features that together provide the illusion of isolation.

Understanding this distinction is not an academic exercise; it is a cornerstone of debugging, security hardening, and performance tuning in production. When you know that a container’s PID namespace is just a remapping of process IDs, you understand why you can't kill a host process from inside a container. When you know that cgroups control resource accounting via pseudo-filesystems, you can diagnose OOM kills by reading `memory.current` and `memory.swap.current` directly. When you know that network namespaces are isolated network stacks that can be moved between processes with `nsenter`, you can debug connectivity issues by attaching to a container’s network namespace from the host.

Let me give you a concrete example of why this matters. A few years ago, I was debugging an incident where a Kubernetes pod running a legacy Java application was killed by the OOM killer every 72 hours. The pod had a perfectly reasonable memory limit set – 512 MB. The Java heap was limited to 256 MB. Yet, like clockwork, the pod would be OOM-killed, restart, run fine for three days, then die again. A "black box" engineer would bump the limit to 1 GB and hope for the best, wasting resources and masking the underlying problem. Instead, we inspected the pod's cgroup. We logged into the Kubernetes worker node and ran:

```bash
cat /sys/fs/cgroup/memory/kubepods/burstable/pod<uid>/memory.current
```

The current memory usage was only 300 MB – well below the limit. But when we checked the swap accounting:

```bash
cat /sys/fs/cgroup/memory/kubepods/burstable/pod<uid>/memory.memsw.usage_in_bytes
```

It showed 1.2 GB! The container was using massive amounts of swap, and the OOM killer was triggered by the combined memory+swap limit (which defaults to the limit alone if swap accounting is enabled, but often includes swap usage). The Java application had a memory leak in a native library that was allocating memory via `mmap` – memory that was not counted in the JVM heap but was still accounted in the cgroup. Without understanding that cgroups track all memory (including kernel slab, page cache, and tmpfs) we would have never found the root cause. We fixed the native library leak, and the pod ran stably for months.

This story illustrates the central thesis of this blog post: containers are not magic. They are constructed from a handful of kernel primitives that are powerful but finite. To master containers, you must understand those primitives. In this deep dive, we will peel back every layer of the container abstraction. We will cover:

- **Namespaces**: The isolation mechanism that gives each container its own view of the world (process IDs, network, filesystem, etc.).
- **Cgroups**: The control groups that limit and account resource usage (CPU, memory, I/O, etc.).
- **How they are combined**: The syscalls (`clone`, `unshare`, `pivot_root`) and filesystem tricks (overlayfs, bind mounts) that Docker and containerd use to create containers.
- **Security layers**: Capabilities, seccomp, AppArmor/SELinux, and user namespaces.
- **Real-world debugging techniques**: How to inspect namespaces and cgroups from the host to understand what a container is actually doing.
- **Orchestration complications**: How Kubernetes adds additional layers of cgroup hierarchies and pod sandboxes.
- **Advanced topics**: Rootless containers, cgroup v2, huge pages, and NUMA awareness.

By the end, you will never look at a container the same way again. You will see through the magic and understand the operating system machinery underneath. And you will be equipped to debug the most elusive container problems in production.

---

## Part 1: The Anatomy of Namespaces – How Containers See the World

### 1.1 The Problem: What Needs to Be Isolated?

When you run a traditional Linux process, it sees the entire system: all processes (via `/proc`), all network interfaces, all mount points, all hostnames, all user IDs, all inter-process communication (IPC) resources. It shares the same process tree, the same network stack, and the same filesystem. This is fine for a desktop machine, but for running many mutually distrusting workloads on a single host, we need isolation. If one process can see another’s memory, or kill another’s processes, or modify the system’s network configuration, then security and stability are impossible.

Virtual machines solve this by providing a complete hardware abstraction and running a separate kernel. But that is heavyweight: each VM requires its own kernel, its own init system, and consumes gigabytes of RAM for overhead. Containers take a different approach: they reuse the host kernel but restrict what each process can see and do. The mechanism for this restriction is namespaces.

A namespace wraps a global system resource in an abstraction that makes it appear to processes within the namespace that they have their own isolated instance of that resource. Changes to that resource by processes in one namespace are invisible to processes in other namespaces. There are currently eight namespaces in the Linux kernel (as of kernel 5.6), each isolating a different aspect of the system:

- **Mount (mnt)** – isolates filesystem mount points
- **Process ID (pid)** – isolates process IDs
- **Network (net)** – isolates network stack (interfaces, routes, firewall rules)
- **Interprocess Communication (ipc)** – isolates System V IPC and POSIX message queues
- **UTS (uts)** – isolates hostname and domainname
- **User ID (user)** – isolates user and group ID mappings
- **Cgroup (cgroup)** – isolates the view of the cgroup filesystem (used in container runtimes)
- **Time (time)** – isolates system time (newer, less commonly used)

Every Linux process belongs to exactly one of each type of namespace at any given moment. When a process is created via `fork()` or `clone()`, it inherits the namespaces of its parent. To create a new namespace, you call `clone()` with one or more `CLONE_NEW*` flags. The resulting child process will be placed in new namespaces of the specified type. The `unshare()` syscall does the same to an existing process (without creating a new process). This is how `docker run`, `unshare`, and `podman` create containers.

### 1.2 The Mount Namespace – The Fires of Filesystem Isolation

The mount namespace isolates the set of filesystem mount points seen by processes in that namespace. Without it, all processes on the system share the same mount table – if one process mounts a filesystem, all others see it. With a mount namespace, each container gets its own view of the filesystem, which is typically a layered root filesystem provided by OverlayFS.

Let’s explore this interactively. First, check your current mount namespace ID and see what mounts you see:

```bash
# Get the mount namespace inode (unique identifier)
ls -l /proc/self/ns/mnt
# Output: lrwxrwxrwx 1 root root 0 ... mnt:[4026531840]

# List all mounted filesystems in the current namespace
cat /proc/self/mounts | head -10
```

Now, let's create a new mount namespace using `unshare`. We'll run a bash session with only the mount namespace isolated:

```bash
sudo unshare --mount --propagation=private bash
```

Inside this new shell, we are in a fresh mount namespace. The mounts we see are a copy of the parent namespace's mount points (depending on propagation type), but any changes we make are private. For instance, we can do:

```bash
mkdir /tmp/mytest
mount --bind /tmp/mytest /mnt
```

Now, from another terminal on the host (outside the container), check if `/mnt` exists:

```bash
ls /mnt
# Should be empty or show the original content, not our bind mount
```

The host does not see our new mount because it's in a different mount namespace. However, note that we are still running as root (inside the new namespace) and have full privileges over the new namespace's mount table. This is why containers are often run with reduced capabilities.

In container runtimes, the mount namespace is used to provide each container with its own root filesystem. The typical sequence is:

1. Create a new mount namespace with `clone()` or `unshare()`.
2. Mount the container image layers (OverlayFS) to create a combined root.
3. Use `pivot_root()` or `chroot()` to change the process's root to the new filesystem.
4. Mount special filesystems like `proc`, `sysfs`, `devtmpfs` inside the new root.

The mount namespace also interacts with shared subtrees. By default, mount events in a new namespace can propagate to other namespaces (and vice versa) if the mount propagation type is set to shared. Container runtimes typically set the mount propagation to `private` or `slave` to prevent accidental leaks.

#### Debugging Mount Namespace Problems

A common issue is a container that cannot mount a filesystem (e.g., NFS, tmpfs) because the mount namespace is misconfigured. To debug, you can enter the container's mount namespace from the host using `nsenter`:

```bash
# Find the container's PID
docker inspect <container> --format '{{.State.Pid}}'
# Let's say it's 12345

# Enter the mount namespace of that process
sudo nsenter --target 12345 --mount bash
# Now you can run mount, df, lsblk as if inside the container
```

Alternatively, you can inspect the mount namespace's bound mounts by reading `/proc/<pid>/mountinfo`. This file shows detailed information about each mount point, including mount ID, parent ID, device, and propagation type. This is invaluable for debugging OverlayFS layers or missing mounts.

### 1.3 The PID Namespace – The Illusion of Process Isolation

The PID namespace makes processes inside the namespace think they have their own process ID numbering starting from 1 (the init process). In reality, each process in the namespace has a global PID on the host, but the mapping is hidden. Containers run their own `init` process (PID 1) which is typically the entrypoint command (e.g., `/bin/bash`). If that process dies, the container exits.

This isolation is critical for security: a process in a PID namespace cannot see processes outside that namespace (by examining `/proc`). It cannot send signals to them (unless they are in the same namespace or the sender has `CAP_KILL` outside the namespace). But note: the process **can** still be killed by the host root using the global PID, or by the OOM killer, because the kernel's signal delivery bypasses namespaces.

Let's explore PID namespaces:

```bash
# Start a shell in a new PID namespace
sudo unshare --fork --pid bash
# Now inside, try:
echo $$
# Output: 1
ps aux
# You see only two processes: bash and ps
```

But from the host, this bash process has a real PID (e.g., 45678). The host can see it in its own process list. The PID namespace simply hides that mapping.

How does a container get a separate `/proc` filesystem? Inside the PID namespace, the process mounts a new `proc` filesystem that is specific to that namespace:

```bash
mount -t proc proc /proc
```

After this, `/proc` will show only the processes in the current PID namespace. In Docker containers, this is done automatically.

#### The Zombie Reaper Problem

One subtlety: when a process in a PID namespace exits, its child processes (orphans) are reparented to the init process (PID 1) of that namespace. If that init process does not reap zombies (i.e., call `waitpid()` on them), they remain as zombies and can exhaust PID resources. In Docker, the entrypoint is often a shell, which does not reap children. This is why it's common to see zombie processes accumulating in containers. The solution is to use a lightweight init process like `tini` or `dumb-init` as the entrypoint.

#### Debugging PID Namespace Leaks

Sometimes processes from one namespace leak into another, or you need to find the global PID for a container process to attach a debugger. Commands:

```bash
# Get the global PID for the container init process
docker inspect <container> --format '{{.State.Pid}}'

# List all PIDs inside a container (from host perspective)
sudo nsenter --target <PID> --pid cat /proc/1/status
# Or use Docker's top command
docker top <container>
```

For network namespaces (next section), you'll need to enter the network namespace separately.

### 1.4 The Network Namespace – Building a Virtual Network Stack

The network namespace isolates everything related to networking: network interfaces, IP addresses, routing tables, firewall rules (`iptables`/`nftables`), socket connections, and even the `/proc/net` directory. Each container gets its own network stack, typically with a virtual Ethernet pair (veth) connecting it to the host bridge (`docker0` or `cni0`).

To see the network namespace isolation in action:

```bash
# Host: list all network namespaces (usually none visible by default)
ip netns list
# (empty)

# Create a new network namespace
sudo unshare --net bash
# Inside the new ns:
ip addr
# Only the loopback interface lo is present (usually down)
ip link set lo up
# Now you have localhost only

# From host, you can't see the container's interfaces in ip link output
```

Docker creates network namespaces for each container and then sets up routing and masquerading to allow external connectivity. The container sees a `eth0` interface with an IP address in the Docker bridge subnet (172.17.0.0/16 by default). The host sees the other end of the veth pair (e.g., `vetha1b2c3`) on the Docker bridge.

#### Accessing a Container’s Network Namespace

This is one of the most useful debugging techniques. Suppose a container cannot reach the internet, but DNS resolution works. You can enter the container's network namespace from the host and run `tcpdump`, `curl`, `ping`, etc.:

```bash
# Get the container's PID
PID=$(docker inspect <container> --format '{{.State.Pid}}')

# Enter the network namespace
sudo nsenter --target $PID --net bash
# Now you are inside the container's network stack
# Run commands as if inside:
curl google.com
tcpdump -i any
ip route show
```

You can also use `nsenter` to bring a host process into a container's network namespace (useful for debugging connectivity between containers):

```bash
# Run a new shell on the host but inside the container's network namespace
nsenter --target $PID --net --mount --uts --ipc bash
```

This gives you the container's full environment without running a new Docker container – perfect for installing diagnostic tools like `tcpdump`, `netstat`, or `nslookup`.

#### Network Namespace Leaks and Cleanup

Sometimes veth pairs are not cleaned up when a container exits (due to runtime bugs or kernel issues). This can exhaust the number of available network namespaces (system-wide limit is controlled by `/proc/sys/user/max_net_namespaces`). To list all network namespaces on the host:

```bash
ls /var/run/netns/   # This directory holds named network namespaces (used by ip netns)
# But container namespaces are not typically listed here.
# Instead, find all processes with unique net namespaces:
ls -l /proc/*/ns/net | sort -k11,12 -u
```

Or use a tool like `ps -eo pid,args | xargs -I{} sh -c 'a=$1; ls -l /proc/$a/ns/net' _ {}` to see PID to netns mapping.

### 1.5 Other Namespaces: UTS, IPC, User, Cgroup, Time

**UTS namespace**: Isolates hostname and domainname. Each container can have its own hostname (set via `--hostname` in Docker). This allows the `hostname` command inside a container to return a custom name, while the host remains unchanged.

**IPC namespace**: Isolates System V IPC (shared memory, semaphores, message queues) and POSIX message queues. Containers cannot communicate with host processes via IPC resources like shared memory segments. This prevents memory exhaustion attacks and data leaks.

**User namespace**: This is perhaps the most important for security. User namespaces allow a process to run with a full set of privileges **inside** the namespace (including root) while having very limited privileges outside. The kernel maps UIDs and GIDs within the namespace to a set of UIDs/GIDs on the host. For example, a process running as UID 0 (root) inside the namespace can be mapped to UID 100000 on the host. This means that even if a container root breaks out, it is only a non-root user on the host. Docker by default runs with user namespaces disabled for historical reasons, but Podman and newer Docker configurations enable them. Rootless containers require user namespaces.

When user namespaces are used, the kernel checks permissions against the namespace's own capability set. So a process can have `CAP_NET_ADMIN` inside the namespace and modify its network stack, but cannot affect the host's network.

**Cgroup namespace**: Isolates the view of the cgroup filesystem. In cgroup v1, each process sees a different path in `/proc/self/cgroup` depending on its cgroup. The cgroup namespace hides the host's cgroup hierarchy and presents a simpler, container-specific view. This prevents information leaks and allows container runtimes to manage cgroups without the container being able to modify its own limits.

**Time namespace**: Newer (Linux 5.6+). Allows a process to see a different system time (CLOCK_MONOTONIC) than the host. Useful for testing time-dependent applications without affecting the rest of the system.

### 1.6 Putting It All Together: Creating a Container Manually

To truly understand containers, build one from scratch using shell commands and `unshare`. The following script creates a minimal container with isolated namespaces:

```bash
#!/bin/bash
# Create a root filesystem (could be a tar of Alpine)
mkdir -p container_root
cd container_root
# Expand a minimal root filesystem (e.g., Alpine)
# We'll skip that; assume you have an /mnt/root directory

# Unshare all namespaces
unshare --fork --pid --mount --uts --ipc --net --user -m /bin/bash <<'EOF'
# In the new namespace, as root inside user namespace (but UID 0 mapped to host UID)
# Mount proc
mount -t proc proc /proc
# Mount sysfs
mount -t sysfs sys /sys
# Mount devtmpfs
mount -t devtmpfs dev /dev
# Change hostname
hostname mycontainer
# Now you are in a container-like environment
# But no network, no filesystem besides root
EOF
```

This is a crude version of what runtimes like `runc` do. They also set up OverlayFS for the root filesystem, create cgroups, set resource limits, drop capabilities, attach the container to a network bridge, and so on.

---

## Part 2: Cgroups – How Containers Are Kept in Their Resource Bounds

### 2.1 The Need for Resource Accounting and Limiting

Namespaces provide isolation of views, but they do not limit resource usage. A process inside a PID namespace can still consume 100% of all CPU cores, fill up all RAM, and saturate disk I/O, starving other processes on the host. That's where control groups (cgroups) come in.

Cgroups are a kernel feature that allows grouping processes into hierarchies, and then applying resource limits, accounting, and prioritization to those groups. Every process on a modern Linux system belongs to exactly one cgroup in each resource controller hierarchy (in cgroup v1), or to a unified hierarchy (in cgroup v2). The container runtime creates a cgroup for each container, and then sets memory limits, CPU shares, block I/O throttling, and more.

### 2.2 Cgroup v1 vs v2

The cgroup subsystem has evolved. There are two major versions in use today:

- **cgroup v1 (legacy)**: Multiple hierarchies, one per resource controller. For example, memory controller's hierarchy is mounted at `/sys/fs/cgroup/memory`, CPU at `/sys/fs/cgroup/cpu`, etc. This led to confusing interactions (e.g., a process in one cgroup for memory but another for CPU).
- **cgroup v2 (unified hierarchy)**: A single hierarchy mounted at `/sys/fs/cgroup` that handles all controllers. Simpler, more consistent, and required for some modern features like writeback throttling and pressure stall information (PSI).

Most modern distributions (Ubuntu 20.04+, Fedora 31+, Docker 20.10+, Kubernetes 1.19+) default to cgroup v2. However, many production systems still run cgroup v1 due to legacy tooling.

For the rest of this section, we'll focus on cgroup v2 concepts, but note the v1 equivalents where relevant.

### 2.3 Discovering Cgroups on Your System

Let's explore the cgroup filesystem. On a cgroup v2 system:

```bash
# Mounted at /sys/fs/cgroup
mount | grep cgroup2
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,relatime)

# List the top-level cgroups
ls /sys/fs/cgroup/
# Typical entries: system.slice, user.slice, kubepods (if Kubernetes), docker (if Docker cgroup driver)
```

Each directory represents a cgroup. Within each directory, you'll find:

- `cgroup.procs` – list of PIDs in this cgroup
- `cgroup.subtree_control` – which controllers are delegated to child cgroups
- `memory.current` – current memory usage in bytes
- `memory.max` – memory hard limit
- `memory.min` – memory guarantee
- `cpu.max` – CPU quota and period (e.g., `100000 100000` means 1 CPU)
- `io.max` – I/O limits for devices
- `pids.current` – current number of processes
- `pids.max` – maximum number of processes allowed

For cgroup v1, the analogous files are in separate directories like `/sys/fs/cgroup/memory/memory.limit_in_bytes`, `memory.usage_in_bytes`, etc.

### 2.4 How Docker Creates Cgroups for a Container

When you run `docker run -m 512m --cpus 1.5 myimage`, Docker (via containerd and runc) does something like this:

1. Create a cgroup directory under the appropriate slice. For Docker with cgroup v2, it might be `/sys/fs/cgroup/system.slice/docker-<container_id>.scope/`.
2. Write the memory limit to `memory.max`: `echo 536870912 > memory.max`.
3. Write the CPU quota and period: `echo 150000 100000 > cpu.max` (150 ms out of 100 ms = 1.5 CPUs).
4. Move the container's process into the cgroup: `echo $PID > cgroup.procs`.
5. Monitor the container's resource usage via the accounting files.

### 2.5 Debugging OOM Kills – The Memory Controller

Let's return to the OOM story from the introduction. The Java application was being killed despite appearing to have memory usage below the limit. The key insight is that cgroups track many types of memory, not just anonymous pages (heap, stack) but also:

- **Page cache** (file-backed memory)
- **Kernel slab** (kernel memory allocations)
- **Sockets** (socket buffer memory)
- **tmpfs** (memory-backed filesystems like `/dev/shm`)
- **Swap usage** (if enabled)

The OOM killer in cgroup v2 will kill a process in the cgroup if total memory usage (including swap if a swap limit is set) exceeds `memory.max`. However, if no swap limit is set, the OOM killer relies on the system's overall memory pressure; but with cgroup v1, there is a separate `memory.memsw.limit_in_bytes` that includes swap.

In the Java case, the native library was allocating memory via `mmap` with `MAP_ANONYMOUS` and then mapping large files into memory. These allocations showed up as page cache (or shared memory) and contributed to the cgroup's memory usage. By inspecting `memory.current` (v2) or `memory.usage_in_bytes` (v1) we saw only a fraction of the total. But `memory.stat` revealed the truth:

```bash
cat /sys/fs/cgroup/memory/kubepods/burstable/pod<uid>/memory.stat
# For v2: cat memory.stat
# For v1: cat memory.stat
# Look for fields like:
# - cache (page cache)
# - rss (anonymous pages)
# - shmem (shared memory, tmpfs)
# - mapped_file (memory mapped files)
```

In our case, `cache` was in the gigabytes. The application was mmap'ing large data files and never munmap'ing them, causing the page cache to grow until the OOM killer stepped in.

#### Steps to Diagnose OOM Kills in Production

1. **Check system logs for OOM events**:

   ```bash
   sudo dmesg | grep -i "oom" | tail -20
   ```

   Look for "Memory cgroup out of memory" and the processes killed.

2. **Find the container's cgroup path**:

   ```bash
   # Docker
   docker inspect <container> --format '{{.HostConfig.CgroupParent}}'
   # Or find from /proc/<pid>/cgroup
   cat /proc/<pid>/cgroup
   # For v2: something like 0::/system.slice/docker-xxx.scope
   ```

3. **Read memory statistics from the cgroup**:

   ```bash
   # v2
   cat /sys/fs/cgroup/system.slice/docker-xxx.scope/memory.stat
   # v1
   cat /sys/fs/cgroup/memory/docker/<container_id>/memory.stat
   ```

4. **Check OOM kills counter**:

   ```bash
   # v2
   cat /sys/fs/cgroup/.../memory.events
   # Look for "oom_kill 1"
   # v1
   grep "oom" /sys/fs/cgroup/memory/.../memory.oom_control
   ```

5. **Look at per-process memory usage inside the container**:
   Enter the container's PID and memory namespace and run `top` or `smem`:
   ```bash
   nsenter --target <PID> --pid cat /proc/1/status | grep VmRSS
   # Or install procps inside the namespace
   nsenter --target <PID> --pid --mount bash -c "apt-get update && apt-get install -y smem && smem"
   ```

### 2.6 CPU Throttling and Latency Issues

CPU cgroups limit the total amount of CPU time a container can consume. In cgroup v2, the `cpu.max` file contains a quota (in microseconds) and a period (in microseconds). For example, `100000 100000` means 100 ms of CPU time per 100 ms period = 1 CPU. If the container's processes run longer than that, they are throttled – paused until the next period.

Throttling can cause latency spikes, especially for bursty workloads. To detect throttling, look at `/sys/fs/cgroup/.../cpu.stat`:

```bash
cat cpu.stat
# nr_periods, nr_throttled, throttled_usec
```

If `nr_throttled` is a large fraction of `nr_periods`, your container is hitting its CPU limit frequently. You might need to increase the limit or reduce CPU demand.

### 2.7 Disk I/O Throttling

Block I/O cgroups (`io` controller in v2, `blkio` in v1) allow limiting read and write bandwidth per device. For example:

```bash
# v2: limit reads to 10 MB/s on device 8:0
echo "8:0 rbps=10485760" > io.max
# v1:
echo "8:0 10485760" > /sys/fs/cgroup/blkio/.../blkio.throttle.read_bps_device
```

One common pitfall: If you set I/O limits but the filesystem is on a network drive (NFS, Ceph), the block device is not local, and the `io` controller may not apply. Use tools like `iotop` inside the container to see actual I/O.

### 2.8 The PIDs Controller and Fork Bombs

The PIDs controller limits the number of processes that can exist in a cgroup. This prevents a container from causing a fork bomb that crashes the host. In cgroup v2:

```bash
# Set maximum number of PIDs
echo 100 > pids.max
# Check current count
cat pids.current
```

If a container attempts to exceed this limit, `fork()` fails with `EAGAIN`. This is why some workloads that spawn many threads (e.g., browsers, compilation jobs) may fail unexpectedly.

### 2.9 Swap and Memory Overcommit

Swap can allow a container to use more memory than its limit, but at the cost of severe performance degradation (thrashing). In cgroup v2, swap is accounted separately: `memory.swap.current` and `memory.swap.max`. If `memory.swap.max` is not set, the default is `max` (unlimited). The OOM killer only triggers when total memory + swap swap usage exceeds `memory.max + memory.swap.max`? Actually, in cgroup v2, the OOM killer considers total memory usage (including swap) against `memory.max`. If you have no swap limit, the OOM killer will kill if `memory.current > memory.max`, even if the excess is in swap? No, the kernel reclaims swap before OOM. But if swap is unlimited, the OOM killer may not trigger until swap itself is exhausted, which can take a long time. To avoid that, always set a swap limit equal to the memory limit (disabling swap) or a small amount.

In Kubernetes, by default, swap is disabled on nodes (or enabled with implications for QoS classes). So OOM kills are purely due to physical memory pressure.

### 2.10 Cgroup v2 Specifics: Delegation, Pressure Stall Information (PSI), and Resource Domains

Cgroup v2 introduced the concept of "resource domains" and "minimum guarantees". The `memory.min` and `memory.low` files allow setting a guaranteed amount of memory that will not be reclaimed under memory pressure. This is used by Kubernetes in Guaranteed QoS pods.

PSI files (`memory.pressure`, `cpu.pressure`, `io.pressure`) provide a measure of resource pressure on the system. They indicate the fraction of time that tasks in the cgroup are stalled due to resource shortages. This is crucial for proactive eviction in Kubernetes.

---

## Part 3: How Container Runtimes Combine Namespaces and Cgroups

### 3.1 The Container Runtime Stack

The modern container runtime stack consists of several layers:

1. **High-level runtime** (e.g., Docker, containerd, podman, CRI-O) – exposes API for managing images, containers, networks, volumes.
2. **Low-level runtime** (e.g., runc, crun, kata-runtime) – creates the actual container using Linux kernel primitives.
3. **OCI specification** – standard for container image and runtime configuration.

When you type `docker run`, the request goes to containerd (or dockerd), which pulls the image, prepares the rootfs, and calls `runc` (the low-level runtime) with an OCI bundle (a directory containing `config.json` and rootfs). `runc` reads `config.json`, which specifies all the namespaces, cgroup settings, capabilities, mounts, and process arguments. Then it creates the container:

- Clone a new process with `clone()` passing flags for each desired namespace.
- In the child, do:
  - `setns()` to join existing namespaces (if any)
  - Mount proc, sys, dev from inside the mount namespace
  - Apply cgroup settings (write limits, move PID)
  - Set secure computing (seccomp) filter
  - Drop capabilities
  - Apply AppArmor/SELinux profiles
  - Change root with `pivot_root()`
  - `exec()` the container entrypoint

### 3.2 Anatomy of `config.json`

Let's look at a simplified OCI config for a container:

```json
{
  "ociVersion": "1.0.0",
  "process": {
    "args": ["/bin/bash"],
    "capabilities": {
      "bounding": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", ...],
      "effective": ["CAP_CHOWN", ...]
    }
  },
  "root": {
    "path": "rootfs",
    "readonly": false
  },
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc"},
    {"destination": "/sys", "type": "sysfs", "source": "sysfs"},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid","strictatime","mode=755","size=65536k"]}
  ],
  "linux": {
    "namespaces": [
      {"type": "pid"},
      {"type": "mount"},
      {"type": "network"},
      {"type": "uts"},
      {"type": "ipc"}
    ],
    "resources": {
      "memory": {"limit": 536870912, "reservation": 268435456},
      "cpu": {"shares": 1024, "quota": 100000, "period": 100000}
    },
    "cgroupsPath": "/system.slice/docker-<id>.scope",
    "seccomp": {
      "defaultAction": "SCMP_ACT_ERRNO",
      "architectures": ["SCMP_ARCH_X86_64"],
      "syscalls": [{"names": ["accept", "bind", "connect", ...], "action": "SCMP_ACT_ALLOW"}]
    }
  }
}
```

This config tells `runc` exactly what isolation to apply.

### 3.3 OverlayFS – The Filesystem Magic

One of the most magical parts of containers is the layered filesystem. Docker images are composed of layers (read-only). When you start a container, a thin writable layer is added on top. OverlayFS merges these layers into a single view.

The commands are:

```bash
# Lower layers (image layers) as read-only
lowerdir=/var/lib/docker/overlay2/l/<layer1>:/var/lib/docker/overlay2/l/<layer2>:...
# Upper layer (container's writable changes)
upperdir=/var/lib/docker/overlay2/<container_id>/diff
# Workdir for atomic operations
workdir=/var/lib/docker/overlay2/<container_id>/work
# Merge into a single mount point
mount -t overlay overlay -o lowerdir=$lowerdir,upperdir=$upperdir,workdir=$workdir /var/lib/docker/overlay2/<container_id>/merged
```

The container then uses `pivot_root` to make this merged directory its root. Any writes go to the upper layer, which survives a container restart only if committed to a new image.

To debug OverlayFS issues (such as missing files when copying data into a container, or "no space left" on the upper layer), you can check disk usage on the overlay2 directory:

```bash
du -sh /var/lib/docker/overlay2/<container_id>/diff
# Or see the merged directory's disk usage from inside the container's mount namespace
nsenter --target <PID> --mount df -h /
```

### 3.4 Rootless Containers and User Namespaces

Traditional Docker runs containers as root (even if the process inside is not root). This is a security risk because if a container escapes, it may have root privileges on the host. Rootless containers solve this by using user namespaces to map the container's root to a non-root UID on the host. Additionally, they must use a different storage driver (fuse-overlayfs) because the home directory is not trusted for overlay mounts. Podman uses this by default.

The key insight: user namespaces allow a process to have capabilities inside its namespace (like `CAP_NET_RAW` to create raw sockets) without having those capabilities on the host. Combined with network namespaces, rootless containers can create their own network stacks (using slirp4netns or pasta for user-mode networking).

## Part 4: Security Layers – Beyond Isolation

Namespaces and cgroups provide isolation and resource control, but they are not sufficient for security on a shared kernel. Additional layers are needed to restrict what system calls a container can make, what capabilities it can use, and what files it can access.

### 4.1 Linux Capabilities

Traditionally, root (UID 0) has all privileges. Capabilities break those privileges into separate, atomic units (e.g., `CAP_NET_ADMIN` for network administration, `CAP_SYS_ADMIN` for mount, `CAP_SETUID` for changing UIDs). In a container, you can drop dangerous capabilities like `CAP_SYS_ADMIN` (which allows mounting filesystems) or `CAP_SYS_MODULE` (loading kernel modules). Docker by default uses a whitelist of safe capabilities.

To see the capabilities of a container:

```bash
docker inspect <container> --format '{{range .HostConfig.CapAdd}}{{.}} {{end}}'
docker inspect <container> --format '{{range .HostConfig.CapDrop}}{{.}} {{end}}'
```

From inside the container, `cat /proc/1/status | grep Cap` shows capability bitmasks. Decode them with `capsh --decode=<bitmask>`.

### 4.2 Seccomp – System Call Filtering

Seccomp (secure computing mode) allows a process to specify which system calls it can make. A container runtime can install a seccomp profile that blocks dangerous system calls (like `mount`, `reboot`, `kexec_load`, `bpf`). Docker ships with a default seccomp profile that blocks ~44 system calls. See it with:

```bash
docker info --format '{{json .SecurityOptions}}' | jq
# Or read the profile from the Docker source: default.json
```

You can write custom seccomp profiles to allow or deny specific syscalls, perhaps to enable `ptrace` for debugging or `perf_event_open` for profiling.

### 4.3 AppArmor and SELinux

These are Linux Security Modules (LSMs) that provide mandatory access control (MAC). AppArmor uses profiles attached to executables or paths. SELinux uses labels. Container runtimes can apply profiles to restrict what files a container can read/write, what network can be accessed, and more.

In Docker, you can specify an AppArmor profile with `--security-opt apparmor=myprofile`. Without it, Docker uses a default profile that is quite permissive.

### 4.4 User Namespaces (Revisited)

User namespaces are the most powerful security feature. When combined with other namespaces, they allow a container to run as root inside its own namespace but have no privileges on the host. The mapping is defined in `/proc/<pid>/uid_map` and `/proc/<pid>/gid_map`. For rootless containers, the mapping is typically:

```
         0       100000       65536
```

Meaning UID 0 inside the namespace maps to UID 100000 on the host, and UIDs up to 65535 inside map to host UIDs 100001-165535.

### 4.5 Limiting Privileged Operations

If you give a container `--privileged`, you essentially disable all isolation – it has root on the host, all capabilities, access to all devices, no seccomp restrictions. This is incredibly dangerous. In Kubernetes, you should never run privileged pods unless absolutely necessary (e.g., for cluster networking daemons like Calico).

## Part 5: Debugging in the Trenches – Real-World Scenarios

### 5.1 Scenario: Container Runs Out of Disk Space on the Writable Layer

Symptom: container exits with "no space left on device" errors when writing to its filesystem.

Causes:

- The OverlayFS upper layer fills up (check `df -h` inside the container's mount namespace).
- The container's disk quota is exhausted (if using `--storage-opt size=<size>` in Docker, or `proc`/`sys` mount is full? unlikely).

Debug:

```bash
# Find the upper layer directory
docker inspect <container> --format '{{.GraphDriver.Data.UpperDir}}'
# Check its disk usage
sudo du -sh /var/lib/docker/overlay2/<upper_dir>
# Also check the merged directory (but that's virtual)
# To see actual disk space inside the container:
nsenter --target <PID> --mount df -h /
# If the root is overlay, look at the usage of the underlying filesystem
```

Solution: either increase the storage driver size (if using device mapper), clean up files, or use volumes for temporary data.

### 5.2 Scenario: Pod Stuck in ContainerCreating State (CNI Network Setup Failure)

Symptom: A Kubernetes pod stays in ContainerCreating. The container runtime cannot set up networking.

Debug:

```bash
# Describe the pod
kubectl describe pod <pod>
# Look for events like "Failed to create pod sandbox" or "failed to set up network"
# Check kubelet logs on the node
journalctl -u kubelet -f --lines 100
# Check container runtime logs (containerd or docker)
journalctl -u containerd
# Check CNI plugin logs (usually in /var/log/cni/ or journalctl of cni)
# Check if the container's network namespace was created
PID=$(docker inspect --format '{{.State.Pid}}' <container>)
sudo nsenter --target $PID --net -t 1 ip addr show
# If loopback only, CNI didn't set up the veth pair.
# Check if the network namespace exists:
ls -l /proc/$PID/ns/net
# You can also check the CNI plugins: bridge, host-local IPAM, etc.
```

Common causes:

- Flannel daemon not running
- Missing sysctl `net.bridge.bridge-nf-call-iptables`
- IP address exhaustion in the pod CIDR
- Firewall blocking veth pairs

### 5.3 Scenario: Zombie Processes Accumulating in a Container

Symptom: Container's process table fills up with zombie processes (visible via `ps aux` inside the container as `defunct`).

Cause: The init process (PID 1) inside the container does not reap orphaned children. This is typical for shells or Java applications.

Fix: Use a proper init process like `tini` (included in Docker 1.13+ with `--init`). In Kubernetes, set the `shareProcessNamespace` option to use a pause container as PID 1.

To debug:

```bash
# Enter the container's PID namespace
nsenter --target <PID> --pid --mount bash
# Run ps aux | grep defunct
# Count them: ps aux | grep -c "defunct"
# Check the parent of the zombies: ps -eo pid,ppid,stat,cmd | grep Z
# The parent is likely the container's init (PID 1) which is not calling wait()
```

### 5.4 Scenario: High CPU Throttling in Kubernetes

Symptom: Application reports high latency, but CPU usage inside the container appears low. Pod has CPU limits set.

Debug:

```bash
# Find the container's cgroup path
CTR_ID=$(kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/docker:\/\///')
# For cgroup v2:
cat /sys/fs/cgroup/kubepods/burstable/pod<uid>/cpu.stat
# Look for nr_throttled and throttled_usec
# Also check CPU usage: cat /sys/fs/cgroup/kubepods/burstable/pod<uid>/cpuacct.usage (v1)
# Use tools like 'sysstat' to see if the container is being throttled
# Run top inside the container (nsenter) to see per-process CPU
```

If throttling is severe, consider increasing the CPU limit or switching to `requests` only (no limits, but beware of QoS degradation).

### 5.5 Scenario: Network Connectivity Randomly Drops for a Container

Symptom: Container can ping external IP but fails to connect to a specific port, or connections drop after a few seconds.

Debug:

```bash
# Enter the network namespace and use tcpdump
nsenter --target <PID> --net tcpdump -i any port <port>
# Also check conntrack table (connection tracking) for shenanigans
# On the host:
sudo conntrack -E -p tcp -d <container_ip> -p tcp
# Check iptables rules: may be dropping packets due to a stale rule
# Check if the container's network namespace still has a default route
nsenter --target <PID> --net ip route
# Should show default via <gateway>
# Check ARP for the gateway
nsenter --target <PID> --net arp
# Check if the veth pair is up
ip link show | grep veth
```

Often the issue is with iptables rules for masquerading, especially on systems with many containers where conntrack table overflows.

---

## Part 6: Orchestration and the Kubernetes Twist

### 6.1 Pods Are Not Containers

In Kubernetes, the basic unit is a **Pod**, which is a group of containers that share the same network namespace, IPC namespace, and sometimes PID namespace (if `shareProcessNamespace` is set). The `pause` container is used to hold these namespaces and keep them alive even if the main container restarts.

Kubernetes itself does not directly use `runc`. Instead, it communicates with containerd or CRI-O through the CRI (Container Runtime Interface). The kubelet writes an OCI-compatible config plus special annotations to tell the runtime about sandbox IDs, pod UIDs, and QoS class.

### 6.2 Kubernetes Cgroup Hierarchy

Kubernetes creates a cgroup tree under `/sys/fs/cgroup/kubepods/` (v2) or `/sys/fs/cgroup/kubepods/` (v1). The hierarchy reflects the pod's QoS class:

- **Guaranteed**: all containers have equal requests and limits.
- **Burstable**: at least one container has a request less than its limit.
- **BestEffort**: no requests or limits set.

The cgroup path for a pod might be: `/sys/fs/cgroup/kubepods/burstable/pod<uid>`. Inside, each container gets a subdirectory (e.g., `container<id>`).

This hierarchy allows the kubelet to enforce eviction thresholds based on cgroup memory pressure (using `memory.usage_in_bytes`, `memory.soft_limit_in_bytes`, etc.).

### 6.3 Debugging Pod Eviction

When a node runs out of memory, kubelet evicts pods, starting with BestEffort and then Burstable. The eviction decision is based on the node's overall memory pressure, but it looks at per-pod cgroup memory limits. To understand why a pod was evicted:

```bash
# Check kubelet logs
journalctl -u kubelet -n 100 | grep -i "evict"
# Check the node condition
kubectl describe node <node> | grep -A5 "Conditions"
# Check memory pressure on the node
cat /sys/fs/cgroup/memory/memory.pressure (v2)
# Or check PSI files: cat /sys/fs/cgroup/system.slice/memory.pressure
```

### 6.4 Implementing a Custom Scheduler That Reads Cgroup Metrics

Advanced users can write Kubernetes scheduler extensions that read real-time cgroup metrics (like `memory.current`, `cpu.usage`) to make scheduling decisions. This requires accessing the cgroup filesystem on each node (or using a metrics API like the kubelet's summary stats). The cgroup data is also exposed via the Container Runtime Interface (CRI) for resource monitoring.

---

## Part 7: Advanced Topics

### 7.1 Cgroup v2 Unified Hierarchy – Advantages and Migration

Cgroup v2 simplifies many things: no more mixed hierarchies, uniform file naming across controllers, better delegation of resource control to child cgroups, and support for PSI. However, some tools (like older versions of Docker and `cgmanager`) are incompatible. Migration steps:

- Ensure kernel 4.15+ (recommended 5.2+ for all features).
- Add kernel boot parameter `systemd.unified_cgroup_hierarchy=1`.
- Use Docker 20.10+ with `"exec-opts": ["native.cgroupdriver=systemd"]`.
- For Kubernetes, enable the `CgroupV2` feature gate in older versions (1.19+ defaults to v2 if kernel supports).

### 7.2 Huge Pages and NUMA

Huge pages (2 MB or 1 GB) reduce TLB misses for memory-intensive workloads. In cgroup v2, you can set `hugetlb.1GB.max` and `hugetlb.2MB.max`. Kubernetes allows requesting huge pages via `resources.requests.hugepages-2Mi`.

NUMA awareness: The kernel can pin cgroup memory allocations to a specific NUMA node using cgroup v2's `memory.numa_stat` and the `cpuset` controller. This is critical for latency-sensitive applications.

### 7.3 eBPF and Observability

eBPF programs can be attached to cgroup events (e.g., `cgroup_skb`, `cgroup_sock`) to monitor or modify behavior. Tools like `bpftrace` can trace cgroup operations:

```bash
bpftrace -e 'tracepoint:cgroup:cgroup_attach_task { printf("PID %d attached to cgroup %s\n", args->pid, args->path); }'
```

This is powerful for debugging process migration and cgroup hierarchy changes.

### 7.4 Container Security Beyond Isolation

Even with all namespaces and cgroups, a kernel exploit can break out. The "sharing the kernel" problem is inherent to containers. Security best practices:

- Use user namespaces whenever possible.
- Run containers with read-only root filesystems.
- Drop all capabilities except those needed.
- Use seccomp profiles.
- Use SELinux/AppArmor.
- Regularly scan for known kernel vulnerabilities (CVE-2022-0492 for cgroup bypass, etc.).
- Consider using Kata Containers (lightweight VMs via hypervisor) for multi-tenant workloads.

---

## Conclusion: The Magic Is in the Kernel

We started with the illusion of a lightweight virtual machine, but we have unmasked the reality: containers are a clever composition of Linux kernel primitives – namespaces for isolation, cgroups for resource management, overlay filesystems for images, and security modules for confinement. Each piece is a set of files in `/proc` and `/sys`, a handful of syscalls, and a lot of configuration in `config.json`. There is no magic bullet; there is only engineering.

When you encounter a container problem that feels like black magic, remember to go back to the kernel. Find the container's PID, enter its namespaces with `nsenter`, read its cgroup files, inspect its network stack with `ip netns`, and trace syscalls with `strace`. The answers are always there, written in the filesystem of the host. The container is not a separate machine; it is a constrained view of the one machine you are standing on.

The next time you run `docker run -it ubuntu:latest /bin/bash`, take a moment to appreciate the layers of complexity that make that second feel effortless. And then, when something breaks, you will know exactly where to look: the kernel.

**Further Reading:**

- Linux kernel documentation on namespaces and cgroups (kernel.org)
- OCI runtime spec (github.com/opencontainers/runtime-spec)
- Docker and containerd source code
- Brendan Gregg's blog on container performance and observability
- "Linux Containers: Why They're Not Like VMs" by Solomon Hykes (Docker creator)

_This blog post is part of a series on deep container debugging. Next up: "Tracing Container Syscalls with eBPF" and "Kubernetes Pod Lifecycle: From Admit to Evict"._
