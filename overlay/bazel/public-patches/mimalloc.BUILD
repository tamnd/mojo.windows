# Build file for the mimalloc source archive, used for the Windows target only.
#
# There is a mimalloc module in the Bazel Central Registry and this deliberately
# does not use it. That module is built around the malloc override use case: its
# top level target on Windows resolves to a shared library plus the prebuilt
# mimalloc-redirect.dll, which patches the CRT's malloc at load time so that
# every allocation in the process goes through mimalloc. That is a fine thing to
# want and it is not what is wanted here.
#
# What is wanted here is the same shape as the tcmalloc target this replaces,
# which is tcmalloc_internal_methods_only_numa_aware: a static library that
# exports its own named allocation functions and overrides nothing. The three
# callers in AsyncRT ask for memory by name, through TCMallocGlobals, and the
# rest of the process is expected to keep using the CRT allocator. Overriding
# malloc globally would change the behaviour of every library linked into the
# compiler, on a platform where nothing else has been tested yet, in exchange
# for nothing this tree asks for.
#
# So this builds mimalloc the way its own CMake calls a static build. The two
# defines below are the whole configuration:
#
#   MI_STATIC_LIB     no dllimport or dllexport on the public API.
#   no MI_MALLOC_OVERRIDE   src/alloc-override.c compiles to nothing, and the
#                           block in src/prim/windows/prim.c that talks to
#                           mimalloc-redirect.dll is under MI_SHARED_LIB and so
#                           never comes in either.
#
# Fetching the source and writing the build file, rather than taking the module
# and patching it, is the same thing this tree already does for gperftools on
# macOS. It is also easier to live with: a build file is code we can read and
# edit, and a patch against someone else's build file has to be regenerated
# every time they touch it.

load("@rules_cc//cc:cc_library.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

licenses(["notice"])

exports_files(["LICENSE"])

cc_library(
    name = "mimalloc",
    srcs = [
        # keep sorted
        "include/mimalloc/atomic.h",
        "include/mimalloc/internal.h",
        "include/mimalloc/prim.h",
        "include/mimalloc/track.h",
        "include/mimalloc/types.h",
        "src/alloc-aligned.c",
        "src/alloc-posix.c",
        "src/alloc.c",
        "src/arena.c",
        "src/bitmap.c",
        "src/bitmap.h",
        "src/heap.c",
        "src/init.c",
        "src/libc.c",
        "src/options.c",
        "src/os.c",
        "src/page.c",
        "src/prim/prim.c",
        "src/random.c",
        "src/segment-map.c",
        "src/segment.c",
        "src/stats.c",
    ],
    # One target rather than the public headers split out into a second one.
    # RuntimeGlobals depends on this through an alias and includes mimalloc.h,
    # and layering_check wants the header to come from a direct dependency, so
    # putting it anywhere else buys a second target and a new way to be wrong.
    hdrs = [
        "include/mimalloc-stats.h",
        "include/mimalloc.h",
    ],
    copts = [
        # mimalloc is C, and it is somebody else's C. The warnings this tree
        # turns on for its own code are not a useful thing to fail somebody
        # else's build on, and there is no version of this we would fix by
        # editing their source.
        "-Wno-everything",
    ],
    includes = ["include"],
    linkopts = select({
        # bcrypt is the one that is easy to miss. mimalloc seeds its own random
        # state from BCryptGenRandom, so leaving this out links fine right up
        # until the first allocation.
        "@platforms//os:windows": [
            "-Wl,/DEFAULTLIB:advapi32.lib",
            "-Wl,/DEFAULTLIB:bcrypt.lib",
            "-Wl,/DEFAULTLIB:psapi.lib",
            "-Wl,/DEFAULTLIB:shell32.lib",
            "-Wl,/DEFAULTLIB:user32.lib",
        ],
        "//conditions:default": [],
    }),
    linkstatic = True,
    local_defines = ["MI_STATIC_LIB"],
    # These are #included by the sources above rather than compiled on their
    # own. src/prim/prim.c picks one of the platform files by #if, and alloc.c
    # pulls in the other three. Listing them in srcs instead would compile each
    # of them a second time as a standalone translation unit, which is how you
    # get duplicate symbols out of a library that builds fine with make.
    textual_hdrs = [
        # keep sorted
        "src/alloc-override.c",
        "src/arena-abandon.c",
        "src/free.c",
        "src/page-queue.c",
        "src/prim/emscripten/prim.c",
        "src/prim/osx/prim.c",
        "src/prim/unix/prim.c",
        "src/prim/wasi/prim.c",
        "src/prim/windows/prim.c",
    ],
)
