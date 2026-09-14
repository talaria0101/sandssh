/* fakepwd.c — synthetic passwd database for cages with no /etc/passwd.
 *
 * LD_PRELOAD into any dynamically linked program (ssh, ssh-keygen, curl's
 * tools, ...) that calls getpwuid/getpwnam and aborts on failure.
 *
 * User database source, in order:
 *   1. $SANDSSH_PASSWD file (standard passwd(5) format, one user per line)
 *   2. /etc/sandssh/passwd
 *   3. built-in default: root with uid/gid 0, home /root, shell /bin/bash
 *
 * Build: gcc -shared -fPIC -O2 -o fakepwd.so fakepwd.c
 * Use:   LD_PRELOAD=./fakepwd.so ssh user@host
 */
#define _GNU_SOURCE
#include <pwd.h>
#include <shadow.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/types.h>

#define MAXU 32
#define LNLEN 1024
static struct passwd users[MAXU];
static char lines[MAXU][LNLEN];      /* field pointers refer into these */
static struct spwd shadow_root;
static int nusers = -1;

static void load(void) {
    if (nusers >= 0) return;
    nusers = 0;
    const char *path = getenv("SANDSSH_PASSWD");
    if (!path) path = "/etc/sandssh/passwd";
    FILE *f = fopen(path, "r");
    if (f) {
        while (fgets(lines[nusers], LNLEN, f) && nusers < MAXU) {
            char *ln = lines[nusers];
            char *nl = strchr(ln, '\n'); if (nl) *nl = 0;
            char *fields[7]; int k = 0;
            char *tok = strtok(ln, ":");
            while (tok && k < 7) { fields[k++] = tok; tok = strtok(NULL, ":"); }
            if (k < 7) continue;
            struct passwd *u = &users[nusers++];
            u->pw_name = fields[0]; u->pw_passwd = fields[1];
            u->pw_uid = (uid_t)atoi(fields[2]); u->pw_gid = (gid_t)atoi(fields[3]);
            u->pw_gecos = fields[4]; u->pw_dir = fields[5]; u->pw_shell = fields[6];
        }
        fclose(f);
    }
    if (nusers == 0) {
        users[0].pw_name = "root"; users[0].pw_passwd = "x";
        users[0].pw_uid = 0; users[0].pw_gid = 0;
        users[0].pw_gecos = "root"; users[0].pw_dir = "/root";
        users[0].pw_shell = "/bin/bash";
        nusers = 1;
    }
    memset(&shadow_root, 0, sizeof(shadow_root));
    shadow_root.sp_namp = users[0].pw_name;
    shadow_root.sp_pwdp = "*";          /* no valid password: pubkey only */
    shadow_root.sp_lstchg = -1; shadow_root.sp_min = -1; shadow_root.sp_max = -1;
    shadow_root.sp_warn = -1; shadow_root.sp_inact = -1; shadow_root.sp_expire = -1;
}

static struct passwd *find_by_name(const char *n) {
    load();
    for (int i = 0; i < nusers; i++)
        if (strcmp(users[i].pw_name, n) == 0) return &users[i];
    return NULL;
}
static struct passwd *find_by_uid(uid_t uid) {
    load();
    for (int i = 0; i < nusers; i++)
        if (users[i].pw_uid == uid) return &users[i];
    return NULL;
}

struct passwd *getpwuid(uid_t uid) { return find_by_uid(uid); }
struct passwd *getpwnam(const char *n) { return n ? find_by_name(n) : NULL; }

int getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t len, struct passwd **res) {
    struct passwd *m = find_by_uid(uid);
    if (!m) { *res = NULL; return 0; }
    *pw = *m; *res = pw; return 0;
}
int getpwnam_r(const char *n, struct passwd *pw, char *buf, size_t len, struct passwd **res) {
    struct passwd *m = n ? find_by_name(n) : NULL;
    if (!m) { *res = NULL; return 0; }
    *pw = *m; *res = pw; return 0;
}
struct spwd *getspnam(const char *n) {
    load();
    return (n && strcmp(n, users[0].pw_name) == 0) ? &shadow_root : NULL;
}
int getspnam_r(const char *n, struct spwd *sp, char *buf, size_t len, struct spwd **res) {
    struct spwd *m = getspnam(n);
    if (!m) { *res = NULL; return 0; }
    *sp = *m; *res = sp; return 0;
}
void setpwent(void) {}
void endpwent(void) {}
struct passwd *getpwent(void) { return NULL; }
