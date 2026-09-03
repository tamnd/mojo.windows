"""Puts a test's harness on the machine running the build and the binary under test on the
target machine.

A cross build has two machines in it and Bazel's test rules are written for one. Almost
everything a mojo_filecheck_test or a lit test is made of runs where the build runs: the
Python wrapper, FileCheck, `not`, lit itself, and the mojo driver a lit test invokes. The
only part that belongs on Windows is the binary whose output is being checked.

Configured the obvious way, all of it is built for Windows. The Python toolchain resolves
against the target platform and picks a Windows interpreter, FileCheck comes out as
FileCheck.exe, and every one of these tests fails with

    python.exe: can't open file 'C:\\...\\test_negative_index_list.mojo.test'

before reaching anything to do with the port. That was 109 of the 119 failures across
tier 0 and tier 1, which is to say most of what the suite was reporting about Windows was
a fact about Bazel.

So the test rule takes an incoming transition back to the host platform, which puts the
whole harness where it runs, and the binary under test comes in through the rule below,
whose single attribute transitions forward to the Windows platform again. Both are no ops
unless //bazel/internal:cross_test is on, which only --config=windows turns on, so an
ordinary build sees none of this and analyses exactly what it did before.
"""

load("@rules_python//python/private:py_test_rule.bzl", upstream_py_test = "py_test")  # buildifier: disable=bzl-visibility

_CROSS_TEST = "//bazel/internal:cross_test"
_PLATFORMS = "//command_line_option:platforms"
_HOST_PLATFORM = "//command_line_option:host_platform"

# One platform rather than a setting that carries it, because this repository cross builds
# to exactly one target and pretending otherwise would be inventing a generality nobody has
# asked for. When there is a second, this is the line that grows a select.
_TARGET_PLATFORM = "//:windows-x86_64-platform"

# Exported in pieces as well as as a transition, because lit.bzl already has a transition
# of its own on the same rule and a rule gets one.
HOST_PLATFORM_INPUTS = [_CROSS_TEST, _PLATFORMS, _HOST_PLATFORM]
HOST_PLATFORM_OUTPUTS = [_PLATFORMS]

def host_platform_settings(settings):
    """The platform half of an incoming transition that moves a test to the host.

    Args:
        settings: the transition's settings, which must include HOST_PLATFORM_INPUTS.

    Returns:
        A dict to merge into what the transition returns.
    """
    if not settings[_CROSS_TEST]:
        return {_PLATFORMS: settings[_PLATFORMS]}
    return {_PLATFORMS: [str(settings[_HOST_PLATFORM])]}

def _to_host_impl(settings, attr):
    _ = attr  # @unused
    return host_platform_settings(settings)

_to_host = transition(
    implementation = _to_host_impl,
    inputs = HOST_PLATFORM_INPUTS,
    outputs = HOST_PLATFORM_OUTPUTS,
)

def _to_target_impl(settings, attr):
    _ = attr  # @unused
    if not settings[_CROSS_TEST]:
        return {_PLATFORMS: settings[_PLATFORMS]}
    return {_PLATFORMS: [_TARGET_PLATFORM]}

_to_target = transition(
    implementation = _to_target_impl,
    inputs = [_CROSS_TEST, _PLATFORMS],
    outputs = [_PLATFORMS],
)

def _target_platform_binary_impl(ctx):
    # An attribute with a transition on it comes back as a list, one entry per branch, and
    # this transition has one branch.
    inner = ctx.attr.binary[0][DefaultInfo]

    # Only the executable in files, with everything else moved into runfiles. A Windows
    # mojo_binary reports its shared libraries as default outputs alongside the exe, and
    # $(location) on a target with more than one of those is an error. The libraries still
    # have to be staged and still have to land in the same directory as the exe, which is
    # what putting them in runfiles does, since they share a package with it.
    files = inner.files.to_list()
    exe = inner.files_to_run.executable
    return [DefaultInfo(
        files = depset([exe]),
        runfiles = ctx.runfiles(files = files).merge(inner.default_runfiles),
    )]

target_platform_binary = rule(
    implementation = _target_platform_binary_impl,
    doc = """Forwards a binary built for the target platform into a test that is not.

    The point of it is the transition on the attribute. Everything else about it is a
    passthrough, so a $(location) on it names the same file the binary itself would have.
    """,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            cfg = _to_target,
            doc = "The binary under test, built for the target platform.",
        ),
    },
)

py_test = rule(
    implementation = lambda ctx: ctx.super(),
    parent = upstream_py_test,
    cfg = _to_host,
    doc = "A py_test whose whole tree is built for the machine running the build.",
)
