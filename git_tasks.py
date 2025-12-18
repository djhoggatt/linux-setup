##
# @file git_tasks.py
#
# @brief Git related invoke tasks. See https://docs.pyinvoke.org/en/stable/ for more info.


# --------------------------------------------------------------------------------------------------
#  Imports
# --------------------------------------------------------------------------------------------------


import subprocess
from tempfile import NamedTemporaryFile

from invoke import task
from invoke import Collection


# --------------------------------------------------------------------------------------------------
# Global Constants
# --------------------------------------------------------------------------------------------------


# --------------------------------------------------------------------------------------------------
# Class/Functions
# --------------------------------------------------------------------------------------------------


def _do_diff(ctx, left_file, right_file):
    ctx.run("nvim -d "
            "-c 'set diffopt+=vertical,linematch:60,context:99999' "
            f"{left_file} {right_file}"
            , pty=True, echo=True)


def _commit_file_diff(ctx, commit, file):
    """
    Vim diff on the given file, for the given commit, against it's parent.
    """

    with NamedTemporaryFile(mode='w', delete=True) as left_file:
        with NamedTemporaryFile(mode='w', delete=True) as right_file:
            try:
                result = ctx.run(f"git show {commit}^:{file} > {left_file.name}")
            except:
                left_file.write(""); # File might not exist, so just compare it with empty

            result = ctx.run(f"git show {commit}:{file} > {right_file.name}")
            if result.exited != 0:
                return

            _do_diff(ctx, left_file.name, right_file.name)


def _local_diff(ctx, file):
    """
    Vim diff on the given file, against it's parent.
    """

    with NamedTemporaryFile(mode='w', delete=True) as left_file:
        with NamedTemporaryFile(mode='w', delete=True) as right_file:
            result = ctx.run(f"git show HEAD:{file} > {left_file.name}")
            if result.exited != 0:
                return

            _do_diff(ctx, left_file.name, file)


@task
def graph(ctx):
    """
    Interactive git log browser: pick commit, pick file, nvim diff.
    """
    # 1) outer loop: pick commits as many times as you want
    while True:
        with NamedTemporaryFile(mode='r', delete=True) as commit_file:
            result = subprocess.run(
                "git log --all --color=always --date=short --decorate --graph "
                "--pretty=format:'%C(yellow)%h%Creset %Cgreen%ad%Creset %Cblue%an%Creset "
                "%C(auto)%d%Creset %s%x09%H' "
                "| fzf --ansi --no-sort --reverse --delimiter=$'\\t' --with-nth=1 "
                f" > {commit_file.name}",
                shell=True,
            )
        
            if result.returncode != 0:
                break

            commit = commit_file.read().strip().split("\t")[-1] # The hash is after the TAB
            if not commit:
                print("Error picking commit!")
                continue

            print(f"Commit {commit}")

        # 2) inner loop: pick files from that commit as many times as you want
        while True:
            with NamedTemporaryFile(mode='r', delete=True) as file_file:
                result = subprocess.run(
                        f"git show -m --name-only --pretty='' {commit} "
                        f"| fzf --ansi --reverse --prompt='file> ' "
                        f"> {file_file.name}",
                        shell=True,
                )
                
                if result.returncode != 0:
                    break

                file = file_file.read().strip()
                if not file:
                    print("Error picking file!")
                    continue

            _commit_file_diff(ctx, commit, file)


@task(help={
    "staged": "Applies the diff to staged changes"
    })
def diff(ctx, staged=False):
    """
    Interactive diff for the current changes in the project.
    """

    while True:
        with NamedTemporaryFile(mode='r', delete=True) as file_file:
            result = subprocess.run(
                    f"git diff --name-only --relative {'--staged' if staged else ''} "
                    f"| fzf --ansi --reverse --prompt='{'' if staged else 'un'}staged> ' "
                    f"> {file_file.name}",
                    shell=True,
            )
            
            if result.returncode != 0:
                break

            file = file_file.read().strip()
            if not file:
                print("Error picking file!")
                continue

            _local_diff(ctx, file)


@task(positional=["file"], help={
    "file": "Path to the file",
    })
def filelog(ctx, file):
    """
    Interactive diff through a specific file's history.
    """

    while True:
        with NamedTemporaryFile(mode='r', delete=True) as commit_file:
            result = subprocess.run(
                "git log --first-parent --follow --color=always --date=short --decorate "
                "--pretty=format:"
                "'%C(yellow)%h%Creset %Cgreen%ad%Creset %Cblue%an%Creset %C(auto)%d%Creset %s%x09%H' "
                f"{file} "
                "| fzf --ansi --no-sort --reverse --delimiter=$'\\t' --with-nth=1 "
                f" > {commit_file.name}",
                shell=True,
            )
            
            if result.returncode != 0:
                break

            commit = commit_file.read().strip().split("\t")[-1] # The hash is after the TAB
            if not commit:
                print("Error picking commit!")
                continue

            _commit_file_diff(ctx, commit, file)

 
# --------------------------------------------------------------------------------------------------
# Script
# --------------------------------------------------------------------------------------------------

git_tasks = Collection()
git_tasks.add_task(graph)
git_tasks.add_task(diff)
git_tasks.add_task(filelog)

