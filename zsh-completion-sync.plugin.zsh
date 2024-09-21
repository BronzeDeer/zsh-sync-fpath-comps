_completion_sync:debug_log(){
  if zstyle -t "$1" debug; then
    echo "completion sync: $2"
  fi
}

_completion_sync:delete_first_from_fpath(){
  # There might be multiple instances of the same path on the fpath
  # We will only delete the first instance to "reset" the priority order
  # but leave later occurences
  local idx="$fpath[(Ie)$1]"
  if (( $idx != 0 )); then
    _completion_sync:debug_log ':completion-sync:fpath:delete' "deleting '$1' from FPATH at index '$idx'"
    fpath[$idx]=()
  fi
}

_completion_sync:fpath_maybe_add_xdg(){
  # There are two valid paths in an XDG_DATA_DIR, one from the zsh install and one from third party
  # It is unclear if would ever make sense to add the ones from the zsh install,
  # since they should be always on the fpath, but for now we test for both

  local p="$1/zsh/$ZSH_VERSION/functions"

  if [[ -d $p ]]; then
    _completion_sync:debug_log ':completion-sync:xdg:add' "Added '$p' to FPATH"
    fpath=("$p" $fpath)
  fi


  p="$1/zsh/site-functions"
  if [[ -d $p ]]; then
    _completion_sync:debug_log ':completion-sync:xdg:add' "Added '$p' to FPATH"
    fpath=("$p" $fpath)
  fi
}

_completion_sync:functions_from_xdg_data(){
  local a=($(echo "$XDG_DATA_DIRS" | tr ':' "\n" | xargs -I{} realpath -e "{}/zsh/site-functions" "\n" realpath -e "{}/zsh/$ZSH_VERSION/functions" 2>/dev/null | tr "\n" ' '))
  # unique the directories
  echo "${(u)a[@]}"
}

_completion_sync:hook(){
  if zstyle -T ':completion-sync:xdg' enabled; then
    if [[ ! -v COMPLETION_SYNC_OLD_XDG_DATA_DIRS ]]; then
      _completion_sync:debug_log ':completion-sync:xdg:init' "Syncing XDG_DATA_DIRS into FPATH enabled"

      _completion_sync:debug_log ':completion-sync:xdg:init:diff' "old FPATH\n${(F)fpath}"

      # First time around, only add relevant XDG_DATA_DIRs, which are not on the FPATH yet
      # Find XDG_DATA_DIRS which have $ZSH function dirs under them
      completion_sync_old_xdg_fpaths=( $(_completion_sync:functions_from_xdg_data) )

      _completion_sync:debug_log ':completion-sync:xdg:init:diff' "adding from XDG"

      # Prepend in reverse order to maintain their order in the final path
      for idx in {${#completion_sync_old_xdg_fpaths}..1} ; do
        local elem="${completion_sync_old_xdg_fpaths[$idx]}"
        if (( ! ${fpath[(I)"$elem"]} )); then

          _completion_sync:debug_log ':completion-sync:xdg:init:diff' $elem

          fpath=($elem $fpath)
        fi
      done

      _completion_sync:debug_log ':completion-sync:xdg:init:diff' "New FPATH\n${(F)fpath}"

    elif [[ "$COMPLETION_SYNC_OLD_XDG_DATA_DIRS" != "$XDG_DATA_DIRS" ]]; then
      _completion_sync:debug_log ':completion-sync:xdg:onchange' "XDG_DATA_DIRS CHANGED"
      # Check if the fpath dirs changed
      local new_paths=( $(_completion_sync:functions_from_xdg_data) )

      if [[ "$completion_sync_old_xdg_fpaths" != "$new_paths" ]]; then
        _completion_sync:debug_log ':completion-sync:xdg:onchange' "Need to update FPATH from XDG_DATA_DIRS!"

        local diff=( "${(@)$(diff <(for p in $new_paths; do echo $p; done) <(for p in $completion_sync_old_xdg_fpaths; do echo $p; done) | grep -E "<|>")}" )
        _completion_sync:debug_log ':completion-sync:xdg:diff' "$diff"

        # Prepend in reverse order to maintain their order in the final path
        for idx in {${#diff}..1} ; do
          local p=$diff[$idx]
          case "${p[1]}" in
            \<)
              # path got added
              local p_path="${p:2}"
              _completion_sync:debug_log ':completion-sync:xdg:onchange:add' "Adding path '$p_path'"
              _completion_sync:debug_log ':completion-sync:fpath:add' "Adding '$p_path' to FPATH"
              fpath=("$p_path" $fpath)
              ;;
            \>)
              # path got removed
              local p_path="${p:2}"
              _completion_sync:debug_log ':completion-sync:xdg:onchange:delete' "Removing path '$p_path'"
              _completion_sync:delete_first_from_fpath "$p_path"
              ;;
            *)
              # This should not happen
              _completion_sync:debug_log ':completion-sync:xdg:onchange' "Invalid diff line $p"
              _completion_sync:debug_log ':completion-sync:xdg:onchange' "Tried to match on character ${p[1]}"
              ;;
          esac
        done

        completion_sync_old_xdg_fpaths=( "${(@f)new_paths}" )
      else
        _completion_sync:debug_log ':completion-sync:xdg:onchange' "No FPATH change needed"
      fi
    fi
    COMPLETION_SYNC_OLD_XDG_DATA_DIRS="$XDG_DATA_DIRS"
  fi

  if [[ ! -v completion_sync_old_fpath ]]; then
    _completion_sync:debug_log ':completion-sync:fpath:init' "Syncing completions to fpath enabled"
    # Do no re-init the first time around
  elif [[ "$completion_sync_old_fpath" != "$fpath" ]]; then

    _completion_sync:debug_log ':completion-sync:fpath:onchange' "FPATH Changed!"
    if zstyle -t ':completion-sync:fpath:onchange:diff' debug; then
      diff <(echo "${(F)fpath}" | sort ) <(echo "${(F)completion_sync_old_fpath}" | sort) | grep -E "<|>"
    fi

    # Allow us to restore the previous compinit, to be a good citizen
    functions -c compinit compinit_orig
    # Remove the current compinit to allow for reloading
    unfunction compinit
    # restore original compinit
    autoload +X compinit

    _completion_sync:debug_log ':completion-sync:compinit:autoload' "previous compinit: $(whence -v compinit_orig)"
    _completion_sync:debug_log ':completion-sync:compinit:autoload' "loaded compinit: $(whence -v compinit)"


    # do not write dumpfile, since we are likely working on a temporary FPATH
    # TODO: make argument configurable
    _completion_sync:debug_log ':completion-sync:compinit' "invoking compinit as 'compinit -D'"
    compinit -D
    # restore original function
    functions -c compinit_orig compinit
    _completion_sync:debug_log ':completion-sync:compinit:autoload' "restored compinit: $(whence -v compinit)"

  fi
  completion_sync_old_fpath=( "${(@f)fpath}" )
}

typeset -ag precmd_functions
if (( ! ${precmd_functions[(I)_completion_sync:hook]} )); then
# Add our hook last to go after _direnv_hook
  precmd_functions=($precmd_functions _completion_sync:hook)
fi
typeset -ag chpwd_functions
if (( ! ${chpwd_functions[(I)_completion_sync:hook]} )); then
  # Add our hook last to go after _direnv_hook
  chpwd_functions=($chpwd_functions _completion_sync:hook)
fi
