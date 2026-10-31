# Release retry reason: Metal access in restricted environment
Original Builds/20261030T052458Z_release_38f74c02 build exit65 at CompileMetalFile, diagnostic missing Metal Toolchain amid sandbox/XPC permission errors. No successful archive exists.
Read-only escalated xcrun metal --version exit0 confirms installed Apple Metal32023.883 at cryptexd MetalToolchain-v17.6.109.0. No download/install needed. Evidence coordinator/commands/20261030T052555_metal-toolchain-access_890f0674.
Retry same frozen product command once with normal system permissions in new unique build directory, no source changes. This is incomplete-build recovery, not repeat passing tests. Preserve first failed build and all logs. No install or app launch.
