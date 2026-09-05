# The Windows counterpart of clang.BUILD.
#
# A separate file rather than a suffix in the other one because the two describe
# archives from different publishers. The three Unix clangs are Modular's own
# builds, and this is the stock llvm-project release, so the layouts agree today
# by coincidence and there is nothing keeping them in step. Writing the names
# out here means a layout change in either archive shows up as a missing file
# with a path in the message rather than as an empty glob.
#
# Everything below is the same as clang.BUILD except that the executables are
# named with .exe, which is what they are called on disk and what a cc_tool has
# to be pointed at. The globbed filegroups need no change, since a glob for
# bin/clang* matches clang.exe as happily as it matches clang.

load("@bazel_skylib//rules/directory:directory.bzl", "directory")

package(default_visibility = ["//visibility:public"])

exports_files(
    glob([
        "lib/clang/*/lib/*/*clang_rt.*",
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

filegroup(
    name = "include",
    srcs = [
        "lib/clang/22/include",
        "lib/clang/22/share",  # sanitizer default ignore lists
    ],
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
    srcs = ["bin/llvm-ar.exe"],
)

filegroup(
    name = "as",
    srcs = ["bin/llvm-as.exe"],
)

filegroup(
    name = "nm",
    srcs = ["bin/llvm-nm.exe"],
)

filegroup(
    name = "objcopy",
    srcs = ["bin/llvm-objcopy.exe"],
)

filegroup(
    name = "objdump",
    srcs = ["bin/llvm-objdump.exe"],
)

filegroup(
    name = "profdata",
    srcs = ["bin/llvm-profdata.exe"],
)

filegroup(
    name = "dwp",
    srcs = ["bin/llvm-dwp.exe"],
)

filegroup(
    name = "ranlib",
    srcs = [
        "bin/llvm-ar.exe",
        "bin/llvm-ranlib.exe",
    ],
)

filegroup(
    name = "strip",
    srcs = [
        "bin/llvm-objcopy.exe",
        "bin/llvm-strip.exe",
    ],
)

filegroup(
    name = "clang-tidy",
    srcs = ["bin/clang-tidy.exe"],
)
