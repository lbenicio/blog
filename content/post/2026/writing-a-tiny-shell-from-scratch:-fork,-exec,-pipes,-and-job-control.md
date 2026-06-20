---
title: "Writing A Tiny Shell From Scratch: Fork, Exec, Pipes, And Job Control"
description: "A comprehensive technical exploration of writing a tiny shell from scratch: fork, exec, pipes, and job control, covering key concepts, practical implementations, and real-world applications."
date: "2026-04-29"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "static/images/blog/Writing-A-Tiny-Shell-From-Scratch-Fork,-Exec,-Pipes,-And-Job-Control.png"
coverAlt: "Technical visualization representing writing a tiny shell from scratch: fork, exec, pipes, and job control"
---

Alright, I'll expand the blog post into a comprehensive, deep-dive guide to building a Unix shell from scratch. The final output will be well over 10,000 words, covering history, core concepts, step-by-step implementation, advanced features, and practical wisdom. I'll use C for code snippets, include detailed explanations, and maintain the engaging technical style.

Let me craft the full expanded article now.# Introduction: The Shell That Whispered to the Kernel

Every developer has felt it – that quiet thrill when you type `ls -la | grep .txt` and the terminal responds with a neat list of text files. You press Enter, and somehow, magically, the machine does exactly what you asked. For decades, the shell has been the command center of Unix systems, the humble interface between human intent and kernel execution. But have you ever paused mid-command and wondered: _What actually happens between my keystroke and the output?_

Most of us treat the shell as a black box, a necessary evil or a beloved companion. We learn its syntax, we master its shortcuts, but we rarely lift the hood. That’s a shame, because inside that black box lies some of the most elegant and fundamental concepts in operating system design: process creation, interprocess communication, signal handling, and the delicate dance of job control. Building your own tiny shell – even a minimal one that can fork, exec, pipe, and manage jobs – is like building a microcosm of the entire Unix philosophy. It’s one of those rare projects that is both deeply satisfying and immediately practical.

### A Brief History of the Unix Shell

Before we dive into code, it’s worth understanding the lineage of the tool we’re about to reconstruct. The first Unix shell, the **Thompson shell** (sh), was written by Ken Thompson in 1971. It was a simple command interpreter: read a line, fork a process, execute it. No pipes, no redirection – just `run this command`. The **Bourne shell** (also sh) came in 1977 with control flow, variables, and I/O redirection. Then the **C shell** (csh) added job control and history, and the **Korn shell** (ksh) merged features. Bash (Bourne Again SHell) appeared in 1989 as the GNU project’s free replacement, and it remains the default on most Linux systems. Fish and zsh have since added syntax highlighting, autocomplete, and other niceties.

Our project will mirror the evolution: start with the simplest possible execution loop, then add pipes, redirections, job control, and built‑ins. By the end, you’ll have a shell that can run real commands (though not with bash’s sheer completeness – that would take years). More importantly, you’ll understand the kernel primitives that make every shell tick.

## Why Bother? The Case for Rolling Your Own Shell

You might ask: “Why write a shell when bash, zsh, and fish already exist, polished to perfection?” It’s a fair question. The answer is not about reinventing the wheel; it’s about understanding how the wheel is made. A shell is a quintessential systems programming exercise. It forces you to grapple with:

- **Process management**: Every command you run is a child process. Understanding `fork()`, `exec()`, and `waitpid()` is the bedrock of Unix multitasking.
- **File descriptors and I/O redirection**: The magic of `>` and `<` is simply a matter of manipulating file descriptor numbers – `dup2()` is your friend.
- **Pipes**: One of the oldest and most elegant IPC mechanisms, where the stdout of one process becomes the stdin of another, all through a pair of file descriptors.
- **Job control**: Running commands in the background (`&`), suspending them (`Ctrl+Z`), resuming them, and managing a list of jobs is a non‑trivial exercise in signal handling and process groups.
- **Signal handling**: The shell must handle `SIGINT` (Ctrl+C) gracefully, pass signals to child processes, and prevent orphan processes.
- **Terminal management**: Understanding terminal line disciplines, canonical vs. non‑canonical mode, and the role of the controlling terminal is both fascinating and pragmatic.
- **Error handling and robustness**: A shell runs in a hostile environment – invalid commands, broken pipes, out‑of‑memory conditions, and unexpected signals must all be handled without crashing.

Beyond the technical mastery, building a shell gives you a deep appreciation for the elegance of the Unix design. You’ll see why “everything is a file” is not just a slogan but a powerful abstraction. You’ll also learn to debug concurrent programs – a skill that transfers directly to writing servers, databases, and any multi‑process system.

## The Grand Plan: What We'll Build

We won’t write a full bash clone. Instead, we’ll build a shell (let’s call it `tinysh`) that supports:

- **Simple commands**: `ls -l`
- **I/O redirection**: `command > file`, `command < file`, `command >> file`
- **Pipes**: `cmd1 | cmd2 | cmd3`
- **Background execution**: `command &`
- **Job control**: `jobs`, `fg`, `bg`, handling `Ctrl+Z` and `Ctrl+C`
- **Built‑in commands**: `cd`, `exit`, `jobs`, `fg`, `bg`
- **Signal propagation**: Properly forwarding signals to foreground job processes.

We’ll write it in C, because C is the language of the Unix API. The code will be portable across Linux and other POSIX systems (macOS, BSDs). We’ll assume a modern Linux environment with glibc, but we won’t rely on GNU‑specific extensions.

## Core Primitives: Fork, Exec, Wait, and File Descriptors

Before we write a single line of code, let’s review the system calls that are the molecular building blocks of a shell. If you already know them, feel free to skip ahead – but a refresher never hurts.

### fork() – The One True Way to Create Processes

`fork()` creates a new process by duplicating the calling process. The new process is called the _child_, and the original is the _parent_. After the call, both processes continue execution from the same point. `fork()` returns the child’s PID to the parent, and 0 to the child. On failure, it returns -1.

```c
pid_t pid = fork();
if (pid == 0) {
    // child process
} else if (pid > 0) {
    // parent process
} else {
    perror("fork");
}
```

The child inherits a copy of the parent’s memory, file descriptors, environment, and signal handlers. The copy is normally a “copy‑on‑write” optimization – actual duplication of memory pages happens only when one of the processes writes.

### exec() Family – Transforming the Process

`exec()` replaces the current process image with a new program. The new program starts at its `main()` function. There are several variants: `execlp`, `execvp`, `execve`, etc. We’ll use `execvp` because it searches the PATH environment variable automatically.

```c
char *args[] = {"ls", "-la", NULL};
execvp(args[0], args);
// If exec returns, it failed
perror("execvp");
exit(EXIT_FAILURE);
```

Once `exec` succeeds, the calling process is gone; the new program takes over. The only way to run a command in a separate process is to `fork` first, then `exec` in the child.

### wait() and waitpid() – Reaping Zombies

When a child terminates, it becomes a _zombie_ until its parent calls `wait()` or `waitpid()`. The zombie holds a small entry in the kernel’s process table (for exit status). If the parent never waits, the zombie persists. The shell must reap its children to avoid filling the process table.

`waitpid(pid, &status, options)` is more flexible: you can wait for a specific child, or use `WNOHANG` to check without blocking. For a simple shell, we often use `waitpid(-1, &status, WUNTRACED)` to also catch stopped processes (needed for job control).

### File Descriptors and dup2()

Every process has a table of file descriptors (integers). 0 = stdin, 1 = stdout, 2 = stderr. When we redirect `< file`, we want fd 0 to refer to `file`. When we say `> file`, we want fd 1 to refer to `file`. We achieve this by opening the file, then using `dup2(oldfd, newfd)` to duplicate the file descriptor onto the desired number, and closing the original.

```c
int fd = open("output.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
if (fd < 0) { /* error */ }
dup2(fd, STDOUT_FILENO); // now stdout goes to file
close(fd);
```

### Pipes: A Pair of File Descriptors

`pipe(int pipefd[2])` creates a unidirectional data channel. `pipefd[0]` is the read end, `pipefd[1]` is the write end. Data written to `pipefd[1]` can be read from `pipefd[0]`. For a pipeline `cmd1 | cmd2`, we create a pipe before forking, then arrange that `cmd1`’s stdout writes to the pipe and `cmd2`’s stdin reads from it.

## Step 1: The Bare‑Bones Command Loop

Every shell has an infinite loop: print prompt, read line, parse line, execute. Let’s implement the simplest version.

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

#define MAX_LINE 1024

int main(void) {
    char line[MAX_LINE];
    while (1) {
        printf("tinysh$ ");
        fflush(stdout);
        if (!fgets(line, sizeof(line), stdin)) break; // EOF
        line[strcspn(line, "\n")] = 0; // remove trailing newline
        if (strlen(line) == 0) continue;
        // simple execution: split by spaces, fork+exec
        char *args[64];
        int argc = 0;
        char *token = strtok(line, " ");
        while (token && argc < 63) {
            args[argc++] = token;
            token = strtok(NULL, " ");
        }
        args[argc] = NULL;
        if (args[0] == NULL) continue;
        // built-in exit
        if (strcmp(args[0], "exit") == 0) break;
        pid_t pid = fork();
        if (pid == 0) {
            execvp(args[0], args);
            perror("execvp");
            exit(EXIT_FAILURE);
        } else if (pid > 0) {
            int status;
            waitpid(pid, &status, 0);
        } else {
            perror("fork");
        }
    }
    return 0;
}
```

This works! Typing `ls -l` at the prompt will show the directory listing. But it’s painfully limited: no redirection, no pipes, no background. And using `strtok` is naive – it breaks on any whitespace, doesn’t handle quoted strings, and modifies the original line destructively. We’ll improve parsing later.

## Step 2: Adding I/O Redirection

I/O redirection (`>`, `<`, `>>`) is the first superpower. In our shell, we need to parse the command line and detect these operators, open the appropriate files, and use `dup2` in the child process _before_ calling `exec`.

We need a more robust parser. Let’s define a `cmd` structure that holds the program name, arguments, and redirection info.

```c
struct redirect {
    char *file;
    int mode; // 0: <, 1: >, 2: >>
};

struct cmd {
    char **argv;       // argv[0] is the program name
    int argc;
    struct redirect input;
    struct redirect output;
    int input_set, output_set;
};
```

We’ll parse the line by splitting on spaces while respecting redirection tokens. For example, `ls -la > out.txt` should break into `["ls", "-la", ">", "out.txt"]` but then we treat `>` as a special operator.

Here’s a simple tokenizer that handles redirection:

```c
// Note: very simplified; does not handle quotes or escape sequences
char *tokens[128];
int ntokens = 0;
char *token = strtok(line, " ");
while (token) {
    tokens[ntokens++] = token;
    token = strtok(NULL, " ");
}
```

Then we scan the tokens for `<`, `>`, `>>` and fill the `cmd` structure accordingly. The remaining tokens (before any redirection symbols) become the argv.

Execution in the child process:

```c
child_pid = fork();
if (child_pid == 0) {
    // handle input redirection
    if (cmd.input_set) {
        int fd = open(cmd.input.file, O_RDONLY);
        if (fd < 0) { perror("open"); exit(1); }
        dup2(fd, STDIN_FILENO);
        close(fd);
    }
    // handle output redirection
    if (cmd.output_set) {
        int flags = O_WRONLY | O_CREAT;
        if (cmd.output.mode == 1) flags |= O_TRUNC;
        else flags |= O_APPEND;
        int fd = open(cmd.output.file, flags, 0644);
        if (fd < 0) { perror("open"); exit(1); }
        dup2(fd, STDOUT_FILENO);
        close(fd);
    }
    execvp(cmd.argv[0], cmd.argv);
    perror("execvp");
    exit(1);
}
```

Test it: `tinysh$ ls > list.txt` should create a file with the directory listing. `tinysh$ cat < /etc/passwd` should print the password file. Good.

## Step 3: Pipes – The Heart of Unix Philosophy

Pipes are where the shell truly shines. `cmd1 | cmd2 | cmd3` must execute three concurrent processes, each reading from the previous and writing to the next. The shell must orchestrate the pipeline: create pipes, fork each command, connect file descriptors, and wait for all processes.

We need to represent a pipeline as a list of commands. Let’s extend our parser to split on `|`. For simplicity, we’ll assume that redirection operators do not appear next to the pipe symbol (e.g., `cmd1 | cmd2 > file` is fine, but we’ll handle redirection per command).

The high‑level execution algorithm:

1. Parse the line into pipeline segments (e.g., `["ls -la", "grep .txt"]`).
2. For each command in the pipeline, fork a child.
3. For the first command, its stdout should write to the write end of pipe[0].
4. For the last command, its stdin should read from the read end of pipe[n-2].
5. For intermediate commands, stdin from previous pipe’s read end, stdout to next pipe’s write end.
6. Close all pipe ends in the parent.
7. Wait for all children.

Implementation sketch:

```c
int num_commands = ...; // number of pipe segments
int prev_pipe_read = -1;
int i;
for (i = 0; i < num_commands; i++) {
    int pipefd[2];
    if (i < num_commands - 1) {
        if (pipe(pipefd) < 0) { perror("pipe"); exit(1); }
    }
    pid_t pid = fork();
    if (pid == 0) {
        // child
        if (prev_pipe_read != -1) {
            dup2(prev_pipe_read, STDIN_FILENO);
            close(prev_pipe_read);
        }
        if (i < num_commands - 1) {
            dup2(pipefd[1], STDOUT_FILENO);
            close(pipefd[1]);
        }
        // close all pipe fds that child might have inherited
        // (we'll handle this cleanly later)
        // handle redirection for this command (input/output)
        execvp(...);
        exit(1);
    }
    // parent
    if (prev_pipe_read != -1) close(prev_pipe_read);
    if (i < num_commands - 1) close(pipefd[1]); // close write end in parent
    prev_pipe_read = pipefd[0]; // save read end for next iteration
}
// wait for all children
for (i = 0; i < num_commands; i++) {
    wait(NULL); // or collect statuses
}
```

This works, but there’s a subtlety: the parent must close all pipe ends that the children might have inherited. In the loop, we close the write end of the current pipe after that child is forked. The read end is kept open for the next child. After the loop, the parent closes `prev_pipe_read` (the last pipe’s read end). It’s also crucial to close any stray file descriptors in children – a robust shell would iterate through all possible fds up to the max limit and close them, but for simplicity we assume no other fds are open.

Now you can run `tinysh$ ls -la | grep .txt | wc -l` and get the count. The magic of pipes, recreated.

## Step 4: Background Execution and Job Control

Running a command in the background (`command &`) means the shell does not wait for the child to finish; it immediately prints the next prompt. But it must still reap the child eventually. Also, the background job should not receive signals from the terminal (like Ctrl+C). This introduces process groups and signals.

### Process Groups and Sessions

Every process belongs to a process group (a set of processes). The shell puts the foreground job into its own process group and gives it control of the terminal. Background jobs run in separate process groups, and they are not the foreground process group of the terminal.

Key functions:

- `setpgid(pid, pgid)` – sets the process group of a process. Typically we set the child’s group to its own PID.
- `tcsetpgrp(fd, pgrp)` – gives the process group control of the terminal (used for foreground jobs).
- `tcgetpgrp(fd)` – returns the foreground process group of the terminal.

When a background job tries to read from the terminal, it receives `SIGTTIN`. When it tries to write, it may receive `SIGTTOU` (depending on terminal settings). The shell should ignore these signals.

### Implementing &

First, detect trailing `&` in the parsed command. If present, set a `background` flag. Then:

- In the parent, do not call `waitpid` immediately. Instead, record the child’s PID in a job list.
- Print the job number and PID: `[1] 12345`
- Reap children asynchronously. We can install a `SIGCHLD` handler that reaps finished jobs and removes them from the list.

For a minimal version, we can use `waitpid` with `WNOHANG` periodically (e.g., before each prompt) or use a signal handler.

Here’s a skeleton job structure:

```c
struct job {
    int jid;         // job number (1,2,3...)
    pid_t pgid;      // process group ID
    char *command;   // the command line
    int status;      // running, stopped, done
    struct job *next;
};
```

We’ll allocate a job for each pipeline, with the PGID equal to the PID of the first process. All processes in the pipeline should be placed in the same process group.

When a background job finishes, the `SIGCHLD` handler reaps it, marks it as done, and we can remove it from the list before the next prompt.

### Foreground vs. Background

If a command is not backgrounded, it runs in the foreground. The shell must:

- Put the job’s process group into the foreground: `tcsetpgrp(STDIN_FILENO, job->pgid)`.
- Give the terminal back to the shell after the job completes: `tcsetpgrp(STDIN_FILENO, shell_pgid)`.
- Send signals like `SIGINT` (Ctrl+C) only to the foreground job’s process group.

### Handling Ctrl+C and Ctrl+Z

When you press `Ctrl+C`, the terminal sends `SIGINT` to the foreground process group. The shell itself should ignore `SIGINT` so it isn’t killed. When you press `Ctrl+Z`, the terminal sends `SIGTSTP` to the foreground process group, suspending it. The shell must catch `SIGTSTP` (or handle it via `waitpid` with `WUNTRACED`), note that the job is now stopped, and possibly print a message.

To implement: in the main shell process, set signal handlers:

```c
signal(SIGINT, SIG_IGN);
signal(SIGTSTP, SIG_IGN);
```

The shell ignores these signals; they will be delivered to the foreground job (which has its own default handlers – typically terminate for SIGINT, stop for SIGTSTP). The shell uses `waitpid(-1, &status, WUNTRACED)` to catch when a child is stopped.

When a child stops, `WIFSTOPPED(status)` is true. The shell then updates the job status to stopped, prints `[1]+  Stopped   command`, and puts the job in the job list.

The `fg` and `bg` built‑ins resume a stopped job in the foreground or background. `fg` sends `SIGCONT` to the process group and then waits for it; `bg` sends `SIGCONT` and lets it run in the background.

## Step 5: Built‑in Commands

Shells must implement certain commands internally because they affect the shell’s own state (like `cd` changes the working directory, which would not work if run as a child process). Common built‑ins:

- `cd [directory]` – change directory. Use `chdir()`.
- `exit [n]` – exit with optional status.
- `jobs` – list running/stopped jobs.
- `fg [%n]` – bring job n to foreground.
- `bg [%n]` – send job n to background.
- `echo` – print arguments (simple version).
- `kill` – send signal to a job or process.
- `pwd` – print working directory.

In our command parsing, before forking, we check if the command name matches a built‑in. If so, execute it in the shell’s own process and continue the loop without forking.

For `cd`, we must handle the case with no arguments (go to $HOME):

```c
if (strcmp(args[0], "cd") == 0) {
    const char *path = args[1] ? args[1] : getenv("HOME");
    if (chdir(path) != 0) perror("cd");
    continue;
}
```

For `exit`, break out of the loop.

`jobs` iterates over the job list and prints each with its status (Running, Stopped, Done).

`fg` and `bg` require job control infrastructure.

## Step 6: Job Control – The Full Dance

Job control is the most complex part of a shell. Let’s design a simplified but functional system.

### Data Structures

We maintain a linked list of jobs. Each job has a `pid_t pgid`, a `int jid`, a string command, a status (RUNNING, STOPPED, DONE), and a flag for whether it’s foreground or background (though that’s really a property of the shell’s current state).

We also keep a global `struct job *first_job` and a counter for JID allocation.

### Adding a Job

When a pipeline is launched (foreground or background), we assign a JID, set the PGID to the PID of the first process (or we can set it after forking each child using `setpgid` in a loop). All children in the pipeline are placed into the same process group.

In the child, right after `fork()`:

```c
if (pid == 0) {
    // child: set its own process group
    setpgid(0, pgid); // pgid from parent (or use getpid())
}

// parent: set child’s process group (race condition safe approach)
setpgid(pid, pid); // or use same pgid for all
```

To avoid race conditions, the parent and child both call `setpgid` – whichever runs first doesn’t matter because the call is idempotent.

For the first command in a pipeline, we can set `pgid = pid` in the parent. For subsequent commands, we use the same `pgid`.

### Foreground Job Execution

If the job is foreground:

1. `tcsetpgrp(STDIN_FILENO, pgid);` – give terminal to job.
2. Resume the job (if stopped) by sending `SIGCONT` (though it just started, so not needed).
3. Wait for all processes in the pipeline using a loop that calls `waitpid(-1, &status, WUNTRACED)`.
   - For each child termination, update job status.
   - If a child stops (WIFSTOPPED), mark job as STOPPED, add it back to job list (if not already there), and break out of wait loop.
   - If all children exit, mark job as DONE, remove from job list, and give terminal back to shell: `tcsetpgrp(STDIN_FILENO, shell_pgid)`.

### Background Job Execution

If background:

1. Do not give terminal control.
2. Print `[jid] pid` (e.g., `[1] 12345`).
3. Add job to job list with status RUNNING.
4. Do not wait; continue to next prompt.
5. The `SIGCHLD` handler (or a polling check before prompt) will reap finished jobs.

### Signal Handling in the Shell

The shell must catch `SIGCHLD` to reap background jobs. The handler should use `waitpid(-1, &status, WNOHANG | WUNTRACED)` in a loop. It updates the job list. Note: `signal()` is not reentrant safe; in production, you’d use `sigaction`. For our project, `signal` is acceptable.

Also, the shell should ignore `SIGINT` and `SIGTSTP`. But when the shell is waiting for a foreground job, the signals go to the job, not to the shell. The shell only needs to handle the aftermath (via `waitpid`).

### fg and bg Built‑ins

`fg %n`:

- Find job with JID n.
- If it’s stopped, send `SIGCONT` to the process group.
- Set terminal foreground to job’s PGID.
- Wait for job to complete (same wait loop as foreground execution).
- After completion, give terminal back to shell.

`bg %n`:

- Find job with JID n.
- If stopped, send `SIGCONT`.
- Set job status to RUNNING.
- Do not make it foreground.
- Print `[jid] command &` (to indicate it’s now in background).

## Step 7: Parsing – The Achilles’ Heel

So far we’ve used `strtok` which is fragile. A real shell must handle:

- Quoted strings (single and double quotes)
- Escape sequences (backslash)
- Variable expansion (`$HOME`, `$PATH`)
- Command substitution (backticks or `$(...)`)
- Globbing (wildcards `*.txt`)
- Environment variables

Implementing a full parser is a significant undertaking. For our mini‑shell, I’ll outline how to support quotes and basic variable expansion.

### Tokenizer with Quoting

We read the line character by character. We maintain a simple state machine: normal, inside single quotes (no escape), inside double quotes (allow some escapes).

Pseudo‑code:

```c
int i = 0;
char current_token[1024];
int tok_len = 0;
int state = NORMAL;

while (line[i]) {
    switch (state) {
        case NORMAL:
            if (line[i] == '\'') state = IN_SINGLE_QUOTE;
            else if (line[i] == '"') state = IN_DOUBLE_QUOTE;
            else if (line[i] == '\\') { /* backslash escape */ }
            else if (line[i] == ' ') {
                if (tok_len > 0) { add_token(current_token); tok_len=0; }
            } else {
                current_token[tok_len++] = line[i];
            }
            break;
        case IN_SINGLE_QUOTE:
            if (line[i] == '\'') state = NORMAL;
            else current_token[tok_len++] = line[i];
            break;
        case IN_DOUBLE_QUOTE:
            // handle escape and variable expansion inside double quotes
            break;
    }
    i++;
}
```

This is manageable. Variable expansion would require looking up environment variables when we encounter `$`. We can implement a simple `expand_variables` function that replaces `$VAR` with the value.

Globbing: we can defer to the shell expansion after parsing, using `glob()` from `<glob.h>`. That’s a good exercise.

## Step 8: Handling Signals and Terminal Properly

We’ve touched on signals, but let’s formalize the terminal management.

### Initializing the Shell

When the shell starts, it should:

- Get its own process group ID: `shell_pgid = getpgrp()`.
- Set the shell process group as the foreground process group of the terminal: `tcsetpgrp(STDIN_FILENO, shell_pgid)`.
- Set signal handlers: ignore `SIGINT`, `SIGQUIT`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU` in the shell.
- Optionally put the terminal in raw mode for line editing (but that’s advanced; we can stay with canonical input).

### While Waiting for Foreground Job

When waiting for a foreground job, the shell is in `waitpid()` and is not in a signal‑sensitive state because it’s blocking. Signals go to the child process group. After the child finishes, the shell restores terminal ownership.

Important: if the shell is reading from stdin (waiting for input), and a background job tries to read from the terminal, the background job gets `SIGTTIN`. That’s fine; it just stops. The user can foreground it with `fg`.

### Orphan Process Groups

Care must be taken that all processes in a pipeline are placed in their own process group before the shell continues. Otherwise, a child might be killed by a signal meant for another group. Using `setpgid` in both parent and child (as shown earlier) handles the race.

## Step 9: Testing Your Shell

A shell is a tricky beast to test. Here are some strategies:

- **Unit tests**: test parsing functions (tokenizer, command extraction) with known inputs.
- **Integration tests**: write a script that runs your shell with a series of commands and compares output to expected.
- **Manual testing**: try edge cases: empty commands, trailing spaces, multiple pipes, redirection with pipes, background + redirection, `cd` with special paths, `SIGINT` while a child is running, etc.
- **Stress testing**: run long‑running commands, many pipeline stages, concurrent background jobs.

Use the `strace` tool to see which system calls your shell makes. It’s an excellent debugging aid.

## Step 10: Advanced Topics – The Escalation

Once you have the basics, you can extend your shell with:

### Command History

Store the last N commands in a circular buffer. Allow recall with arrow keys (requires raw terminal mode and termios manipulation). A simpler version: just print history with `history` built‑in.

### Completion

Tab completion: listen for tab character, iterate over files in PATH or current directory. This is complex but satisfying.

### Scripting Support

Execute a file of commands line by line, with control structures (if, while). This turns your shell into a mini‑script interpreter.

### Redirection to/from File Descriptors

Bash style: `command 2>&1` or `command 3>file`. This requires parsing numeric file descriptors before redirection operators.

### Setuid and Security

Handle setuid bits correctly. Avoid shell injection vulnerabilities: when using `system()` or constructing arguments manually, always escape.

### Unicode and Multibyte Characters

Terminals now handle UTF‑8. Your parser should be 8‑bit clean and not break on multibyte sequences.

## Conclusion: The Shell That Whispers Back

We’ve built a tiny but functional Unix shell. Along the way, we’ve touched on `fork`, `exec`, `wait`, `dup2`, `pipe`, process groups, signals, job control, and parsing. These are not just academic exercises – they are the building blocks of nearly every operating system service, from web servers to database daemons.

The next time you type a command into bash, you’ll appreciate the machinery behind it. You’ll understand why `Ctrl+C` kills your program but not the shell itself. You’ll know why background jobs get stopped when they try to read from the terminal. And you’ll have the confidence to dive into the source code of bash or dash, because you’ve already walked the same path.

Building your own shell is a rite of passage in systems programming. It’s a project that you’ll never forget, because it forces you to think like the kernel. And in the process, you’ll discover that the shell isn’t a black box at all – it’s a beautifully transparent interface, whispering to the kernel on your behalf.

Now go fork some processes. The terminal is waiting.
