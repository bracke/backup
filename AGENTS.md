# Agent instructions

This repository is an Ada 2022 command-line backup utility.

## Toolchain

Use Alire GNAT 15 only. Do not run plain system `gnat*`, `gnatmake`, `gnatls`,
`gnatprove`, `gprbuild`, or `gprinstall` in this workspace. Use
`alr exec -- ...` for compiler, prover, installer, and builder commands so PATH
cannot select a different GNAT installation.

The root and tests manifests must pin:

```toml
[[depends-on]]
gnat_native = "=15.2.1"
```

Confirm the selected compiler with:

```sh
alr exec -- gnatls --version
```

## Validation

Preferred validation:

```sh
alr build
cd tests && alr build && ./bin/tests
cd ..
alr exec -- gprbuild -P tools/tools.gpr
tools/bin/check_all
```

When GNAT/GPRBuild/GNATprove are unavailable through Alire, state that clearly
and run the static checks the environment supports.

## Boundaries

Use repository tooling through `tools/` and `project_tools`. Do not introduce
system zlib, Python-generated fixtures, or system GNAT/GPR toolchain
dependencies.
