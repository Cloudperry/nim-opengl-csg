#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

print_usage() {
  echo "Usage: $0 [slang-binary-path]"
  echo "  [slang-binary-path]  Optional directory containing the slangc shader compiler."
  echo "                       If omitted, slangc is looked up from PATH."
}

slang_bin_path=""
if [[ $# -ge 1 ]]; then
  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    print_usage
    exit 0
  fi
  slang_bin_path="$1"
fi

release_date="$(date +%Y-%m-%d)"
release_root="releases"
release_name="platformer-game-release-$release_date"
release_dir="$release_root/$release_name"
archive_path="$release_dir.tar.xz"

game_bin="bin/platformer-game"
tester_bin="bin/platformer-game-tester"
replay_tests_bin="bin/platformer-game-tests"

nimble build -d:release -d:glfwStaticLib

if [[ ! -x "$game_bin" ]]; then
  echo "Expected game binary not found: $game_bin" >&2
  exit 1
fi

if [[ ! -x "$tester_bin" ]]; then
  echo "Expected tester binary not found: $tester_bin" >&2
  exit 1
fi

rm -rf "$release_dir" "$archive_path"
mkdir -p "$release_dir"

mv "$game_bin" "$tester_bin" "$release_dir/"
cp -a testData "$release_dir/"

# Bundle a debug build of all tests so the
# release can be verified on the target machine.
nim c -d:debug -o:"$replay_tests_bin" tests/AllTests.nim
mv "$replay_tests_bin" "$release_dir/"

if ! nim r -d:debug src/Game.nim --compileShadersAndQuit --slangBinPath="$slang_bin_path"; then
  echo "Shader compilation failed (is slangc installed in PATH or passed as an argument?)." >&2
  print_usage >&2
  exit 1
fi

mkdir -p "$release_dir/shaders"
find shaders -maxdepth 1 -type f -name "*.glsl" -print0 |
  while IFS= read -r -d "" shader; do
    cp "$shader" "$release_dir/shaders/"
  done

if ! find "$release_dir/shaders" -maxdepth 1 -type f -name "*.glsl" | grep -q .; then
  echo "No GLSL shader files were copied into $release_dir/shaders" >&2
  exit 1
fi

tar -cJf "$archive_path" -C "$release_root" "$release_name"

echo "Created release archive: $archive_path"
