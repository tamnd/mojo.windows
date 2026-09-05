load("@bazel_skylib//rules/directory:directory.bzl", "directory")

package(default_visibility = ["//visibility:public"])

exports_files(
    glob([
        "lib/clang/*/lib/*/libclang_rt.*",
        "bin/*",
    ]),
)

filegroup(
    name = "clang",
    srcs = glob(["bin/clang*"]),
)

filegroup(
    name = "ld",
    srcs = glob(["bin/*ld*"]),
)

# Globbed rather than named as two directories, because a source directory is a
# single opaque file as far as Bazel is concerned and nothing can see inside it
# without running a tool. builtin_module_map needs the list of files, and with
# the directories named here the only way to get it was to shell out to find,
# which is a thing that does not exist on a Windows host. The inputs are the
# same either way. See bazel/internal/cc-toolchain/tools/builtin_module_map.bzl.
filegroup(
    name = "include",
    srcs = glob([
        "lib/clang/22/include/**",
        "lib/clang/22/share/**",  # sanitizer default ignore lists
    ]),
)

directory(
    name = "include_dir",
    srcs = [":include"],
)

filegroup(
    name = "resource_directory_filegroup",
    srcs = ["lib/clang/22"],
)

directory(
    name = "resource_directory",
    srcs = [":resource_directory_filegroup"],
)

filegroup(
    name = "bin",
    srcs = glob(["bin/**"]),
)

filegroup(
    name = "ar",
    srcs = ["bin/llvm-ar"],
)

filegroup(
    name = "as",
    srcs = ["bin/llvm-as"],
)

filegroup(
    name = "nm",
    srcs = ["bin/llvm-nm"],
)

filegroup(
    name = "objcopy",
    srcs = ["bin/llvm-objcopy"],
)

filegroup(
    name = "objdump",
    srcs = ["bin/llvm-objdump"],
)

filegroup(
    name = "profdata",
    srcs = ["bin/llvm-profdata"],
)

filegroup(
    name = "dwp",
    srcs = ["bin/llvm-dwp"],
)

filegroup(
    name = "ranlib",
    srcs = [
        "bin/llvm-ar",
        "bin/llvm-ranlib",
    ],
)

filegroup(
    name = "strip",
    srcs = [
        "bin/llvm-objcopy",
        "bin/llvm-strip",
    ],
)

filegroup(
    name = "clang-tidy",
    srcs = ["bin/clang-tidy"],
)
