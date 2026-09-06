"""A tool that always resolves against the machine running the build."""

def _exec_tool_impl(ctx):
    source = ctx.file.tool

    # Windows will not run a file without the extension, and the exec platform here is
    # whatever machine the build is on rather than whatever it is building for, so the
    # name follows the file this points at rather than the platform being targeted.
    name = ctx.label.name
    if source.extension:
        name += "." + source.extension

    output = ctx.actions.declare_file(name)
    ctx.actions.symlink(output = output, target_file = source, is_executable = True)

    return [DefaultInfo(
        executable = output,
        files = depset([output]),
        runfiles = ctx.runfiles(files = [output]),
    )]

exec_tool = rule(
    doc = """Forwards a build time tool through an exec configuration dependency.

An alias whose actual is a select over platforms resolves that select in whatever
configuration the thing depending on it is in. For a tool that runs during the build
that is the wrong question to ask, because on a cross build the target platform is not
the platform the tool has to run on, and the answer is a binary the build machine cannot
execute. Every dependency edge into the tool being cfg = "exec" would say the same
thing, but a data attribute has no such knob and there is at least one of those.

So the select goes behind this instead. The dependency is exec configured here, once,
and everything downstream gets a binary that runs without having to know it had to ask.
""",
    implementation = _exec_tool_impl,
    executable = True,
    attrs = {
        "tool": attr.label(
            allow_single_file = True,
            cfg = "exec",
            doc = "The tool to forward. Usually an alias over a per platform select.",
            mandatory = True,
        ),
    },
)
