/*
 * sleep-unified-gui — launcher for "sleep-unified --gui"
 *
 * Version: 1.1
 *
 * Copyright (C) 2025-2026 Maksym Nazar.
 * Created with the assistance of Claude, ChatGPT, and Perplexity.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * ----------------------------------------------------------------------
 * What this is:
 *   A tiny launcher: it does nothing but exec "sleep-unified --gui" from
 *   the same directory this binary itself lives in. This exists purely
 *   for convenience — for menu entries, desktop launchers, or double-click
 *   use, where passing "--gui" as an argument to sleep-unified directly
 *   isn't always straightforward, but launching a separate binary with no
 *   arguments is. There is no logic of its own beyond locating and
 *   exec'ing sleep-unified; the GUI itself is entirely implemented in
 *   sleep-unified.c/sleep-unified.
 *
 *   sleep-unified must be present in the same directory as this binary —
 *   it is located via /proc/self/exe (this binary's own path), not via
 *   $PATH, so it works correctly regardless of how sleep-unified-gui
 *   itself was invoked (double-click, absolute path, relative path,
 *   symlink, etc.).
 * ----------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libgen.h>

#define PATH_BUFFER 1024

int main(void) {
    char exe_path[PATH_BUFFER];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (len <= 0) {
        fprintf(stderr, "sleep-unified-gui: could not determine my own path (/proc/self/exe).\n");
        return 1;
    }
    exe_path[len] = '\0';

    char exe_path_copy[PATH_BUFFER];
    strncpy(exe_path_copy, exe_path, sizeof(exe_path_copy) - 1);
    exe_path_copy[sizeof(exe_path_copy) - 1] = '\0';
    char *dir = dirname(exe_path_copy);

    char target_path[PATH_BUFFER];
    snprintf(target_path, sizeof(target_path), "%s/sleep-unified", dir);

    if (access(target_path, X_OK) != 0) {
        fprintf(stderr, "sleep-unified-gui: could not find or execute %s "
                        "(expected sleep-unified in the same directory as sleep-unified-gui).\n",
                        target_path);
        return 1;
    }

    execl(target_path, "sleep-unified", "--gui", (char *)NULL);

    /* execl only returns on failure. */
    fprintf(stderr, "sleep-unified-gui: failed to execute %s.\n", target_path);
    return 1;
}
