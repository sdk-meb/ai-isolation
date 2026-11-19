/*
 * aisup.c — a tiny seccomp "exec supervisor" for ai-sandbox.sh
 *
 *   aisup <policy-file> </absolute/command> [args...]
 *
 * How it works
 *   1. fork()
 *   2. child:  no_new_privs + a seccomp filter that
 *                - PAUSES execve/execveat and hands them to us (SCMP_ACT_NOTIFY)
 *                - refuses ioctl(TIOCSTI) (faking keystrokes into your terminal)
 *              sends the notification fd to the parent, then exec()s the
 *              command (normally: bwrap ... <ai tool>). Every process inside
 *              the sandbox inherits the filter and cannot remove it.
 *   3. parent: stays OUTSIDE the sandbox, receives every exec attempt, checks
 *              it against the policy file (allow / deny / ask) and answers.
 *
 * Safety notes
 *   - If this supervisor dies, the child gets SIGKILL (PR_SET_PDEATHSIG) and
 *     any paused exec fails with ENOSYS: it fails CLOSED.
 *   - Path and args are read from the paused process's memory. Another thread
 *     could change that memory after we read it (TOCTOU). We re-check the
 *     notification id (SECCOMP_IOCTL_NOTIF_ID_VALID) before answering, which
 *     narrows but does not close that gap. Exec approval is a guard rail;
 *     bubblewrap is the wall.
 *
 * Build:  make        (needs: sudo apt install libseccomp-dev)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <poll.h>
#include <seccomp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef SECCOMP_USER_NOTIF_FLAG_CONTINUE
#define SECCOMP_USER_NOTIF_FLAG_CONTINUE (1UL << 0)
#endif

#define CMD_MAX   4096      /* longest command line we match / show */
#define MAX_ARGS  64        /* how many argv entries we read        */
#define MAX_RULES 512

/* ------------------------------------------------------------------ policy */

enum action { ALLOW, DENY, ASK };

struct rule { enum action act; char pattern[1024]; };

static struct rule rules[MAX_RULES];
static int         nrules;
static enum action default_action = ASK;
static FILE       *logfp;
static char        tool_name[128] = "The AI tool";   /* $AISUP_NAME, shown in the dialog */

static int parse_action(const char *w, enum action *out)
{
    if (strcmp(w, "allow") == 0) { *out = ALLOW; return 0; }
    if (strcmp(w, "deny")  == 0) { *out = DENY;  return 0; }
    if (strcmp(w, "ask")   == 0) { *out = ASK;   return 0; }
    return -1;
}

/* File format (see policy.conf):  <allow|deny|ask> <glob>   or   default <action>
 * The glob is matched against "/abs/path arg1 arg2 ...". First match wins. */
static void load_policy(const char *file)
{
    FILE *f = fopen(file, "r");
    if (!f) { perror(file); exit(1); }

    char line[CMD_MAX];
    int lineno = 0;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        line[strcspn(line, "\r\n")] = '\0';

        char *p = line + strspn(line, " \t");        /* skip indentation   */
        if (*p == '\0' || *p == '#') continue;         /* blank / comment    */

        char *word = p;                                /* first word         */
        p += strcspn(p, " \t");
        if (*p) *p++ = '\0';
        p += strspn(p, " \t");                         /* rest = pattern     */

        enum action act;
        if (strcmp(word, "default") == 0) {
            if (parse_action(p, &default_action) < 0) goto bad;
            continue;
        }
        if (parse_action(word, &act) < 0 || *p == '\0' || nrules == MAX_RULES) goto bad;
        rules[nrules].act = act;
        snprintf(rules[nrules].pattern, sizeof rules[nrules].pattern, "%s", p);
        nrules++;
        continue;
    bad:
        fprintf(stderr, "aisup: %s:%d: bad policy line\n", file, lineno);
        exit(1);
    }
    fclose(f);
}

static enum action decide(const char *cmd)
{
    for (int i = 0; i < nrules; i++)
        if (fnmatch(rules[i].pattern, cmd, 0) == 0)   /* '*' also matches '/' */
            return rules[i].act;
    return default_action;
}

/* ------------------------------------------------- reading the paused process */

/* Read a NUL-terminated string from another process's memory, page by page
 * (so a string that ends right before an unmapped page still works). */
static int read_string(int mem, unsigned long addr, char *out, size_t size)
{
    size_t got = 0;
    while (got < size - 1) {
        size_t chunk = 4096 - ((addr + got) % 4096);
        if (chunk > size - 1 - got) chunk = size - 1 - got;
        ssize_t n = pread(mem, out + got, chunk, (off_t)(addr + got));
        if (n <= 0) return -1;
        if (memchr(out + got, '\0', (size_t)n)) return 0;
        got += (size_t)n;
    }
    out[size - 1] = '\0';                              /* too long: truncate */
    return 0;
}

static int read_pointer(int mem, unsigned long addr, unsigned long *out)
{
    return pread(mem, out, sizeof *out, (off_t)addr) == (ssize_t)sizeof *out ? 0 : -1;
}

static void append(char *dst, size_t size, const char *s)
{
    size_t len = strlen(dst);
    if (len + 1 < size) snprintf(dst + len, size - len, "%s", s);
}

/* Turn a paused execve/execveat into  path="/abs/path"  cmd="/abs/path a1 a2 ..."
 * (paths as seen INSIDE the sandbox). Returns -1 if memory can't be read. */
static int describe(const struct seccomp_notif *req,
                    char *path, size_t psize, char *cmd, size_t csize)
{
    char proc[64], raw[PATH_MAX], base[PATH_MAX];
    unsigned long path_ptr, argv_ptr;
    int dirfd = AT_FDCWD, flags = 0, ret = -1;

    if (req->data.nr == __NR_execveat) {      /* execveat(dirfd, path, argv, envp, flags) */
        dirfd    = (int)req->data.args[0];
        path_ptr = req->data.args[1];
        argv_ptr = req->data.args[2];
        flags    = (int)req->data.args[4];
    } else {                                  /* execve(path, argv, envp) */
        path_ptr = req->data.args[0];
        argv_ptr = req->data.args[1];
    }

    snprintf(proc, sizeof proc, "/proc/%u/mem", req->pid);
    int mem = open(proc, O_RDONLY | O_CLOEXEC);
    if (mem < 0) return -1;
    if (read_string(mem, path_ptr, raw, sizeof raw) < 0) goto out;

    /* Relative path -> prefix with the process's cwd (or the dirfd's path).
     * A path that doesn't fit is an error (-> deny), never truncated: a cut
     * path could match a policy rule for a different program. */
    int len;
    if (raw[0] == '/') {
        len = snprintf(path, psize, "%s", raw);
    } else {
        if (dirfd == AT_FDCWD) snprintf(proc, sizeof proc, "/proc/%u/cwd", req->pid);
        else                   snprintf(proc, sizeof proc, "/proc/%u/fd/%d", req->pid, dirfd);
        ssize_t n = readlink(proc, base, sizeof base - 1);
        if (n < 0) goto out;
        base[n] = '\0';
        if (raw[0] == '\0' && (flags & AT_EMPTY_PATH)) len = snprintf(path, psize, "%s", base);
        else                                           len = snprintf(path, psize, "%s/%s", base, raw);
    }
    if (len < 0 || (size_t)len >= psize) goto out;

    /* Command line = resolved path + argv[1..] (argv[0] can be anything). */
    snprintf(cmd, csize, "%s", path);
    for (int i = 1; i < MAX_ARGS; i++) {
        unsigned long arg_ptr;
        char arg[1024];
        if (read_pointer(mem, argv_ptr + i * sizeof(unsigned long), &arg_ptr) < 0 || arg_ptr == 0)
            break;
        if (read_string(mem, arg_ptr, arg, sizeof arg) < 0) break;
        append(cmd, csize, " ");
        append(cmd, csize, arg);
    }
    ret = 0;
out:
    close(mem);
    return ret;
}

/* ---------------------------------------------------------------- deciding */

/* Desktop dialog via zenity. No display / no zenity / 60 s timeout = deny.
 * (One dialog at a time: other execs wait until you answer.) */
static int ask_user(const char *cmd)
{
    if (!getenv("WAYLAND_DISPLAY") && !getenv("DISPLAY")) return 0;

    char text[CMD_MAX + sizeof tool_name + 32];
    snprintf(text, sizeof text, "%s wants to run:\n\n%s", tool_name, cmd);

    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        int null = open("/dev/null", O_RDWR);          /* keep the TUI clean */
        if (null >= 0) { dup2(null, 0); dup2(null, 1); dup2(null, 2); }
        execlp("zenity", "zenity", "--question", "--no-markup",
               "--title=AI sandbox: allow command?",
               "--ok-label=Allow", "--cancel-label=Deny",
               "--timeout=60", "--width=600", "--text", text, (char *)NULL);
        _exit(127);
    }
    int status;
    if (waitpid(pid, &status, 0) != pid) return 0;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;   /* 0 = Allow */
}

static void log_line(const char *verdict, unsigned pid, const char *cmd)
{
    if (!logfp) return;
    char ts[32];
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(logfp, "%s pid=%u %-5s %s\n", ts, pid, verdict, cmd);
}

static void handle(int nfd, struct seccomp_notif *req, struct seccomp_notif_resp *resp)
{
    static char path[PATH_MAX], cmd[CMD_MAX], inroot[PATH_MAX + 64];
    const char *verdict = "deny";
    int allow = 0, err = EPERM;

    if (describe(req, path, sizeof path, cmd, sizeof cmd) < 0) {
        snprintf(cmd, sizeof cmd, "(could not read exec arguments)");
        goto reply;                                    /* unknown = deny */
    }

    /* Is the syscall still waiting? (process may have died / id reused) */
    if (seccomp_notify_id_valid(nfd, req->id) != 0) return;

    /* Exec of a file that doesn't exist (execvp trying each $PATH dir): the
     * kernel would fail it anyway -> fail it quietly, no prompt, no log. */
    snprintf(inroot, sizeof inroot, "/proc/%u/root%s", req->pid, path);
    if (path[0] == '/' && access(inroot, F_OK) < 0 && errno == ENOENT) {
        err = ENOENT;
        verdict = NULL;
        goto reply;
    }

    switch (decide(cmd)) {
    case ALLOW: allow = 1; verdict = "allow"; break;
    case DENY:             verdict = "deny";  break;
    case ASK:
        allow   = ask_user(cmd);
        verdict = allow ? "ALLOW" : "DENY";           /* upper case = you decided */
        /* the dialog may have taken a while: check again before answering */
        if (seccomp_notify_id_valid(nfd, req->id) != 0) { log_line("gone", req->pid, cmd); return; }
        break;
    }

reply:
    if (verdict) log_line(verdict, req->pid, cmd);
    memset(resp, 0, sizeof *resp);
    resp->id = req->id;
    if (allow) resp->flags = SECCOMP_USER_NOTIF_FLAG_CONTINUE;  /* run the real execve */
    else       resp->error = -err;                               /* execve returns -1 */
    seccomp_notify_respond(nfd, resp);   /* fails harmlessly if the process is gone */
}

/* ---------------------------------------------- passing the fd parent<-child */

static void send_fd(int sock, int fd)
{
    char dummy = 'x';
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } u;
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1,
                          .msg_control = u.buf, .msg_controllen = sizeof u.buf };
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type  = SCM_RIGHTS;
    c->cmsg_len   = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof fd);
    if (sendmsg(sock, &msg, 0) < 0) { perror("aisup: sendmsg"); _exit(1); }
}

static int recv_fd(int sock)
{
    char dummy;
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } u;
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1,
                          .msg_control = u.buf, .msg_controllen = sizeof u.buf };
    if (recvmsg(sock, &msg, 0) <= 0) return -1;
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    if (!c || c->cmsg_type != SCM_RIGHTS) return -1;
    int fd;
    memcpy(&fd, CMSG_DATA(c), sizeof fd);
    return fd;
}

static int exit_code(int status)
{
    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}

/* -------------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    if (argc < 3 || argv[2][0] != '/') {
        fprintf(stderr, "usage: aisup <policy-file> </absolute/command> [args...]\n");
        return 2;
    }
    load_policy(argv[1]);

    /* Tool name for the dialog; removed so the sandboxed tool doesn't inherit it. */
    const char *name = getenv("AISUP_NAME");
    if (name && *name) snprintf(tool_name, sizeof tool_name, "%s", name);
    unsetenv("AISUP_NAME");

    /* Log file: $AISUP_LOG or ~/.local/state/aisup.log (stderr belongs to the TUI). */
    char deflog[PATH_MAX];
    const char *logpath = getenv("AISUP_LOG");
    if (!logpath) {
        const char *home = getenv("HOME");
        snprintf(deflog, sizeof deflog, "%s/.local/state/aisup.log", home ? home : "/tmp");
        logpath = deflog;
    }
    logfp = fopen(logpath, "a");
    if (logfp) setvbuf(logfp, NULL, _IOLBF, 0);

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) < 0) { perror("socketpair"); return 1; }

    pid_t parent = getpid();
    pid_t child  = fork();
    if (child < 0) { perror("fork"); return 1; }

    if (child == 0) {
        /* ---------------- child: lock itself down, then become the sandbox */
        close(sv[0]);
        if (logfp) fclose(logfp);
        prctl(PR_SET_PDEATHSIG, SIGKILL);               /* supervisor gone -> we die */
        if (getppid() != parent) _exit(1);              /* ...it died already        */

        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) { perror("no_new_privs"); _exit(1); }

        scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);   /* everything else: allowed */
        if (!ctx
            || seccomp_rule_add(ctx, SCMP_ACT_NOTIFY, SCMP_SYS(execve), 0) < 0
            || seccomp_rule_add(ctx, SCMP_ACT_NOTIFY, SCMP_SYS(execveat), 0) < 0
            || seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(ioctl), 1,
                                SCMP_A1(SCMP_CMP_MASKED_EQ, 0xFFFFFFFFul, TIOCSTI)) < 0
            || seccomp_load(ctx) < 0) {
            fprintf(stderr, "aisup: could not install the seccomp filter\n");
            _exit(1);
        }
        int nfd = seccomp_notify_fd(ctx);
        if (nfd < 0) { fprintf(stderr, "aisup: no notification fd\n"); _exit(1); }
        send_fd(sv[1], nfd);
        close(nfd);
        close(sv[1]);
        seccomp_release(ctx);

        execv(argv[2], argv + 2);       /* this exec is itself paused until the parent answers */
        perror(argv[2]);
        _exit(127);
    }

    /* ---------------- parent: the supervisor (outside the sandbox) */
    close(sv[1]);
    int nfd = recv_fd(sv[0]);
    close(sv[0]);
    if (nfd < 0) {
        fprintf(stderr, "aisup: did not receive the notification fd\n");
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        return 1;
    }

    /* Ctrl-C / Ctrl-\ are for the tool, not for us (killing us kills the sandbox). */
    signal(SIGINT,  SIG_IGN);
    signal(SIGQUIT, SIG_IGN);

    struct seccomp_notif      *req;
    struct seccomp_notif_resp *resp;
    if (seccomp_notify_alloc(&req, &resp) < 0) { kill(child, SIGKILL); return 1; }

    for (;;) {
        struct pollfd pfd = { .fd = nfd, .events = POLLIN };
        int r = poll(&pfd, 1, 1000);
        if (r < 0 && errno != EINTR) break;

        if (r > 0 && (pfd.revents & POLLIN)) {
            memset(req, 0, sizeof *req);                 /* kernel wants it zeroed */
            if (seccomp_notify_receive(nfd, req) == 0)
                handle(nfd, req, resp);
            continue;
        }
        if (r > 0 && (pfd.revents & (POLLHUP | POLLERR)))
            break;                                       /* no sandboxed process left */

        /* idle: has the sandbox exited? */
        int st;
        if (waitpid(child, &st, WNOHANG) == child) return exit_code(st);
    }

    int st = 0;
    waitpid(child, &st, 0);
    return exit_code(st);
}
