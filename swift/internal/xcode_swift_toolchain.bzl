# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""BUILD rules used to provide a Swift toolchain provided by Xcode on macOS.

The rules defined in this file are not intended to be used outside of the Swift
toolchain package. If you are looking for rules to build Swift code using this
toolchain, see `swift.bzl`.
"""

load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(":actions.bzl", "swift_action_names")
load(":attrs.bzl", "swift_toolchain_driver_attrs")
load(":compiling.bzl", "compile_action_configs", "features_from_swiftcopts")
load(
    ":feature_names.bzl",
    "SWIFT_FEATURE_BUNDLED_XCTESTS",
    "SWIFT_FEATURE_CACHEABLE_SWIFTMODULES",
    "SWIFT_FEATURE_COVERAGE",
    "SWIFT_FEATURE_COVERAGE_PREFIX_MAP",
    "SWIFT_FEATURE_DEBUG_PREFIX_MAP",
    "SWIFT_FEATURE_EMIT_SWIFTDOC",
    "SWIFT_FEATURE_EMIT_SWIFTSOURCEINFO",
    "SWIFT_FEATURE_ENABLE_BATCH_MODE",
    "SWIFT_FEATURE_ENABLE_SKIP_FUNCTION_BODIES",
    "SWIFT_FEATURE_FILE_PREFIX_MAP",
    "SWIFT_FEATURE_MODULE_MAP_HOME_IS_CWD",
    "SWIFT_FEATURE_OBJC_LINK_FLAGS",
    "SWIFT_FEATURE_OPT_USES_WMO",
    "SWIFT_FEATURE_REMAP_XCODE_PATH",
    "SWIFT_FEATURE_SUPPORTS_BARE_SLASH_REGEX",
    "SWIFT_FEATURE_SUPPORTS_LIBRARY_EVOLUTION",
    "SWIFT_FEATURE_SUPPORTS_PRIVATE_DEPS",
    "SWIFT_FEATURE_SUPPORTS_SYSTEM_MODULE_FLAG",
    "SWIFT_FEATURE_USE_GLOBAL_MODULE_CACHE",
    "SWIFT_FEATURE_USE_RESPONSE_FILES",
    "SWIFT_FEATURE__DISABLE_SWIFT_SANDBOX",
    "SWIFT_FEATURE__FORCE_ALWAYSLINK_TRUE",
    "SWIFT_FEATURE__SUPPORTS_CONST_VALUE_EXTRACTION",
    "SWIFT_FEATURE__SUPPORTS_MACROS",
)
load(":features.bzl", "features_for_build_modes")
load(
    ":providers.bzl",
    "SwiftFeatureAllowlistInfo",
    "SwiftInfo",
    "SwiftPackageConfigurationInfo",
    "SwiftToolchainInfo",
)
load(":target_triples.bzl", "target_triples")
load(":toolchain_config.bzl", "swift_toolchain_config")
load(
    ":utils.bzl",
    "collect_implicit_deps_providers",
    "get_swift_executable_for_toolchain",
)

# TODO: Remove once we drop bazel 7.x
_OBJC_PROVIDER_LINKING = hasattr(apple_common.new_objc_provider(), "linkopt")

# Maps (operating system, environment) pairs from target triples to the legacy
# Bazel core `apple_common.platform` values, since we still use some APIs that
# require these.
_TRIPLE_OS_TO_PLATFORM = {
    ("ios", None): apple_common.platform.ios_device,
    ("ios", "simulator"): apple_common.platform.ios_simulator,
    ("macos", None): apple_common.platform.macos,
    ("tvos", None): apple_common.platform.tvos_device,
    ("tvos", "simulator"): apple_common.platform.tvos_simulator,
    # TODO: Remove getattr use once we no longer support 6.x
    ("xros", None): getattr(apple_common.platform, "visionos_device", None),
    ("xros", "simulator"): getattr(apple_common.platform, "visionos_simulator", None),
    ("watchos", None): apple_common.platform.watchos_device,
    ("watchos", "simulator"): apple_common.platform.watchos_simulator,
}

def _bazel_apple_platform(target_triple):
    """Returns the `apple_common.platform` value for the given target triple."""

    # TODO: Remove once we no longer support 6.x
    if target_triples.unversioned_os(target_triple) == "xros" and not hasattr(
        apple_common.platform,
        "visionos_device",
    ):
        fail("visionOS requested but your version of bazel doesn't support it")

    return _TRIPLE_OS_TO_PLATFORM[(
        target_triples.unversioned_os(target_triple),
        target_triple.environment,
    )]

def _command_line_objc_copts(compilation_mode, cpp_fragment, objc_fragment):
    """Returns copts that should be passed to `clang` from the `objc` fragment.

    Args:
        compilation_mode: The current compilation mode.
        cpp_fragment: The `cpp` configuration fragment.
        objc_fragment: The `objc` configuration fragment.

    Returns:
        A list of `clang` copts, each of which is preceded by `-Xcc` so that
        they can be passed through `swiftc` to its underlying ClangImporter
        instance.
    """

    # In general, every compilation mode flag from native `objc_*` rules should
    # be passed, but `-g` seems to break Clang module compilation. Since this
    # flag does not make much sense for module compilation and only touches
    # headers, it's ok to omit.
    # TODO(b/153867054): These flags were originally being set by Bazel's legacy
    # hardcoded Objective-C behavior, which has been migrated to crosstool. In
    # the long term, we should query crosstool for the flags we're interested in
    # and pass those to ClangImporter, and do this across all platforms. As an
    # immediate short-term workaround, we preserve the old behavior by passing
    # the exact set of flags that Bazel was originally passing if the list we
    # get back from the configuration fragment is empty.
    legacy_copts = objc_fragment.copts_for_current_compilation_mode
    if not legacy_copts:
        if compilation_mode == "dbg":
            legacy_copts = [
                "-O0",
                "-DDEBUG=1",
                "-fstack-protector",
                "-fstack-protector-all",
            ]
        elif compilation_mode == "opt":
            legacy_copts = [
                "-Os",
                "-DNDEBUG=1",
                "-Wno-unused-variable",
                "-Winit-self",
                "-Wno-extra",
            ]

    clang_copts = cpp_fragment.objccopts + legacy_copts
    return [copt for copt in clang_copts if copt != "-g"]

def _platform_developer_framework_dir(
        apple_toolchain,
        target_triple):
    """Returns the Developer framework directory for the platform.

    Args:
        apple_toolchain: The `apple_common.apple_toolchain()` object.
        target_triple: The triple of the platform being targeted.

    Returns:
        The path to the Developer framework directory for the platform if one
        exists, otherwise `None`.
    """
    return paths.join(
        apple_toolchain.developer_dir(),
        "Platforms",
        "{}.platform".format(
            _bazel_apple_platform(target_triple).name_in_plist,
        ),
        "Developer/Library/Frameworks",
    )

def _sdk_developer_framework_dir(apple_toolchain, target_triple):
    """Returns the Developer framework directory for the SDK.

    Args:
        apple_toolchain: The `apple_common.apple_toolchain()` object.
        target_triple: The triple of the platform being targeted.

    Returns:
        The path to the Developer framework directory for the SDK if one
        exists, otherwise `None`.
    """

    # All platforms have a `Developer/Library/Frameworks` directory in their SDK
    # root except for macOS (all versions of Xcode so far)
    os = target_triples.unversioned_os(target_triple)
    if os == "macos":
        return None

    return paths.join(apple_toolchain.sdk_dir(), "Developer/Library/Frameworks")

def _swift_linkopts_providers(
        apple_toolchain,
        target_triple,
        toolchain_label,
        toolchain_root):
    """Returns providers containing flags that should be passed to the linker.

    The providers returned by this function will be used as implicit
    dependencies of the toolchain to ensure that any binary containing Swift code
    will link to the standard libraries correctly.

    Args:
        apple_toolchain: The `apple_common.apple_toolchain()` object.
        target_triple: The target triple `struct`.
        toolchain_label: The label of the Swift toolchain that will act as the
            owner of the linker input propagating the flags.
        toolchain_root: The path to a custom Swift toolchain that could contain
            libraries required to link the binary

    Returns:
        A `struct` containing the following fields:

        *   `cc_info`: A `CcInfo` provider that will provide linker flags to
            binaries that depend on Swift targets.
        *   `objc_info`: An `apple_common.Objc` provider that will provide
            linker flags to binaries that depend on Swift targets.
    """
    linkopts = []
    if toolchain_root:
        # This -L has to come before Xcode's to make sure libraries are
        # overridden when applicable
        linkopts.append("-L{}/usr/lib/swift/{}".format(
            toolchain_root,
            target_triples.platform_name_for_swift(target_triple),
        ))

    swift_lib_dir = paths.join(
        apple_toolchain.developer_dir(),
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
        target_triples.platform_name_for_swift(target_triple),
    )

    linkopts.extend([
        "-L{}".format(swift_lib_dir),
        "-L/usr/lib/swift",
        # TODO(b/112000244): These should get added by the C++ Starlark API,
        # but we're using the "c++-link-executable" action right now instead
        # of "objc-executable" because the latter requires additional
        # variables not provided by cc_common. Figure out how to handle this
        # correctly.
        "-Wl,-objc_abi_version,2",
        "-Wl,-rpath,/usr/lib/swift",
    ])

    if _OBJC_PROVIDER_LINKING:
        objc_info = apple_common.new_objc_provider(linkopt = depset(linkopts))
    else:
        objc_info = apple_common.new_objc_provider()

    return struct(
        cc_info = CcInfo(
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([
                    cc_common.create_linker_input(
                        owner = toolchain_label,
                        user_link_flags = depset(linkopts),
                    ),
                ]),
            ),
        ),
        objc_info = objc_info,
    )

def _resource_directory_configurator(developer_dir, _prerequisites, args):
    """Configures compiler flags about the toolchain's resource directory.

    We must pass a resource directory explicitly if the build rules are invoked
    using a custom driver executable or a partial toolchain root, so that the
    compiler doesn't try to find its resources relative to that binary.

    Args:
        developer_dir: The path to Xcode's Developer directory. This argument is
            pre-bound in the partial.
        _prerequisites: The value returned by
            `swift_common.action_prerequisites`.
        args: The `Args` object to which flags will be added.
    """
    args.add(
        "-resource-dir",
        (
            "{developer_dir}/Toolchains/{toolchain}.xctoolchain/" +
            "usr/lib/swift"
        ).format(
            developer_dir = developer_dir,
            toolchain = "XcodeDefault",
        ),
    )

def _all_action_configs(
        additional_objc_copts,
        additional_swiftc_copts,
        apple_toolchain,
        generated_header_rewriter,
        needs_resource_directory,
        target_triple):
    """Returns the action configurations for the Swift toolchain.

    Args:
        additional_objc_copts: Additional Objective-C compiler flags obtained
            from the `objc` configuration fragment (and legacy flags that were
            previously passed directly by Bazel).
        additional_swiftc_copts: Additional Swift compiler flags obtained from
            the `swift` configuration fragment.
        apple_toolchain: The `apple_common.apple_toolchain()` object.
        generated_header_rewriter: An executable that will be invoked after
            compilation to rewrite the generated header, or None if this is not
            desired.
        needs_resource_directory: If True, the toolchain needs the resource
            directory passed explicitly to the compiler.
        target_triple: The triple of the platform being targeted.

    Returns:
        The action configurations for the Swift toolchain.
    """

    # Basic compilation flags (target triple and toolchain search paths).
    action_configs = [
        swift_toolchain_config.action_config(
            actions = [
                swift_action_names.COMPILE,
                swift_action_names.COMPILE_MODULE_INTERFACE,
                swift_action_names.DERIVE_FILES,
                swift_action_names.PRECOMPILE_C_MODULE,
                swift_action_names.DUMP_AST,
            ],
            configurators = [
                swift_toolchain_config.add_arg(
                    "-target",
                    target_triples.str(target_triple),
                ),
                swift_toolchain_config.add_arg(
                    "-sdk",
                    apple_toolchain.sdk_dir(),
                ),
            ],
        ),
    ]

    action_configs.extend([
        # Xcode path remapping
        swift_toolchain_config.action_config(
            actions = [
                swift_action_names.COMPILE,
                swift_action_names.DERIVE_FILES,
            ],
            configurators = [
                swift_toolchain_config.add_arg(
                    "-debug-prefix-map",
                    "__BAZEL_XCODE_DEVELOPER_DIR__=/PLACEHOLDER_DEVELOPER_DIR",
                ),
            ],
            features = [
                [SWIFT_FEATURE_REMAP_XCODE_PATH, SWIFT_FEATURE_DEBUG_PREFIX_MAP],
            ],
        ),
        swift_toolchain_config.action_config(
            actions = [
                swift_action_names.COMPILE,
                swift_action_names.COMPILE_MODULE_INTERFACE,
                swift_action_names.DERIVE_FILES,
            ],
            configurators = [
                swift_toolchain_config.add_arg(
                    "-coverage-prefix-map",
                    "__BAZEL_XCODE_DEVELOPER_DIR__=/PLACEHOLDER_DEVELOPER_DIR",
                ),
            ],
            features = [
                [
                    SWIFT_FEATURE_REMAP_XCODE_PATH,
                    SWIFT_FEATURE_COVERAGE_PREFIX_MAP,
                    SWIFT_FEATURE_COVERAGE,
                ],
            ],
        ),
        swift_toolchain_config.action_config(
            actions = [
                swift_action_names.COMPILE,
                swift_action_names.DERIVE_FILES,
            ],
            configurators = [
                swift_toolchain_config.add_arg(
                    "-file-prefix-map",
                    "__BAZEL_XCODE_DEVELOPER_DIR__=/PLACEHOLDER_DEVELOPER_DIR",
                ),
            ],
            features = [
                [
                    SWIFT_FEATURE_REMAP_XCODE_PATH,
                    SWIFT_FEATURE_FILE_PREFIX_MAP,
                ],
            ],
        ),
    ])

    if needs_resource_directory:
        # If the user is using a custom driver but not a complete custom
        # toolchain, provide the original toolchain's resources as the resource
        # directory so that modules are found correctly.
        action_configs.append(
            swift_toolchain_config.action_config(
                actions = [
                    swift_action_names.COMPILE,
                    swift_action_names.DERIVE_FILES,
                    swift_action_names.PRECOMPILE_C_MODULE,
                    swift_action_names.DUMP_AST,
                ],
                configurators = [
                    partial.make(
                        _resource_directory_configurator,
                        apple_toolchain.developer_dir(),
                    ),
                ],
            ),
        )

    action_configs.extend(compile_action_configs(
        additional_objc_copts = additional_objc_copts,
        additional_swiftc_copts = additional_swiftc_copts,
        generated_header_rewriter = generated_header_rewriter,
    ))
    return action_configs

def _all_tool_configs(
        custom_toolchain,
        env,
        execution_requirements,
        generated_header_rewriter,
        swift_executable,
        toolchain_root):
    """Returns the tool configurations for the Swift toolchain.

    Args:
        custom_toolchain: The bundle identifier of a custom Swift toolchain, if
            one was requested.
        env: The environment variables to set when launching tools.
        execution_requirements: The execution requirements for tools.
        generated_header_rewriter: The optional executable that will be invoked
            after compilation to rewrite the generated header.
        swift_executable: A custom Swift driver executable to be used during the
            build, if provided.
        toolchain_root: The root directory of the toolchain, if provided.

    Returns:
        A dictionary mapping action name to tool configuration.
    """

    # Configure the environment variables that the worker needs to fill in the
    # Bazel placeholders for SDK root and developer directory, along with the
    # custom toolchain if requested.
    if custom_toolchain:
        env = dict(env)
        env["TOOLCHAINS"] = custom_toolchain

    env["SWIFT_AVOID_WARNING_USING_OLD_DRIVER"] = "1"

    tool_config = swift_toolchain_config.driver_tool_config(
        driver_mode = "swiftc",
        env = env,
        execution_requirements = execution_requirements,
        swift_executable = swift_executable,
        tools = [generated_header_rewriter] if generated_header_rewriter else [],
        toolchain_root = toolchain_root,
        use_param_file = True,
        worker_mode = "persistent",
    )

    tool_configs = {
        swift_action_names.COMPILE: tool_config,
        swift_action_names.DERIVE_FILES: tool_config,
        swift_action_names.DUMP_AST: tool_config,
        swift_action_names.PRECOMPILE_C_MODULE: (
            swift_toolchain_config.driver_tool_config(
                driver_mode = "swiftc",
                env = env,
                execution_requirements = execution_requirements,
                swift_executable = swift_executable,
                toolchain_root = toolchain_root,
                use_param_file = True,
                worker_mode = "wrap",
            )
        ),
        swift_action_names.COMPILE_MODULE_INTERFACE: (
            swift_toolchain_config.driver_tool_config(
                driver_mode = "swiftc",
                args = ["-frontend"],
                env = env,
                execution_requirements = execution_requirements,
                swift_executable = swift_executable,
                toolchain_root = toolchain_root,
                use_param_file = True,
                worker_mode = "wrap",
            )
        ),
    }

    return tool_configs

def _is_xcode_at_least_version(xcode_config, desired_version):
    """Returns True if we are building with at least the given Xcode version.

    Args:
        xcode_config: The `apple_common.XcodeVersionConfig` provider.
        desired_version: The minimum desired Xcode version, as a dotted version
            string.

    Returns:
        True if the current target is being built with a version of Xcode at
        least as high as the given version.
    """
    current_version = xcode_config.xcode_version()
    if not current_version:
        fail("Could not determine Xcode version at all. This likely means " +
             "Xcode isn't available; if you think this is a mistake, please " +
             "file an issue.")

    desired_version_value = apple_common.dotted_version(desired_version)
    return current_version >= desired_version_value

def _xcode_env(target_triple, xcode_config):
    """Returns a dictionary containing Xcode-related environment variables.

    Args:
        target_triple: The triple of the platform being targeted.
        xcode_config: The `XcodeVersionConfig` provider that contains
            information about the current Xcode configuration.

    Returns:
        A `dict` containing Xcode-related environment variables that should be
        passed to Swift compile and link actions.
    """
    return dicts.add(
        apple_common.apple_host_system_env(xcode_config),
        apple_common.target_apple_env(
            xcode_config,
            _bazel_apple_platform(target_triple),
        ),
    )

def _entry_point_linkopts_provider(*, entry_point_name):
    """Returns linkopts to customize the entry point of a binary."""
    return struct(
        linkopts = ["-Wl,-alias,_{},_main".format(entry_point_name)],
    )

def _xcode_swift_toolchain_impl(ctx):
    cpp_fragment = ctx.fragments.cpp
    apple_toolchain = apple_common.apple_toolchain()
    cc_toolchain = find_cpp_toolchain(ctx)

    target_triple = target_triples.normalize_for_swift(
        target_triples.parse(cc_toolchain.target_gnu_system_name),
    )

    xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]

    # TODO: Remove once we drop bazel 7.x support
    if not bazel_features.cc.swift_fragment_removed:
        swiftcopts = list(ctx.fragments.swift.copts())
    else:
        swiftcopts = []

    if "-exec-" in ctx.bin_dir.path:
        swiftcopts.extend(ctx.attr._exec_copts[BuildSettingInfo].value)
    else:
        swiftcopts.extend(ctx.attr._copts[BuildSettingInfo].value)

    # `--define=SWIFT_USE_TOOLCHAIN_ROOT=<path>` is a rapid development feature
    # that lets you build *just* a custom `swift` driver (and `swiftc`
    # symlink), rather than a full toolchain, and point compilation actions at
    # those. Note that the files must still be in a "toolchain-like" directory
    # structure, meaning that the path passed here must contain a `bin`
    # directory and that directory contains the `swift` and `swiftc` files.
    #
    # TODO(allevato): Retire this feature in favor of the `swift_executable`
    # attribute, which supports remote builds.
    #
    # To use a "standard" custom toolchain built using the full Swift build
    # script, use `--define=SWIFT_CUSTOM_TOOLCHAIN=<id>` as shown below.
    swift_executable = get_swift_executable_for_toolchain(ctx)
    toolchain_root = ctx.var.get("SWIFT_USE_TOOLCHAIN_ROOT")

    # TODO: Remove SWIFT_CUSTOM_TOOLCHAIN for the next major release
    custom_toolchain = ctx.var.get("SWIFT_CUSTOM_TOOLCHAIN") or ctx.configuration.default_shell_env.get("TOOLCHAINS")
    custom_xcode_toolchain_root = None
    if ctx.var.get("SWIFT_CUSTOM_TOOLCHAIN"):
        print("WARNING: SWIFT_CUSTOM_TOOLCHAIN is deprecated. Use --action_env=TOOLCHAINS=<id> instead.")  # buildifier: disable=print
    if toolchain_root and custom_toolchain:
        fail("Do not use SWIFT_USE_TOOLCHAIN_ROOT and TOOLCHAINS" +
             "in the same build.")
    elif custom_toolchain:
        custom_xcode_toolchain_root = "__BAZEL_CUSTOM_XCODE_TOOLCHAIN_PATH__"

    swift_linkopts_providers = _swift_linkopts_providers(
        apple_toolchain = apple_toolchain,
        target_triple = target_triple,
        toolchain_label = ctx.label,
        toolchain_root = toolchain_root or custom_xcode_toolchain_root,
    )

    # Compute the default requested features and conditional ones based on Xcode
    # version.
    requested_features = features_for_build_modes(
        ctx,
        cpp_fragment = cpp_fragment,
    ) + features_from_swiftcopts(swiftcopts = swiftcopts)
    requested_features.extend(ctx.features)
    requested_features.extend([
        SWIFT_FEATURE_BUNDLED_XCTESTS,
        SWIFT_FEATURE_CACHEABLE_SWIFTMODULES,
        SWIFT_FEATURE_COVERAGE_PREFIX_MAP,
        SWIFT_FEATURE_DEBUG_PREFIX_MAP,
        SWIFT_FEATURE_EMIT_SWIFTDOC,
        SWIFT_FEATURE_EMIT_SWIFTSOURCEINFO,
        SWIFT_FEATURE_ENABLE_BATCH_MODE,
        SWIFT_FEATURE_ENABLE_SKIP_FUNCTION_BODIES,
        SWIFT_FEATURE_OBJC_LINK_FLAGS,
        SWIFT_FEATURE_OPT_USES_WMO,
        SWIFT_FEATURE_REMAP_XCODE_PATH,
        SWIFT_FEATURE_SUPPORTS_LIBRARY_EVOLUTION,
        SWIFT_FEATURE_SUPPORTS_PRIVATE_DEPS,
        SWIFT_FEATURE_SUPPORTS_SYSTEM_MODULE_FLAG,
        SWIFT_FEATURE_USE_GLOBAL_MODULE_CACHE,
        SWIFT_FEATURE_USE_RESPONSE_FILES,
    ])

    # Xcode 14 implies Swift 5.7.
    if _is_xcode_at_least_version(xcode_config, "14.0"):
        requested_features.append(SWIFT_FEATURE_FILE_PREFIX_MAP)
        requested_features.append(SWIFT_FEATURE_SUPPORTS_BARE_SLASH_REGEX)

    if getattr(ctx.fragments.objc, "alwayslink_by_default", False):
        requested_features.append(SWIFT_FEATURE__FORCE_ALWAYSLINK_TRUE)

    if _is_xcode_at_least_version(xcode_config, "15.0"):
        requested_features.append(SWIFT_FEATURE__SUPPORTS_MACROS)
        requested_features.append(SWIFT_FEATURE__SUPPORTS_CONST_VALUE_EXTRACTION)

    if _is_xcode_at_least_version(xcode_config, "15.3"):
        requested_features.append(SWIFT_FEATURE__DISABLE_SWIFT_SANDBOX)

    env = _xcode_env(target_triple = target_triple, xcode_config = xcode_config)
    execution_requirements = xcode_config.execution_info()
    generated_header_rewriter = ctx.executable.generated_header_rewriter

    all_tool_configs = _all_tool_configs(
        custom_toolchain = custom_toolchain,
        env = env,
        execution_requirements = execution_requirements,
        generated_header_rewriter = generated_header_rewriter,
        swift_executable = swift_executable,
        toolchain_root = toolchain_root,
    )
    all_action_configs = _all_action_configs(
        additional_objc_copts = _command_line_objc_copts(
            ctx.var["COMPILATION_MODE"],
            ctx.fragments.cpp,
            ctx.fragments.objc,
        ),
        additional_swiftc_copts = swiftcopts,
        apple_toolchain = apple_toolchain,
        generated_header_rewriter = generated_header_rewriter,
        needs_resource_directory = swift_executable or toolchain_root,
        target_triple = target_triple,
    )
    swift_toolchain_developer_paths = []
    platform_developer_framework_dir = _platform_developer_framework_dir(
        apple_toolchain,
        target_triple,
    )
    if platform_developer_framework_dir:
        swift_toolchain_developer_paths.append(
            struct(
                developer_path_label = "platform",
                path = platform_developer_framework_dir,
            ),
        )
    sdk_developer_framework_dir = _sdk_developer_framework_dir(
        apple_toolchain,
        target_triple,
    )
    if sdk_developer_framework_dir:
        swift_toolchain_developer_paths.append(
            struct(
                developer_path_label = "sdk",
                path = sdk_developer_framework_dir,
            ),
        )

    return [
        SwiftToolchainInfo(
            action_configs = all_action_configs,
            cc_toolchain_info = cc_toolchain,
            clang_implicit_deps_providers = collect_implicit_deps_providers(
                ctx.attr.clang_implicit_deps,
            ),
            developer_dirs = swift_toolchain_developer_paths,
            entry_point_linkopts_provider = _entry_point_linkopts_provider,
            feature_allowlists = [
                target[SwiftFeatureAllowlistInfo]
                for target in ctx.attr.feature_allowlists
            ],
            generated_header_module_implicit_deps_providers = (
                collect_implicit_deps_providers(
                    ctx.attr.generated_header_module_implicit_deps,
                )
            ),
            implicit_deps_providers = collect_implicit_deps_providers(
                ctx.attr.implicit_deps + ctx.attr.clang_implicit_deps,
                additional_cc_infos = [swift_linkopts_providers.cc_info],
                additional_objc_infos = [swift_linkopts_providers.objc_info],
            ),
            package_configurations = [
                target[SwiftPackageConfigurationInfo]
                for target in ctx.attr.package_configurations
            ],
            requested_features = requested_features,
            swift_worker = ctx.attr._worker[DefaultInfo].files_to_run,
            const_protocols_to_gather = ctx.file.const_protocols_to_gather,
            test_configuration = struct(
                env = env,
                execution_requirements = execution_requirements,
            ),
            tool_configs = all_tool_configs,
            unsupported_features = ctx.disabled_features + [
                SWIFT_FEATURE_MODULE_MAP_HOME_IS_CWD,
            ],
        ),
    ]

xcode_swift_toolchain = rule(
    attrs = dicts.add(
        swift_toolchain_driver_attrs(),
        {
            "clang_implicit_deps": attr.label_list(
                doc = """\
A list of labels to library targets that should be unconditionally added as
implicit dependencies of any explicit C/Objective-C module compiled by the Swift
toolchain and also as implicit dependencies of any Swift modules compiled by
the Swift toolchain.

Despite being C/Objective-C modules, the targets specified by this attribute
must propagate the `SwiftInfo` provider because the Swift build rules use that
provider to look up Clang module requirements. In particular, the targets must
propagate the provider in their rule implementation themselves and not rely on
the implicit traversal performed by `swift_clang_module_aspect`; the latter is
not possible as it would create a dependency cycle between the toolchain and the
implicit dependencies.
""",
                providers = [[SwiftInfo]],
            ),
            "feature_allowlists": attr.label_list(
                doc = """\
A list of `swift_feature_allowlist` targets that allow or prohibit packages from
requesting or disabling features.
""",
                providers = [[SwiftFeatureAllowlistInfo]],
            ),
            "generated_header_module_implicit_deps": attr.label_list(
                doc = """\
Targets whose `SwiftInfo` providers should be treated as compile-time inputs to
actions that precompile the explicit module for the generated Objective-C header
of a Swift module.
""",
                providers = [[SwiftInfo]],
            ),
            "generated_header_rewriter": attr.label(
                allow_files = True,
                cfg = "exec",
                doc = """\
If present, an executable that will be invoked after compilation to rewrite the
generated header.

This tool is expected to have a command line interface such that the Swift
compiler invocation is passed to it following a `"--"` argument, and any
arguments preceding the `"--"` can be defined by the tool itself (however, at
this time the worker does not support passing additional flags to the tool).
""",
                executable = True,
            ),
            "implicit_deps": attr.label_list(
                allow_files = True,
                doc = """\
A list of labels to library targets that should be unconditionally added as
implicit dependencies of any Swift compilation or linking target.
""",
                providers = [
                    [CcInfo],
                    [SwiftInfo],
                ],
            ),
            "package_configurations": attr.label_list(
                doc = """\
A list of `swift_package_configuration` targets that specify additional compiler
configuration options that are applied to targets on a per-package basis.
""",
                providers = [[SwiftPackageConfigurationInfo]],
            ),
            "const_protocols_to_gather": attr.label(
                default = Label("@build_bazel_rules_swift//swift/toolchains/config:const_protocols_to_gather.json"),
                allow_single_file = True,
                doc = """\
The label of the file specifying a list of protocols for extraction of conformances'
const values.
""",
            ),
            "_cc_toolchain": attr.label(
                default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
                doc = """\
The C++ toolchain from which linking flags and other tools needed by the Swift
toolchain (such as `clang`) will be retrieved.
""",
            ),
            "_copts": attr.label(
                default = Label("@build_bazel_rules_swift//swift:copt"),
                doc = """\
The label of the `string_list` containing additional flags that should be passed
to the compiler.
""",
            ),
            "_exec_copts": attr.label(
                default = Label("@build_bazel_rules_swift//swift:exec_copt"),
                doc = """\
The label of the `string_list` containing additional flags that should be passed
to the compiler for exec transition builds.
""",
            ),
            "_worker": attr.label(
                cfg = "exec",
                allow_files = True,
                default = Label(
                    "@build_bazel_rules_swift//tools/worker:worker_wrapper",
                ),
                doc = """\
An executable that wraps Swift compiler invocations and also provides support
for incremental compilation using a persistent mode.
""",
                executable = True,
            ),
            "_xcode_config": attr.label(
                default = configuration_field(
                    name = "xcode_config_label",
                    fragment = "apple",
                ),
            ),
        },
    ),
    doc = "Represents a Swift compiler toolchain provided by Xcode.",
    fragments = [
        "cpp",
        "objc",
    ] + ([] if bazel_features.cc.swift_fragment_removed else ["swift"]),
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    implementation = _xcode_swift_toolchain_impl,
)
