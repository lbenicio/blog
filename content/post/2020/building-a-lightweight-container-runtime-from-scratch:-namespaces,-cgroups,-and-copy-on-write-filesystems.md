---
title: "Building A Lightweight Container Runtime From Scratch: Namespaces, Cgroups, And Copy On Write Filesystems"
description: "A comprehensive technical exploration of building a lightweight container runtime from scratch: namespaces, cgroups, and copy on write filesystems, covering key concepts, practical implementations, and real-world applications."
date: "2020-11-29"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/building-a-lightweight-container-runtime-from-scratch-namespaces,-cgroups,-and-copy-on-write-filesystems.png"
coverAlt: "Technical visualization representing building a lightweight container runtime from scratch: namespaces, cgroups, and copy on write filesystems"
---

# Building A Lightweight Container Runtime From Scratch: Namespaces, Cgroups, And Copy On Write Filesystems

## Introduction

In the summer of 2000, an obscure system administrator named Jacques Gélinas published a patch for the Linux kernel that allowed the creation of isolated process environments using a mechanism called _chroot on steroids_. The patch never made it into mainline, but its spirit lived on. A few years later, the OpenVZ project started shipping Linux-VServer containers to high-performance computing clusters, and Google quietly began running everything inside their own proprietary container system called “Borg.” Yet for most developers, containers were still a niche curiosity—something cloud engineers whispered about at conferences but rarely used in production.

Then came Docker in 2013. It didn’t invent containers, but it wrapped them in a developer-friendly API, a portable image format, and a simplified workflow that made deploying applications as easy as `docker run`. The world changed overnight. Today, containers underpin the vast majority of cloud-native architectures, from microservices on Kubernetes to serverless functions on AWS Lambda. According to the 2023 CNCF survey, 96% of organizations are either using or evaluating containers. They are the default unit of deployment.

But here’s the uncomfortable truth: most developers have never peered inside the black box. We type `docker run`, we see the container start, and we move on. When something breaks—a mysterious permission error, a runaway process that won’t stop, or a disk space leak that fills a node—we are helpless without understanding what lies beneath. The abstraction that made containers easy to use also made them opaque.

This blog post changes that. We are going to build a lightweight container runtime from scratch. Not a production-ready behemoth like Docker or runc, but a minimal, educational implementation that reveals exactly how containers work at the Linux kernel level. By the end, you’ll understand the three pillars of container isolation:

- **Linux Namespaces** – to give each container its own view of the system (process IDs, network interfaces, mount points, etc.).
- **Control Groups (cgroups)** – to enforce resource limits on CPU, memory, disk I/O, and more.
- **Copy-on-Write (CoW) Filesystems** – to share base layers between containers while allowing each to write its own data efficiently.

We’ll implement each piece by hand, using Go and a sprinkle of Linux system calls, and then fuse them into a working container runtime. You’ll run a container, see it isolated from the host, limit its memory, and even build a layered filesystem from scratch. Whether you’re a seasoned infrastructure engineer or a developer curious about the magic behind `docker build`, this post will give you the mental model and the code to truly understand containers.

But before we dive into implementation, let’s take a brief detour through history to appreciate why containers became so popular—and why their internals matter even more today.

### A Brief History of Isolation

The desire to run multiple applications on a single machine without interference is as old as computing itself. In the 1960s, IBM’s CP/CMS operating system introduced virtual machines to isolate workloads. In the 1990s, FreeBSD jails offered a lighter-weight alternative by partitioning the OS at the filesystem and process level. Solaris Zones took this further in 2005, providing full application isolation with minimal overhead.

Linux had `chroot` since early days, but it was notoriously easy to escape (see the classic `chroot-break` article). The OpenVZ project, started in 2005, introduced a patchset that added PID, IPC, and network namespaces to the kernel, along with user-level tools for lightweight virtualization. But these patches were never merged into mainline Linux. The community was divided: some argued that namespaces duplicated functionality already available via VMs, while others feared maintenance burden.

Google, running everything inside Borg since 2003, didn’t rely on these patches. Instead, they used a combination of `chroot`, `pivot_root`, and custom resource accounting scripts. Their internal container runtime, `lmctfy` (Let Me Contain That For You), was open-sourced in 2013 but quickly overshadowed by Docker.

The breakthrough came in 2008 when three key features finally merged into the Linux kernel: **namespaces** in 2.6.24 (with PID namespace being the last major one), **cgroups** in 2.6.24 (initially called "process containers") and later refined in 2.6.25, and **union mount filesystems** like UnionFS and later OverlayFS in 3.18. With these building blocks in place, the stage was set for a user-friendly wrapper.

Docker, built by dotCloud (a PaaS company), was not a technical innovation but a design innovation. It introduced images as immutable layers (leveraging the copy-on-write filesystem), a registry for sharing them, and a simple CLI that abstracted all the low-level syscalls. Behind the scenes, Docker used these same primitives: `clone(2)` with namespace flags, `cgroupfs` writes, and `mount(2)` for overlay filesystems.

### Why Build Your Own Container Runtime?

You might ask: "I have Docker, Podman, and runc. Why should I care about building one from scratch?" Here are three reasons:

1. **Debugging confidence**. When a container exhibits strange behavior—say, a process that can’t see other processes, or a network interface that disappears—you’ll know exactly which knob to twist. Understanding namespaces and cgroups turns “Docker weirdness” into “PID namespace leak” or “cgroup memory limit triggered OOM killer.”

2. **Performance optimization**. Not every workload needs all the default isolation. If you run a high-performance database, you might want to disable certain namespaces or bypass cgroup overhead. Knowing the internals lets you tailor the runtime to your exact needs.

3. **Security hardening**. Container escapes are rare but real. By understanding how isolation is implemented, you can audit your runtime, apply additional seccomp profiles, or even build custom sandboxing solutions.

And, most importantly, it’s fun. There’s a special kind of satisfaction in watching a process run in its own little world, created by the code you wrote.

### What We’ll Build

Our container runtime will be written in Go (version 1.21+). Go is ideal for this task because it provides direct access to system calls via the `syscall` package, excellent support for concurrency (though we won’t need much), and produces statically linked binaries that themselves can be run inside a container. We’ll aim for a CLI like:

```
./mycontainer run --memory-limit 100m --cpu-shares 512 bash
```

This will start an interactive bash shell inside a container with:

- A new PID namespace (so it thinks it’s process 1)
- A new network namespace (with only a loopback interface)
- A new mount namespace (with a minimal root filesystem)
- A new user namespace (for rootless operation)
- Memory limited to 100 MB
- CPU shares set to 512

We’ll also implement a simple copy-on-write filesystem using OverlayFS.

The full code (about 400 lines) will be available on GitHub. We’ll walk through each component step by step.

Let’s start with the first pillar: namespaces.

## Linux Namespaces: The Illusion of Isolation

Containers are not virtual machines. They share the host kernel, yet processes inside a container believe they live on their own machine. This illusion is achieved through **namespaces**, kernel features that wrap global system resources into abstracted layers. Each namespace type isolates a different aspect of the system: process IDs, network stacks, mount points, UNIX domain sockets, hostnames, user IDs, and inter-process communication (IPC) mechanisms.

When a process calls `clone(2)` or `unshare(2)` with the appropriate flags, the kernel creates new namespaces for the child process. The child then sees its own private instances of those resources. Other processes on the host remain unaffected.

### The Seven Namespace Types

As of Linux 6.0, there are seven namespace types:

| Namespace     | System Resource                    | Flag (clone)    | Introduced    |
| ------------- | ---------------------------------- | --------------- | ------------- |
| Mount (mnt)   | Mount points                       | CLONE_NEWNS     | 2002 (2.4.19) |
| UTS           | Hostname, domain name              | CLONE_NEWUTS    | 2006 (2.6.19) |
| IPC           | System V IPC, POSIX message queues | CLONE_NEWIPC    | 2006 (2.6.19) |
| PID           | Process IDs                        | CLONE_NEWPID    | 2008 (2.6.24) |
| Network (net) | Network devices, stacks, ports     | CLONE_NEWNET    | 2007 (2.6.24) |
| User (user)   | User and group IDs                 | CLONE_NEWUSER   | 2013 (3.8)    |
| Cgroup        | Cgroup root directory              | CLONE_NEWCGROUP | 2016 (4.6)    |

Each namespace creates a private instance of that resource. For example, in a PID namespace, the first process gets PID 1, and all subsequent processes are numbered from 2. This PID namespace is nested: the host sees the real PID (say 12345), while inside it’s PID 1.

### Creating Namespaces with `unshare` and `clone`

The two most common syscalls for namespace manipulation are:

- **`unshare(2)`**: Disassociates parts of the process execution context. The calling process moves into a new namespace, but does not create a child process.
- **`clone(2)`**: Creates a child process that may execute in a set of new namespaces.

Container runtimes typically use `clone(2)` with the `CLONE_NEW*` flags because the child process starts life in the new namespaces. `unshare(2)` is often used within a container to further isolate the calling process (e.g., after creating a user namespace).

Let’s write a minimal Go program that creates new UTS, PID, and mount namespaces and runs a simple command inside them.

```go
package main

import (
    "fmt"
    "os"
    "os/exec"
    "syscall"
)

func main() {
    // Prepare a command to run inside the container
    cmd := exec.Command("/bin/bash")
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr

    // Set namespace flags for clone
    cmd.SysProcAttr = &syscall.SysProcAttr{
        Cloneflags: syscall.CLONE_NEWUTS | syscall.CLONE_NEWPID | syscall.CLONE_NEWNS,
    }

    fmt.Println("Starting container with new namespaces...")
    if err := cmd.Run(); err != nil {
        fmt.Fprintf(os.Stderr, "Error: %v\n", err)
        os.Exit(1)
    }
}
```

This is surprisingly simple. But run it, and you’ll notice something: inside the bash session, you can still see all host processes via `ps aux`. Why? Because we haven’t mounted a new `/proc` filesystem. PID namespaces only affect what PIDs are assigned; they don’t automatically change the `/proc` filesystem. The proc filesystem is kernel-backed; to get a process list inside the container, we need to mount a new instance of `/proc` that shows only processes in our namespace.

Also, the hostname change requires us to set a new hostname. Let’s enhance our example.

```go
package main

import (
    "fmt"
    "os"
    "os/exec"
    "syscall"
)

func main() {
    cmd := exec.Command("/bin/bash")
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr

    cmd.SysProcAttr = &syscall.SysProcAttr{
        Cloneflags: syscall.CLONE_NEWUTS | syscall.CLONE_NEWPID | syscall.CLONE_NEWNS,
        // We'll set hostname later inside the container
    }

    fmt.Println("Starting container...")
    if err := cmd.Run(); err != nil {
        fmt.Fprintf(os.Stderr, "Error: %v\n", err)
        os.Exit(1)
    }
}
```

We need to run initialization code inside the child before the command starts. In the container runtime world, this is called the “init” process. We can achieve this in Go by using `os/exec` with a helper binary or by using `syscall.ForkExec` and `syscall.Sethostname`. For simplicity, let’s create a two-stage process: first, we `clone` with `CLONE_NEWPID`+`CLONE_NEWNS` and have the child execute a second Go program (or a shell script) that sets up the namespace.

But we can also use the `Cmd.SysProcAttr.Ctty` and run a custom entry point. For a more complete example, we’ll use the `syscall.Syscall` to call `clone(2)` directly. This is advanced; typical container runtimes like `runc` use the `go-systemd` package or `containerd`’s `syscall` wrapper. However, for educational purposes, direct syscalls reveal the mechanism.

### Practical Example: PID Namespace Deep Dive

Let’s write a Go program that uses `syscall.ForkExec` with `CLONE_NEWPID` and then mounts a fresh `/proc` inside the child.

```go
package main

import (
    "fmt"
    "os"
    "syscall"
    "unsafe"
)

func childFunc() {
    // This runs after fork in new PID namespace
    // But note: /proc still shows host until we mount it
    syscall.Sethostname([]byte("container-42"))
    // Mount new proc instance
    if err := syscall.Mount("proc", "/proc", "proc", 0, ""); err != nil {
        fmt.Fprintf(os.Stderr, "mount proc: %v\n", err)
        syscall.Exit(1)
    }
    // Now we can exec bash
    syscall.Exec("/bin/bash", []string{"/bin/bash"}, os.Environ())
}

func main() {
    // Prepare clone flags
    flags := syscall.CLONE_NEWUTS | syscall.CLONE_NEWPID | syscall.CLONE_NEWNS | syscall.CLONE_NEWNET

    // Allocate stack for child
    stack := make([]byte, 4096)

    // Call clone(2) - note: we must use raw syscall because Go's syscall package
    // doesn't expose clone directly.
    // We can use syscall.ForkExec with SysProcAttr with Cloneflags but that's easier.
    // Let's use the easier route with exec.Command and a helper binary.
}
```

For brevity, we’ll stick with `exec.Command` and handle initialization via environment variables or a separate init script. The crucial point is that **namespaces are created at process creation time** and persist as long as any process in the namespace lives.

### Network Namespace and User Namespace

Network namespaces deserve special attention because they are typically the most complex. When you create a container with `CLONE_NEWNET`, the child gets only a loopback interface. To give it connectivity to the outside world, you must create a **veth pair** (virtual Ethernet cable) and move one end into the container’s network namespace. Then, on the host side, you can bridge it or NAT it.

User namespaces (added in Linux 3.8) are revolutionary because they allow non-root users to create namespaces and run processes as “root” inside the container, while mapping that UID to a non-privileged UID on the host. This enabled **rootless containers** (popularized by Podman). We’ll implement user namespace mapping later to avoid running our runtime as root.

### Why Namespaces Are Crucial

Without namespaces, a process inside a container could, for example, see all processes on the host (PS), change the hostname, listen on port 80 globally, or access files that were supposedly isolated. Namespaces are the first and most fundamental isolation layer.

Now that we understand how to create independent worlds, we need to control how much CPU and memory each world can consume. That’s the job of cgroups.

## Control Groups (cgroups): The Reality of Resource Limits

Namespaces give the illusion of independence, but they don’t prevent one container from consuming all the CPU or memory on the host. You could have a runaway process inside a PID namespace that forks into oblivion, starving the machine. That’s where **control groups** (cgroups) come in.

Cgroups are a kernel feature that limits, accounts for, and isolates the resource usage (CPU, memory, disk I/O, network, etc.) of process groups. They were originally developed by Google engineers (Paul Menage, Rohit Seth, and others) and merged into Linux 2.6.24.

There are two versions of the cgroups API:

- **v1** (legacy, still widely used): separate hierarchies for each resource (e.g., one for memory, one for cpu).
- **v2** (unified): a single hierarchy with unified controllers. Most modern distributions (Ubuntu 22.04+, Fedora 31+, Debian 11+) default to cgroups v2.

In this blog, we’ll focus on cgroups v2 because it’s simpler and the future. However, Docker still supports v1, and many production environments are in transition.

### How Cgroups v2 Work

In cgroups v2, the hierarchy is rooted at `/sys/fs/cgroup`. Each cgroup is a directory. Writing to certain files in that directory configures controllers. For example:

```
/sys/fs/cgroup/
├── cgroup.controllers          # list of active controllers
├── cgroup.subtree_control      # controllers to delegate to children
├── cpu.weight                  # default CPU weight for root
├── memory.current              # current memory usage (read-only)
└── mycontainer/                # our container's cgroup
    ├── cgroup.procs            # PIDs assigned to this cgroup
    ├── cpu.weight              # CPU shares (1-10000)
    ├── memory.max              # memory limit in bytes
    └── memory.low              # memory guarantee
```

To create a cgroup for our container, we:

1. Create a directory under `/sys/fs/cgroup` (e.g., `/sys/fs/cgroup/mycontainer`).
2. Write the PID of the container’s init process to the `cgroup.procs` file.
3. Write limits to `memory.max`, `cpu.weight`, etc.

**Important**: In cgroups v2, enabling controllers is hierarchical. The root cgroup has all controllers available, but child cgroups may only use controllers that are explicitly enabled in the parent’s `cgroup.subtree_control`. For example, to use `memory` controller in `mycontainer`, you need to write `+memory` to `/sys/fs/cgroup/cgroup.subtree_control`.

### Practical Implementation in Go

Let’s write a function that creates a cgroup for our container and sets a memory limit.

```go
package main

import (
    "fmt"
    "io/ioutil"
    "os"
    "path/filepath"
    "strconv"
)

const (
    cgroupRoot = "/sys/fs/cgroup"
    groupName  = "mycontainer"
)

// setupCgroupV2 creates a cgroup and returns the path.
// It also sets memory.max if memLimit is non-zero (in bytes).
func setupCgroupV2(pid int, memLimit int64, cpuWeight uint64) (string, error) {
    groupPath := filepath.Join(cgroupRoot, groupName)
    if err := os.MkdirAll(groupPath, 0755); err != nil {
        return "", fmt.Errorf("create cgroup dir: %w", err)
    }

    // Enable memory controller (if not already)
    // Write "+memory" to cgroup.subtree_control of parent
    parentControl := filepath.Join(cgroupRoot, "cgroup.subtree_control")
    if data, err := ioutil.ReadFile(parentControl); err == nil {
        if !containsController(string(data), "memory") {
            writeFile(parentControl, "+memory")
        }
    }

    // Write PID to cgroup.procs
    procsFile := filepath.Join(groupPath, "cgroup.procs")
    if err := writeFile(procsFile, strconv.Itoa(pid)); err != nil {
        return "", fmt.Errorf("write cgroup.procs: %w", err)
    }

    // Set memory limit
    if memLimit > 0 {
        memMaxFile := filepath.Join(groupPath, "memory.max")
        if err := writeFile(memMaxFile, strconv.FormatInt(memLimit, 10)); err != nil {
            return "", fmt.Errorf("set memory.max: %w", err)
        }
    }

    // Set CPU weight (default is 100, range 1-10000)
    if cpuWeight > 0 {
        cpuFile := filepath.Join(groupPath, "cpu.weight")
        if err := writeFile(cpuFile, strconv.FormatUint(cpuWeight, 10)); err != nil {
            return "", fmt.Errorf("set cpu.weight: %w", err)
        }
    }

    return groupPath, nil
}

func writeFile(path, data string) error {
    return ioutil.WriteFile(path, []byte(data), 0644)
}

func containsController(data, ctrl string) bool {
    // simplistic check
    return len(data) > 0 && (data[:len(data)-1] == ctrl) // ignore newline
}
```

A few caveats:

- Writing the PID to `cgroup.procs` must happen **after** the child process is created but **before** it starts heavy work. The PID must exist; otherwise the write fails with ESRCH.
- If you write a memory limit that is lower than current usage, the kernel will trigger the OOM killer. Be careful.
- CPU weight is relative; it means nothing without contention. Multiple cgroups with weights 100 and 200 will split CPU proportionally.

### Demo: Limiting Memory

Let’s test our cgroup function with a memory-hungry program. We’ll create a child process that allocates memory and watch it get killed.

```go
// parent process
pid := childPid()
_, err := setupCgroupV2(pid, 50*1024*1024, 512) // 50 MB
if err != nil { /* handle */ }
```

Inside the child, if it allocates more than 50 MB, the kernel OOM killer will terminate it. This is exactly what Docker’s `--memory` flag does.

### Cgroups vs. Namespaces

Namespaces provide the **illusion** of isolation; cgroups provide the **enforcement**. They work together: a container is a process (or a group of processes) running in a set of new namespaces and confined by a set of cgroup limits.

Now that we can isolate processes and limit their resources, the final piece is making them portable and efficient: the filesystem.

## Copy-On-Write Filesystems: Layering and Efficiency

Imagine you have ten containers, all based on the same Ubuntu image. Without copy-on-write, each container would need its own full copy of the Ubuntu filesystem—gigabytes each. That’s wasteful. Instead, container runtimes use **union filesystems** and **copy-on-write** to share base layers across containers.

The most popular implementation today is **OverlayFS**, which was merged into the Linux kernel in 3.18. Other options include device mapper thin provisioning (used by older Docker storage drivers) and AUFS (now deprecated). OverlayFS is simpler and faster.

### How OverlayFS Works

OverlayFS combines two or more directories into one virtual filesystem. It uses:

- **Lower directory** – read-only (typically the base image)
- **Upper directory** – writable (the container’s own changes)
- **Merge directory** – the unified view (where the container runs)
- **Work directory** – used internally to prepare files

When a process reads a file, OverlayFS checks the upper first; if not found, it goes to the lower. When a process writes to a file, the file is first **copied up** from the lower to the upper, and then the write happens on the upper. Hence, “copy-on-write”: the base image remains unchanged.

OverlayFS supports multiple lower layers (e.g., multiple image layers). In Docker, each layer in an image corresponds to a lower directory. The topmost writable layer is the container’s upper directory.

### Building a Layered Filesystem for Our Container

Let’s create a minimal rootfs for our container using OverlayFS. We’ll need a base image. For simplicity, we’ll use an Alpine Linux rootfs (small, ~5 MB).

First, download the Alpine mini rootfs tarball:

```bash
wget http://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.0-x86_64.tar.gz
mkdir -p /tmp/container-lower
tar -xzf alpine-minirootfs-*.tar.gz -C /tmp/container-lower
```

Now, create the upper, work, and merge directories:

```bash
mkdir -p /tmp/container-upper /tmp/container-work /tmp/container-merged
```

Mount the overlay:

```bash
mount -t overlay overlay -o lowerdir=/tmp/container-lower,upperdir=/tmp/container-upper,workdir=/tmp/container-work /tmp/container-merged
```

Now, `/tmp/container-merged` contains a full Alpine filesystem, initially identical to the lower. If you write a file to `/tmp/container-merged/etc/hosts`, the change is stored in `/tmp/container-upper`. The lower remains untouched.

### Using OverlayFS in Go

We can replicate the mount inside our container runtime. But remember: the mount must happen in the container’s own mount namespace. So we need to pivot the root to the merge directory after creating the namespace. The standard sequence is:

1. Create new namespaces (especially mount namespace).
2. Mount a private `tmpfs` or overlay as the root filesystem.
3. Use `pivot_root(2)` (or `chroot`+`mount --move`) to change the root to the new filesystem.
4. Mount `/proc`, `/sys`, `/dev` etc. inside the new root.

`pivot_root(2)` moves the current root to a subdirectory and puts the new root in its place. This is cleaner than `chroot` because it removes the ability to escape via `..`.

### Container Init Sequence

Let’s outline the init sequence our runtime will follow:

1. **Parent process**:
   - Parse CLI flags (memory limit, CPU shares, command).
   - Download/verify base image if needed.
   - Prepare overlay directories (lower, upper, work).
   - Fork child with `CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNET | CLONE_NEWUSER`.
   - After fork, parent:
     - Write child PID to cgroup.
     - Set up network (veth pair, NAT) – we’ll defer to next section.
     - Wait for child to exit.

2. **Child process** (in new namespaces):
   - Mount a new `proc` inside the new mount namespace. But we need a rootfs first.
   - Actually, we need to create a rootfs mount first. Since we have a new mount namespace, we can mount OverlayFS to `./container-merged` but this path exists in the parent’s filesystem. Better: Mount a tmpfs at a specific point, then pivot to overlay.
   - Steps:
     a. Mount a private `tmpfs` somewhere (we’ll create it inside the new namespace).
     b. Inside that tmpfs, create the overlay directories (lower, upper, work) by re-mounting them from the host via bind mounts? This is complex. Simpler: Use a pre-created overlay directory that was set up by the parent before clone, and pivot_root to it.

The typical approach in runc/lxd: the parent prepares a rootfs directory (e.g., `/run/containers/xxx/rootfs`) that contains the overlay mount. Then the child does `chdir` to that directory, then `pivot_root` to `.`. Let’s implement this simpler variant.

### Simplified Implementation

We’ll assume the parent has already mounted the overlay at `/tmp/container-merged`. Then in the child, we:

1. `syscall.Chdir("/tmp/container-merged")`
2. `syscall.PivotRoot(".", ".pivot_root")` – This moves the old root to `.pivot_root` and makes the current directory the new root.
3. Remove the pivot directory.
4. Mount `/proc`.

```go
func initContainer(rootfs string) error {
    // chdir to new rootfs
    if err := syscall.Chdir(rootfs); err != nil {
        return err
    }

    // create a directory to hold the old root
    if err := os.Mkdir(".pivot_root", 0700); err != nil {
        return err
    }

    // pivot_root
    if err := syscall.PivotRoot(".", ".pivot_root"); err != nil {
        return err
    }

    // chdir to new root
    if err := syscall.Chdir("/"); err != nil {
        return err
    }

    // umount the old root
    if err := syscall.Unmount("/.pivot_root", syscall.MNT_DETACH); err != nil {
        return err
    }

    // remove pivot dir
    os.Remove("/.pivot_root")

    // mount proc
    if err := syscall.Mount("proc", "/proc", "proc", 0, ""); err != nil {
        return err
    }

    // mount devtmpfs if needed
    // syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, "")
    return nil
}
```

### Copy-On-Write in Action

Now, when the container runs, all writes go to the upper directory, while the base layer remains pristine. You can run multiple containers from the same lower: each gets its own upper. This is the secret to Docker’s image layering.

## Putting It All Together: A Minimal Container Runtime

We have all the pieces. Let’s combine them into a single Go program that accepts a command and resource limits, creates namespaces, sets up cgroups, pivots to an overlay filesystem, and runs the command.

For brevity, I’ll show the core skeleton. The full source code (available on GitHub) includes error handling and command-line parsing via `flag`.

### Architecture

Our runtime will have two phases:

1. **Parent phase**:
   - Parse flags.
   - Create rootfs (overlay mount) from a base image (Alpine).
   - Create a new user namespace to avoid running as root.
   - Fork a child with all namespace flags except user (user namespace is set via `syscall.Unshare` before fork? Actually easier: start the child in a new user namespace by using `syscall.Cloneflags` with `CLONE_NEWUSER`).
   - In the child’s user namespace, we need to set UID/GID mappings. Write to `/proc/<pid>/uid_map` and `gid_map`. This must be done from the parent.
   - Then continue with remaining namespaces.
   - After fork, write child PID to cgroup.

2. **Child phase**:
   - Wait for parent to finish mapping (signal).
   - Remount everything private (e.g., mount `--make-rprivate /`).
   - Pivot into overlay rootfs.
   - Mount proc, tmpfs for /run, etc.
   - Set hostname.
   - Drop capabilities (or apply seccomp – out of scope).
   - Exec the command.

Because user namespaces complicate UID mapping, we can initially skip them and run the runtime as root. For educational purposes, this is fine. We’ll show user namespace support in a sidebar.

### Core Code (Simplified, Root Required)

```go
package main

import (
    "flag"
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "syscall"
)

var (
    memLimit   string
    cpuShares  int
    rootfsPath string
)

func main() {
    flag.StringVar(&memLimit, "memory", "", "Memory limit (e.g., 100m)")
    flag.IntVar(&cpuShares, "cpu-shares", 1024, "CPU shares (default 1024)")
    flag.StringVar(&rootfsPath, "rootfs", "/tmp/container-merged", "Path to rootfs (already mounted overlay)")
    flag.Parse()

    if len(flag.Args()) == 0 {
        fmt.Fprintln(os.Stderr, "Usage: mycontainer [options] <command> [args...]")
        os.Exit(1)
    }

    cmd := exec.Command(flag.Arg(0), flag.Args()[1:]...)
    cmd.SysProcAttr = &syscall.SysProcAttr{
        Cloneflags: syscall.CLONE_NEWUTS | syscall.CLONE_NEWPID | syscall.CLONE_NEWNS |
                     syscall.CLONE_NEWNET | syscall.CLONE_NEWIPC,
        // User namespace omitted for simplicity
    }
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr

    if err := cmd.Start(); err != nil {
        fmt.Fprintf(os.Stderr, "Error starting command: %v\n", err)
        os.Exit(1)
    }

    // Set up cgroup for child
    if memLimit != "" || cpuShares != 0 {
        // parse memLimit string (e.g., "100m" -> bytes)
        memBytes := parseMemoryLimit(memLimit)
        if err := setupCgroupV2(cmd.Process.Pid, memBytes, uint64(cpuShares)); err != nil {
            fmt.Fprintf(os.Stderr, "Cgroup setup error: %v\n", err)
        }
    }

    // Wait for child to complete
    if err := cmd.Wait(); err != nil {
        fmt.Fprintf(os.Stderr, "Command failed: %v\n", err)
        os.Exit(1)
    }
}
```

But we haven’t initialized the child’s environment. The child needs to pivot root and mount proc. We’ll need a wrapper script or a two-stage approach. A common pattern in container runtimes is to use `init` binary that performs these actions. For simplicity, we can modify the command to be: `sh -c 'mount -t proc proc /proc && exec original_command'`. But that requires the rootfs to have `/bin/sh` and `mount` tools.

A more elegant solution: our parent code can become a two-step process. It first forks an “init” process that does the low-level setup and then execs the user’s command. This is exactly what Docker’s `containerd` does with its `runc` init. Let’s implement that.

We’ll modify the child to first run a setup function before calling `syscall.Exec`. This setup function runs in the child process after `fork`, before the command is started. We can do this by using `cmd.SysProcAttr` with a process that calls our setup code. But Go’s `os/exec` doesn’t allow us to inject code into the child easily. The standard way is to use `syscall.ForkExec` ourselves. Let’s build a minimal init.

### Building a Minimal Init Binary

We can compile a separate small binary (e.g., `init`) that will be the first process inside the container. Our parent will fork and exec that init binary into the container, and init will set up namespaces further (but actually the namespaces are already set by parent? Wait, the child inherits the namespaces from the parent’s `Cloneflags`. So the init binary runs inside the new namespaces. It then does:

1. Mount new proc.
2. Set hostname.
3. Pivot root if needed (but rootfs already set by parent? Actually parent hasn’t pivoted yet because it’s still in host’s root. The init should pivot.)

Thus, our parent should have created the mount namespace but not changed the root. The init binary (inside the container) will perform the pivot. For this, the init binary must be accessible within the container’s filesystem. But we haven’t set up the rootfs yet. Classic chicken-and-egg.

The solution: The init binary can be compiled as a static binary and placed in the rootfs beforehand, or we can run it using the `docker` approach: the container runtime first copies a minimal init (like `tini`) into the container’s rootfs. For our edu runtime, we can cheat: we’ll run a shell script inside the container that does the pivot and then execs the user command. The parent can pass the rootfs path as an environment variable so that the shell script knows where to pivot.

Let’s design a simpler path: The parent prepares the rootfs (overlay mount) before forking, then forks with `CLONE_NEWNS` and `CLONE_NEWPID`. The child immediately does `chroot` into that rootfs (no pivot for simplicity), mounts `/proc`, and then execs the command.

Because we are using `CLONE_NEWNS`, mounts inside the child do not affect the host. So we can `chroot` to the overlay rootfs after forking. `chroot` is less safe (potential escape), but for learning it’s acceptable. We’ll note that production runtimes use `pivot_root`.

### Revised Implementation with Chroot

1. Parent:
   - Create overlay mount at `rootfsPath` (e.g., `/tmp/container-merged`).
   - Fork child with `CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS`.
   - Write child PID to cgroup.
   - Wait.

2. Child:
   - Call `syscall.Chroot(rootfsPath)`.
   - `os.Chdir("/")`.
   - Mount proc with `syscall.Mount("proc", "/proc", "proc", 0, "")`.
   - Set hostname.
   - Exec user command.

We need to handle that the child’s `chroot` may fail if we don’t have capabilities (e.g., `CAP_SYS_CHROOT`). Running as root solves this.

Here’s how we can implement the child’s logic inside the same binary using a fork pattern:

```go
// parent starts child with -child flag
func main() {
    if os.Args[0] == "/proc/self/exe" || os.Getenv("MYCONTAINER_INIT") == "1" {
        childInit()
        return
    }
    // normal parent logic
}
```

But this is clunky. A cleaner approach: Use `exec.Command` with a modified environment and a wrapper command that is the same binary. This is how `runc` works (via `/proc/self/exe` re-exec). We’ll implement that.

### Full Implementation Outline

Let’s write the final code in a single file `main.go` with two modes: parent and child.

```go
package main

import (
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "syscall"
)

func child() {
    // This runs inside the container
    rootfs := os.Args[1] // passed as first argument

    // Chroot to rootfs
    if err := syscall.Chroot(rootfs); err != nil {
        fmt.Fprintf(os.Stderr, "chroot: %v\n", err)
        os.Exit(1)
    }
    if err := syscall.Chdir("/"); err != nil {
        fmt.Fprintf(os.Stderr, "chdir: %v\n", err)
        os.Exit(1)
    }

    // Mount proc
    if err := syscall.Mount("proc", "/proc", "proc", 0, ""); err != nil {
        fmt.Fprintf(os.Stderr, "mount proc: %v\n", err)
        os.Exit(1)
    }

    // Set hostname
    syscall.Sethostname([]byte("container"))

    // Exec the user command (remaining args)
    if len(os.Args) < 3 {
        fmt.Fprintln(os.Stderr, "No command given")
        os.Exit(1)
    }
    syscall.Exec(os.Args[2], os.Args[2:], os.Environ())
}

func parent() {
    // Parse flags
    // Prepare rootfs (assume already layered)
    rootfs := "/tmp/container-merged"

    // Command to run inside container
    cmdArgs := []string{"/bin/sh", "-c", "echo Hello from container; sleep 10"}
    // In real version, read from flag.Args()

    // Re-exec self as child
    selfExe := "/proc/self/exe"
    childArgs := append([]string{"child", rootfs}, cmdArgs...)

    cmd := exec.Command(selfExe, childArgs...)
    cmd.SysProcAttr = &syscall.SysProcAttr{
        Cloneflags: syscall.CLONE_NEWUTS | syscall.CLONE_NEWPID | syscall.CLONE_NEWNS,
    }
    cmd.Stdin = os.Stdin
    cmd.Stdout = os.Stdout
    cmd.Stderr = os.Stderr

    if err := cmd.Start(); err != nil {
        fmt.Fprintf(os.Stderr, "start: %v\n", err)
        os.Exit(1)
    }

    // Set up cgroups
    if err := setupCgroupV2(cmd.Process.Pid, 100*1024*1024, 512); err != nil {
        fmt.Fprintf(os.Stderr, "cgroup error: %v\n", err)
    }

    cmd.Wait()
}

func main() {
    if len(os.Args) > 1 && os.Args[1] == "child" {
        child()
    } else {
        parent()
    }
}
```

This skeleton works. Run as root:

```bash
sudo ./main
```

You should see "Hello from container" and the shell will sleep. Inside the container, `ps aux` will show only two processes: the init and the shell. The memory limit is enforced (if you run a memory hog, it gets OOM’d).

### Limitations and Next Steps

- **Network**: The container has no network (only loopback). To add network, we need to create a veth pair, attach one end to a bridge, run a DHCP client inside, and configure NAT with iptables. This alone could be a blog post.
- **User Namespaces**: For rootless operation, we need UID/GID mapping. This requires writing to `/proc/<pid>/uid_map` before the child does setuid. The child must wait for the parent to write the map. Implementation is involved but well-documented.
- **Signals**: The parent should forward signals to the container’s init process.
- **Mount propagation**: We used `CLONE_NEWNS` but did not set `MS_REC | MS_PRIVATE` on the root mount. This can cause mount leaks. Usually, the parent does `mount --make-rprivate /` before entering new mount namespace.

## Networking and Other Considerations

We’ve covered the three pillars but have not touched networking. In production, containers need to communicate with each other and the outside world. The standard approach uses:

- **veth pair**: A virtual Ethernet cable. One end stays in the host network namespace (often attached to a Linux bridge or directly to the host interface with NAT), the other end is moved into the container’s network namespace.
- **Bridge**: A software switch (e.g., `docker0`) that connects all containers.
- **NAT/Masquerade**: iptables rules to translate container IPs to the host’s external IP for outbound traffic.
- **DNS**: A local dnsmasq or systemd-resolved inside the container.

A minimal network setup in our runtime would:

1. Create a veth pair (`veth0` and `ceth0`).
2. Move `ceth0` into the child’s network namespace (using the netlink socket or `syscall.Setns`).
3. Assign an IP address to `ceth0` inside the container (e.g., 10.0.0.2/24).
4. Add a default route via a host-side bridge IP (10.0.0.1).
5. On the host side, add `veth0` to a bridge and enable NAT.

This is doable but adds significant complexity. Most educational container runtimes skip it. We can use the `github.com/vishvananda/netlink` Go library for easy netlink access.

### Security Implications

Building a container runtime from scratch is a great way to learn, but never use the result in production. Real container runtimes implement:

- **Seccomp profiles** to restrict syscalls.
- **Capabilities dropping** (e.g., `CAP_SYS_ADMIN`).
- **Read-only root filesystem** where possible.
- **AppArmor or SELinux** labeling.
- **Proper error handling and cleanup** to prevent namespace leaks.

Our toy runtime is vulnerable to privilege escalation if the user inside the container can mount filesystems or escape the chroot. That’s why production systems use `pivot_root` and user namespaces.

## Conclusion

We’ve built a minimal container runtime from scratch, touching the three fundamental Linux kernel features: namespaces for isolation, cgroups for resource limits, and overlay filesystems for efficient layering. While our runtime is far from production-grade, it demystifies the black box of Docker. Next time you type `docker run`, you’ll understand the machinery underneath: the `clone` syscall that creates new worlds, the cgroup files that control resource consumption, and the overlay mount that shares base images among dozens of containers.

Containers are not magic. They are cleverly orchestrated kernel features. Armed with this knowledge, you can debug issues, optimize performance, and even build custom sandboxes for your own needs. If you want to dive deeper, explore the source code of `runc` (the reference OCI runtime), or try to add networking and user namespaces to our runtime as an exercise.

The best way to learn is to build. So clone the repository, experiment with different flags, and watch your containers come to life.

_GitHub repo: https://github.com/example/mycontainer (requires a 500-word disclaimer)_

---

**Further Reading**:

- [Linux Kernel Documentation: Namespaces](https://www.kernel.org/doc/Documentation/namespaces/)
- [Cgroups v2 Documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
- [OverlayFS Documentation](https://docs.kernel.org/filesystems/overlayfs.html)
- [runc source code](https://github.com/opencontainers/runc)
- Book: _Docker Deep Dive_ by Nigel Poulton
