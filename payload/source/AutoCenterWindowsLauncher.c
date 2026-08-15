#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

int main(void) {
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        const struct passwd *account = getpwuid(getuid());
        home = account != NULL ? account->pw_dir : NULL;
    }

    if (home == NULL || home[0] == '\0') {
        fputs("Auto Center Windows could not locate the current user folder.\n", stderr);
        return EXIT_FAILURE;
    }

    char executable[PATH_MAX];
    const int length = snprintf(
        executable,
        sizeof(executable),
        "%s/Applications/Auto Center Windows.app/Contents/MacOS/AutoCenterWindows",
        home
    );
    if (length < 0 || (size_t)length >= sizeof(executable)) {
        fputs("The Auto Center Windows executable path is too long.\n", stderr);
        return EXIT_FAILURE;
    }

    char *const arguments[] = { executable, NULL };
    execv(executable, arguments);
    fprintf(stderr, "Auto Center Windows could not start: %s\n", strerror(errno));
    return 127;
}
