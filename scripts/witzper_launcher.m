// Native launcher so Activity Monitor's "Process Name" column reads
// "Witzper" instead of "Python".
//
// Key trick: we can't execv() into python — the kernel resets p_comm to
// the exec'd binary basename ("python"). Instead we dlopen libpython and
// call Py_BytesMain() inside this process so the running image stays
// "Witzper". p_comm is derived from this binary's basename, which is
// exactly what we want.
//
// Build:
//   clang -fobjc-arc -o Witzper scripts/witzper_launcher.m \
//       -framework Foundation
//
// Place the resulting "Witzper" binary anywhere; at runtime it locates
// the repo (by walking up until it finds pyproject.toml) and loads
// .venv/lib/libpython3.*.dylib from there.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach-o/dyld.h>

typedef int (*Py_BytesMain_t)(int argc, char **argv);

static NSString *findRepoRoot(void) {
    char exePath[4096];
    uint32_t size = sizeof(exePath);
    if (_NSGetExecutablePath(exePath, &size) != 0) return nil;
    NSString *p = [[NSString stringWithUTF8String:exePath]
                   stringByStandardizingPath];
    p = [p stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    while (![fm fileExistsAtPath:
             [p stringByAppendingPathComponent:@"pyproject.toml"]]) {
        NSString *parent = [p stringByDeletingLastPathComponent];
        if ([parent isEqualToString:p]) return nil;
        p = parent;
    }
    return p;
}

static NSString *findLibPython(NSString *repo) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Search .venv for a libpython*.dylib (exposed via framework symlink).
    NSArray *candidates = @[
        @".venv/lib/libpython3.13.dylib",
        @".venv/lib/libpython3.12.dylib",
        @".venv/lib/libpython3.11.dylib",
    ];
    for (NSString *rel in candidates) {
        NSString *full = [repo stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:full]) return full;
    }
    // Fall back to the framework libpython the venv points to. Resolve
    // the venv python symlink chain → .../Python.framework/.../Python
    NSString *venvPy = [repo stringByAppendingPathComponent:@".venv/bin/python3"];
    NSError *err = nil;
    NSString *resolved = [fm destinationOfSymbolicLinkAtPath:venvPy error:&err];
    while (resolved) {
        if (![resolved hasPrefix:@"/"]) {
            resolved = [[venvPy stringByDeletingLastPathComponent]
                        stringByAppendingPathComponent:resolved];
        }
        resolved = [resolved stringByStandardizingPath];
        NSString *next = [fm destinationOfSymbolicLinkAtPath:resolved error:&err];
        if (!next) break;
        venvPy = resolved;
        resolved = next;
    }
    // resolved now points to a real Python binary inside the framework.
    // Its sibling Python.framework/Versions/3.XX/Python is the dylib.
    NSString *frameworkDir = resolved;
    while (frameworkDir && ![[frameworkDir lastPathComponent]
                             isEqualToString:@"Python.framework"]) {
        NSString *parent = [frameworkDir stringByDeletingLastPathComponent];
        if ([parent isEqualToString:frameworkDir]) { frameworkDir = nil; break; }
        frameworkDir = parent;
    }
    if (frameworkDir) {
        // Walk into Versions/<v>/Python
        NSString *versions = [frameworkDir stringByAppendingPathComponent:@"Versions"];
        NSArray *entries = [fm contentsOfDirectoryAtPath:versions error:nil];
        for (NSString *v in entries) {
            if ([v isEqualToString:@"Current"]) continue;
            NSString *dylib = [[versions stringByAppendingPathComponent:v]
                               stringByAppendingPathComponent:@"Python"];
            if ([fm fileExistsAtPath:dylib]) return dylib;
        }
    }
    return nil;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *repo = findRepoRoot();
        if (!repo) {
            fprintf(stderr, "Witzper: cannot find repo (pyproject.toml)\n");
            return 1;
        }
        chdir(repo.UTF8String);

        NSString *libpath = findLibPython(repo);
        if (!libpath) {
            fprintf(stderr, "Witzper: cannot locate libpython in %s/.venv\n",
                    repo.UTF8String);
            return 1;
        }

        void *h = dlopen(libpath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!h) {
            fprintf(stderr, "Witzper: dlopen(%s) failed: %s\n",
                    libpath.UTF8String, dlerror());
            return 1;
        }
        Py_BytesMain_t py_bytes_main =
            (Py_BytesMain_t)dlsym(h, "Py_BytesMain");
        if (!py_bytes_main) {
            fprintf(stderr, "Witzper: Py_BytesMain not found: %s\n", dlerror());
            return 1;
        }

        // Point Python at our venv so site-packages resolves correctly.
        NSString *venv = [repo stringByAppendingPathComponent:@".venv"];
        setenv("VIRTUAL_ENV", venv.UTF8String, 1);
        NSString *venvBin = [venv stringByAppendingPathComponent:@"bin"];
        const char *oldPath = getenv("PATH");
        NSString *newPath = [NSString stringWithFormat:@"%@:%s",
                             venvBin, oldPath ? oldPath : "/usr/bin:/bin"];
        setenv("PATH", newPath.UTF8String, 1);
        // Force Python to treat the venv python as its executable so
        // sys.prefix / site-packages resolution lands on the venv.
        NSString *venvPython = [venvBin stringByAppendingPathComponent:@"python"];
        setenv("PYTHONEXECUTABLE", venvPython.UTF8String, 1);

        // Build new argv: [self, -m, flow, run, ...passthrough]
        int newArgc = argc + 3;
        char **newArgv = (char **)calloc(newArgc + 1, sizeof(char *));
        newArgv[0] = strdup("Witzper");
        newArgv[1] = strdup("-m");
        newArgv[2] = strdup("flow");
        newArgv[3] = strdup("run");
        for (int i = 1; i < argc; i++) newArgv[3 + i] = strdup(argv[i]);
        newArgv[newArgc] = NULL;

        return py_bytes_main(newArgc, newArgv);
    }
}
