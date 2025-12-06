# Clone Zinit (plugin manager)
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"

# Download zinit if it si not
if [ ! -d $ZINIT_HOME ]; then 
  mkdir -p "$(dirname $ZINIT_HOME)"
  git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi

# Source Zinit
source "${ZINIT_HOME}/zinit.zsh"

# Starship
export STARSHIP_CONFIG="${HOME}/.config/starship/starship.toml"
eval "$(starship init zsh)"

# Core plugins
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-syntax-highlighting
zinit light zsh-users/zsh-completions
zinit light Aloxaf/fzf-tab

# Load comletion
autoload -Uz compinit && compinit -C

# History
HISTSIZE=5000
SAVEHIST=5000
HISTFILE="$XDG_CACHE_HOME/zsh_history" # move histfile to cache
HISTDUP=erase

# ZHS Options
setopt appendhistory #append commands to hist file
setopt sharehistory #share history across sessions
setopt hist_ignore_space #dont add commands to hist if it starts with a space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# zstyle options
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}' # make completion non case sensitive
zstyle ':completion:*' group-name ''
zstyle ':completion:*' list-prompt '%S%M matches%s'
zstyle ':completion:*' list-colors '$(s.:.)LS_COLORS' 
zstyle ':completion:*' max-errors 5
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
# zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'

# Shell integrations
eval "$(fzf --zsh)"
# eval "$(zoxide init --cmd cd zsh)"

# Alises
alias sync-gdrive="~/.local/bin/gdrive_sync.sh"
alias ls='ls --color'

# Commands
# === Update Zinit & Plugins Function ===
zsh-update() {
  echo "🔄 Updating Zinit and plugins..."
  zinit self-update && zinit update --all
  echo "✅ All Zinit plugins updated!"
}
