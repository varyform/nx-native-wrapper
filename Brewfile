# The tools nxnative's builds run (its README: "Pack an IPA"), plus uv for the Python packages.
# bin/setup installs them: brew bundle --file Brewfile
brew "uv"            # Python and the packages in .venv (pyproject.toml, uv.lock)
brew "xcodegen"      # the iOS projects nxnative generates, and NX Play's own
brew "zstd"
brew "glslang"       # shaders of OpenGL games
# retired: cask "dotnet-sdk"   nx_extract and the shader translator needed .NET 10 until nxnative 641636e2
# (2026-11-10) committed them as native executables. Setup installed it before; Uninstall still offers to remove it.
