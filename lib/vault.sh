# shellcheck shell=bash
# Obsidian vaults as bare git repos. Not a sync daemon: SSH is already there, so
# a bare repo costs no port, no process and no memory, and conflicts end up as
# git conflicts a person can resolve.

cmd_vault() {
  load_config
  case ${1:-} in
    init)
      local name=${2:-main}
      remote "git init --bare --quiet $NOOK_DATA/vaults/$name.git"
      cat <<EOF
vault "$name" ready.

In the vault directory on this machine:

    git init
    git remote add nook $NOOK_HOST:$NOOK_DATA/vaults/$name.git

Then in Obsidian, the Git plugin:

    commit-and-sync   every 5 minutes
    pull on startup   on
EOF
      ;;
    list | "")
      remote "ls -1 $NOOK_DATA/vaults 2>/dev/null" | sed 's/\.git$//'
      ;;
    *) die "usage: nook vault init [name] | nook vault list" ;;
  esac
}
