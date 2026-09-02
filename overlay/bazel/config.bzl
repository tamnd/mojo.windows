"""Shared config that needs to be referenced by BUILD.bazel files but isn't important enough to be in api.bzl"""

# Used for linting unused targets, top level targets are potentially used
# externally, and therefore their deps are all considered used
TOP_LEVEL_TAG = "top-level"

# Used for linting unused targets, these targets might be unused and that's
# allowed, used sparingly, primarily used for macros that expand to multiple
# targets, some of which are optional
ALLOW_UNUSED_TAG = "maybe-unused"

# Default GPU memory for scheduling remote exec tests
DEFAULT_GPU_MEMORY = "0.8"

MODULAR_CONFIGS = [
    "default",
    "debug_modular",
    "debug_everything",
    "dev",
    "ci_build",
    "release",
    "production",
    "asan",
    "tsan",
    "ubsan",
    "coverage",
]

ASYNCRT_PROFILING_LOCAL_DEFINES = [
    "MODULAR_ASYNCRT_MAX_PROFILING_LEVEL=0000000",
]

CONFIG_SECTION_LOCAL_DEFINES = [
    "MAX_CONFIG_SECTION=max",
    "MOJO_CONFIG_SECTION=mojo-max",
]

KERNEL_PROFILING_LOCAL_DEFINES = [
    "MODULAR_ENABLE_GPU_PROFILING=0",
    "MODULAR_ENABLE_GPU_PROFILING_DETAILED=0",
]

# How the target OS names library files. Both halves of a name come from the same
# arm, because prefix and suffix are not independent: ELF and Mach-O want a "lib"
# prefix and PE does not, so a build that picks the suffix per OS and hardcodes the
# prefix produces "libfoo.dll", which is a plausible looking name that nothing on
# the system is called. There is deliberately no default. An OS nobody has thought
# about should fail here during analysis rather than quietly inherit another OS's
# naming and go wrong later at a dlopen that cannot find anything.
PLATFORM_LIB_NAME_LOCAL_DEFINES = select({
    "@platforms//os:linux": [
        "SHARED_LIBRARY_PREFIX='\"lib\"'",
        "SHARED_LIBRARY_SUFFIX='\".so\"'",
        "STATIC_LIBRARY_PREFIX='\"lib\"'",
        "STATIC_LIBRARY_SUFFIX='\".a\"'",
    ],
    "@platforms//os:macos": [
        "SHARED_LIBRARY_PREFIX='\"lib\"'",
        "SHARED_LIBRARY_SUFFIX='\".dylib\"'",
        "STATIC_LIBRARY_PREFIX='\"lib\"'",
        "STATIC_LIBRARY_SUFFIX='\".a\"'",
    ],
    "@platforms//os:windows": [
        "SHARED_LIBRARY_PREFIX='\"\"'",
        "SHARED_LIBRARY_SUFFIX='\".dll\"'",
        "STATIC_LIBRARY_PREFIX='\"\"'",
        "STATIC_LIBRARY_SUFFIX='\".lib\"'",
    ],
})
