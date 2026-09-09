# ===== BEGIN hpc-stack ======================================================
# Append this block to ~/.bashrc (it is shared across master and compute node
# if your home is on NFS - that is fine, 00-env.sh is node-agnostic).
#
#   cat ~/hpc-stack/bashrc-snippet.sh >> ~/.bashrc && source ~/.bashrc
#
# NOTE: Ubuntu's stock .bashrc returns early for non-interactive shells, so
# `ssh dgx-node1 'ollama list'` would NOT see these vars. That is why every
# script in the bundle sources 00-env.sh explicitly. Put this block ABOVE the
# early-return line if you want non-interactive ssh commands to inherit it.

if [ -f "$HOME/hpc-stack/00-env.sh" ]; then
    . "$HOME/hpc-stack/00-env.sh"
fi

# convenience aliases
alias svc='bash $HOME/hpc-stack/svc.sh'
alias coder='bash $HOME/hpc-stack/coder-ctl.sh'
alias general='bash $HOME/hpc-stack/vllm-ctl.sh'
alias doctor='bash $HOME/hpc-stack/doctor.sh'
alias gpu='ssh -t "$HPC_GPU_NODE"'
alias gpustat='ssh "$HPC_GPU_NODE" nvidia-smi'
alias workdu='du -sh "$WORK"/* 2>/dev/null | sort -h'
alias homedu='du -sh "$HOME"/.[!.]* "$HOME"/* 2>/dev/null | sort -h | tail -20'

# one-line reminder of where you are
if [ -n "${PS1:-}" ]; then
    case "$(hostname -s)" in
        "$HPC_GPU_NODE") PS1="\[\033[1;32m\][gpu]\[\033[0m\] $PS1" ;;
        *)               PS1="\[\033[1;34m\][master]\[\033[0m\] $PS1" ;;
    esac
fi
# ===== END hpc-stack ========================================================
