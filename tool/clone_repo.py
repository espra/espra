#!/usr/bin/env python3

# Public Domain (-) 2026-present, The Espra Core Authors.
# See the Espra Core UNLICENSE file for details.

import os
import subprocess
import sys

from common import exit


def main():
    if len(sys.argv) < 4:
        print("Usage: clone_repo.py <name> <repo-url> <revision> [--init-submodules]")
        sys.exit(1)
    name = sys.argv[1]
    repo = sys.argv[2]
    revision = sys.argv[3]
    if len(sys.argv) > 4 and sys.argv[4] == "--init-submodules":
        init_submodules = True
    else:
        init_submodules = False

    root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dep_dir = os.path.join(root_dir, "dep")
    repo_dir = os.path.join(dep_dir, name)

    prefix = ""
    if not os.path.exists(repo_dir):
        print(f">> Cloning {repo} ...\n")
        prefix = "\n"
        subprocess.run(["git", "clone", repo, name], check=True, cwd=dep_dir)

    result = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, check=True, cwd=repo_dir, text=True)
    current_rev = result.stdout.strip()
    if current_rev == revision:
        result = subprocess.run(["git", "status", "--porcelain"], capture_output=True, check=True, cwd=repo_dir, text=True)
        if result.stdout.strip():
            exit(f"Repository at {repo_dir} is dirty, please commit or stash your changes")
    else:
        print(f"{prefix}>> Checking out {name} at {revision} ...\n")
        prefix = "\n"
        subprocess.run(["git", "checkout", revision], check=True, cwd=repo_dir)

    if init_submodules:
        result = subprocess.run(["git", "submodule", "status"], capture_output=True, check=True, cwd=repo_dir, text=True)
        if any(line and line[0] in ("+", "-") for line in result.stdout.splitlines()):
            print(f"{prefix}>> Initializing git submodules for {name}...\n")
            subprocess.run(["git", "submodule", "update", "--init", "--recursive"], check=True, cwd=repo_dir)


if __name__ == "__main__":
    main()
