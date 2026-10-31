// SPDX-License-Identifier: GPL-3.0-or-later
// The app's executable: run the mirror script in the app's Resources as a child
// and exit with its code. macOS holds the app responsible for the child and its
// descendants, so they use the app's permissions. It must stay a child: an exec
// would make it plain bash, and a stop signal must reach the script (ADR 0007).

#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static pid_t child;

static void forward(int sig) {
    if (child > 0)
        kill(child, sig);
}

int main(int argc, char **argv) {
    char executable[PATH_MAX], resolved[PATH_MAX], script[PATH_MAX + 64];
    uint32_t size = sizeof executable;
    int status;

    if (_NSGetExecutablePath(executable, &size) != 0 ||
        realpath(executable, resolved) == NULL) {
        perror("executable path");
        return 70;
    }
    // Contents/MacOS/<name> to Contents/Resources/.
    snprintf(script, sizeof script, "%s/../Resources/osxphotos-nas-mirror.sh",
             dirname(resolved));
    argv[0] = script;
    (void)argc;

    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);
    errno = posix_spawn(&child, script, NULL, NULL, argv, environ);
    if (errno != 0) {
        perror(script);
        return 70;
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            perror("waitpid");
            return 70;
        }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
