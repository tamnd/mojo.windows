"""Helper code for feature crosstool configuration."""

MARKER_FEATURES = [
    "archive_param_file",
    "compile_all_modules",
    # Bazel's own name, checked by the compile action builder rather than by
    # anything here, and only turned on for a Windows host. There is no entry for
    # linker_param_file next to it because rules_cc already defines that one, and
    # a second definition of the same name is an analysis error. See the comment
    # on PARAM_FILE_FEATURES in cc-toolchain/BUILD.bazel.
    "compiler_param_file",
    # Bazel asks the feature configuration whether this is on and copies every
    # dynamic library a binary needs next to the binary when it is. The feature
    # carries no flags, so this is the whole of its definition, but it has to
    # exist here or the answer is always no: a --features flag naming a feature
    # the toolchain has never heard of is quietly dropped, which is why turning
    # it on from the command line appeared to do nothing.
    "copy_dynamic_libraries_to_binary",
    "exclude_private_headers_in_module_maps",
    "gcc_quoting_for_param_files",
    "modular_code",  # Differentiate between third and first party code
    "module_maps",
    "only_doth_headers_in_module_maps",
    "set_soname",
    "supports_start_end_lib",
    "sysroot",  # Stop duplicate sysroot confusion until legacy features are disabled
]
