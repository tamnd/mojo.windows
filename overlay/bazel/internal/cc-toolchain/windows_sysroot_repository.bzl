"""Create a local repository for the MSVC CRT and the Windows SDK.

Modelled on macos_sysroot_repository.bzl in this directory, and for the same reason. The
Linux sysroots come down as tarballs from an artifact bucket because they are made of
things that can be redistributed. Microsoft's CRT and SDK are not, so there is nothing to
put in a bucket and the headers have to come from the machine doing the build.

Unlike the macOS case there is no xcrun to ask. The layout this expects is the one xwin
produces, which is a crt directory and an sdk directory side by side. Point at one with
MOJO_WINDOWS_SYSROOT, and see scripts/windows-sysroot.sh in the mojo.windows repository
for how to make one and what accepting the Visual Studio licence means.

With nothing to point at, this writes an empty repository rather than failing. That is
deliberate and copied from the macOS rule. Analysis of a Windows configured build then
works anywhere, which is what the cross build lane needs, and only an actual compile
action fails, which is honest because an actual compile action is the thing that cannot
be done without the headers.
"""

_ENV_VAR = "MOJO_WINDOWS_SYSROOT"

# Everything the C and C++ compiler needs and nothing else. winrt and cppwinrt are the two
# big directories in an xwin splat and no part of this project is a WinRT component, so
# they stay out. Keeping the glob narrow matters more here than it looks, because every
# file it matches becomes an input that Bazel hashes on every action.
_INCLUDES = """[
    "crt/include/**",
    "crt/lib/x86_64/**",
    "sdk/include/shared/**",
    "sdk/include/ucrt/**",
    "sdk/include/um/**",
    "sdk/lib/ucrt/x86_64/**",
    "sdk/lib/um/x86_64/**",
]"""

_BUILD_TEMPLATE = """\
load("@bazel_skylib//rules/directory:directory.bzl", "directory")

_INCLUDES = {includes}

directory(
    name = "root",
    srcs = {srcs},
    visibility = ["//visibility:public"],
)

filegroup(
    name = "directory",
    srcs = {srcs},
    visibility = ["//visibility:public"],
)
"""

# The four include trees again, gathered under one directory so that something wanting
# only headers can ask for only headers. It is a package of its own rather than a target
# in the one above because a directory target is rooted at its own package, and there is
# no way to say "the crt/include part of this" without either a subdirectory target,
# which fails at analysis time when the sysroot is not configured and the subdirectory
# does not exist, or a second package, which does not.
#
# The names here are what a compiler would call these header sets and not the paths they
# came from, since nothing downstream includes through this directory. It exists to be
# walked.
_HEADER_DIRS = {
    "crt": "crt/include",
    "shared": "sdk/include/shared",
    "ucrt": "sdk/include/ucrt",
    "um": "sdk/include/um",
}

_HEADERS_BUILD = """\
load("@bazel_skylib//rules/directory:directory.bzl", "directory")

directory(
    name = "headers",
    srcs = glob(
        ["**"],
        exclude = ["BUILD.bazel"],
        allow_empty = True,
    ),
    visibility = ["//visibility:public"],
)
"""

def _empty(rctx, reason):
    rctx.file("sysroot/REASON", reason + "\n")
    rctx.file("sysroot/BUILD.bazel", _BUILD_TEMPLATE.format(
        includes = _INCLUDES,
        srcs = "[]",
    ))
    rctx.file("headers/BUILD.bazel", _HEADERS_BUILD)

def _windows_sysroot_repository_impl(rctx):
    configured = rctx.getenv(_ENV_VAR)
    if not configured:
        _empty(rctx, "{} is not set".format(_ENV_VAR))
        return

    root = rctx.path(configured)
    if not root.exists:
        _empty(rctx, "{} points at {}, which does not exist".format(_ENV_VAR, configured))
        return

    # Check for the two directories rather than just the root, because pointing this at the
    # xwin cache directory instead of its output is an easy mistake and the failure it
    # causes otherwise is a wall of missing header errors much later on.
    for required in ["crt", "sdk"]:
        if not root.get_child(required).exists:
            _empty(rctx, "{} has no {} directory, so it is not an xwin splat output".format(configured, required))
            return

    for child in root.readdir(watch = "no"):
        rctx.symlink(child, "sysroot/" + child.basename)

    rctx.file("sysroot/BUILD.bazel", _BUILD_TEMPLATE.format(
        includes = _INCLUDES,
        srcs = "glob(_INCLUDES, allow_empty = True)",
    ))

    for name, path in _HEADER_DIRS.items():
        target = root
        for part in path.split("/"):
            target = target.get_child(part)
        rctx.symlink(target, "headers/" + name)

    rctx.file("headers/BUILD.bazel", _HEADERS_BUILD)

windows_sysroot_repository = repository_rule(
    implementation = _windows_sysroot_repository_impl,
    environ = [_ENV_VAR],
    local = True,
    configure = True,
)
