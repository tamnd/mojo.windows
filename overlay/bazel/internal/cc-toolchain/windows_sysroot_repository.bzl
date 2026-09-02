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
# they stay out. Keeping the list narrow matters more here than it looks, for two reasons.
# Every file under one of these becomes an input that Bazel hashes on every action, and
# these are the paths the repository links in one by one rather than linking crt and sdk
# wholesale, which is what keeps the loops described below out of the repository.
_DIRS = [
    "crt/include",
    "crt/lib/x86_64",
    "sdk/include/shared",
    "sdk/include/ucrt",
    "sdk/include/um",
    "sdk/lib/ucrt/x86_64",
    "sdk/lib/um/x86_64",
]

_INCLUDES = "[\n" + "".join(['    "{}/**",\n'.format(d) for d in _DIRS]) + "]"

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

def _empty(rctx, reason):
    rctx.file("sysroot/REASON", reason + "\n")
    rctx.file("sysroot/BUILD.bazel", _BUILD_TEMPLATE.format(
        includes = _INCLUDES,
        srcs = "[]",
    ))

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

    # One symlink per directory in _DIRS rather than one for crt and one for sdk, which is
    # the obvious way to write this and is wrong. An xwin splat carries the path spellings
    # that MSVC projects expect, so sdk/Include is a symlink to sdk/include and
    # sdk/include/10.0.26100 is a symlink to the directory holding it. Anything walking the
    # tree with symlinks followed then sees a loop, which is exactly what the builtin
    # module map rule does, and it fails the build with nothing on stderr because that
    # walk discards it. Linking the seven directories we actually use means the loops are
    # never in the repository to begin with, and the paths still read the same, which
    # matters because the module map lists headers by path and the compiler matches them
    # by path.
    for path in _DIRS:
        target = root
        for part in path.split("/"):
            target = target.get_child(part)
        rctx.symlink(target, "sysroot/" + path)

    rctx.file("sysroot/BUILD.bazel", _BUILD_TEMPLATE.format(
        includes = _INCLUDES,
        srcs = "glob(_INCLUDES, allow_empty = True)",
    ))

windows_sysroot_repository = repository_rule(
    implementation = _windows_sysroot_repository_impl,
    environ = [_ENV_VAR],
    local = True,
    configure = True,
)
