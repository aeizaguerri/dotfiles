# Use GNOME Keyring's SSH agent in Wayland sessions when no agent is set.
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" && -n "${XDG_RUNTIME_DIR:-}" && -z "${SSH_AUTH_SOCK:-}" ]]; then
  _keyring_ssh_socket="$XDG_RUNTIME_DIR/keyring/ssh"
  if [[ -S "$_keyring_ssh_socket" ]]; then
    export SSH_AUTH_SOCK="$_keyring_ssh_socket"
  else
    eval "$(gnome-keyring-daemon --start --components=ssh)"
  fi
  unset _keyring_ssh_socket
fi
