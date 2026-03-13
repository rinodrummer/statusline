#!/bin/bash
input=$(cat)

# Extract fields from JSON input
model_display=$(echo "$input" | jq -r '.model.display_name // .model // "unknown"')
cwd=$(echo "$input" | jq -r '.cwd // "."')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
exceeds_200k=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

# Format context size (e.g. 200000 => 200K, 1000000 => 1M, 1000000000 => 1B)
if [ "$context_size" -ge 1000000000 ] 2>/dev/null; then
  context_fmt="$((context_size / 1000000000))B"
elif [ "$context_size" -ge 1000000 ] 2>/dev/null; then
  context_fmt="$((context_size / 1000000))M"
elif [ "$context_size" -ge 1000 ] 2>/dev/null; then
  context_fmt="$((context_size / 1000))K"
else
  context_fmt="$context_size"
fi

# Session start time and duration
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  start_epoch=$(stat -c '%W' "$transcript_path" 2>/dev/null)
  if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
    start_date=$(date -d "@$start_epoch" '+%d/%m/%Y')
    today=$(date '+%d/%m/%Y')
    if [ "$start_date" = "$today" ]; then
      start_time=$(date -d "@$start_epoch" '+%H:%M')
    else
      start_time="${start_date} $(date -d "@$start_epoch" '+%H:%M')"
    fi
    now_epoch=$(date '+%s')
    elapsed=$((now_epoch - start_epoch))
    hours=$((elapsed / 3600))
    minutes=$(( (elapsed % 3600) / 60 ))
    seconds=$((elapsed % 60))
    if [ "$hours" -gt 0 ]; then
      duration="${hours}h${minutes}m${seconds}s"
    elif [ "$minutes" -gt 0 ]; then
      duration="${minutes}m${seconds}s"
    else
      duration="${seconds}s"
    fi
    time_part=" \x1b[2;37m${start_time} (${duration})\x1b[0m"
  else
    time_part=""
  fi
else
  time_part=""
fi

# Warning icon if exceeding 200k tokens
if [ "$exceeds_200k" = "true" ]; then
  warn="\x1b[1;33m\xef\x81\xb1 \x1b[0m"
else
  warn=""
fi

# Context progress bar
pct=${used_pct%%.*}
bar_width=10
filled=$((pct * bar_width / 100))
empty=$((bar_width - filled))
bar=""
for ((i=0; i<filled; i++)); do bar+="\xe2\x96\x88"; done
for ((i=0; i<empty; i++)); do bar+="\xe2\x96\x91"; done

# Current directory name (not full path)
dir_name=$(basename "$cwd")

# Added dirs (extra directories in workspace)
added_dirs=$(echo "$input" | jq -r '.workspace.added_dirs // [] | map(split("/") | last) | join(", ")' 2>/dev/null)
if [ -n "$added_dirs" ]; then
  added_dirs_part=" + \x1b[2;34m${added_dirs}\x1b[0m"
else
  added_dirs_part=""
fi

# Project name (from package.json if available, otherwise git root basename)
project_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$project_root" ] && [ -f "$project_root/package.json" ]; then
  project_name=$(jq -r '.name // empty' "$project_root/package.json" 2>/dev/null)
fi
if [ -z "$project_name" ]; then
  project_name=$(basename "${project_root:-$cwd}")
fi

# Repo name (git root directory name)
if [ -n "$project_root" ]; then
  repo_name=$(basename "$project_root")
else
  repo_name=""
fi

# Git branch
git_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo "")

# Git status
if [ -n "$git_branch" ]; then
  # Commits ahead of remote
  ahead=$(git -C "$cwd" rev-list --count @{upstream}..HEAD 2>/dev/null || echo "0")
  # Working tree + staged file counts
  added=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c '^[?A]')
  modified=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c '^.\?M')
  deleted=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c '^.\?D')

  git_status=""
  [ "$ahead" -gt 0 ] 2>/dev/null && git_status+="\x1b[33m\xef\x85\xb6 ${ahead}\x1b[0m "
  [ "$added" -gt 0 ] 2>/dev/null && git_status+="\x1b[32m\xef\x81\x86 ${added}\x1b[0m "
  [ "$modified" -gt 0 ] 2>/dev/null && git_status+="\x1b[34m\xef\x81\x84 ${modified}\x1b[0m "
  [ "$deleted" -gt 0 ] 2>/dev/null && git_status+="\x1b[31m\xef\x85\x87 ${deleted}\x1b[0m "
  git_status="${git_status% }"
  [ -z "$git_status" ] && git_status="\x1b[32m\xe2\x9c\x93\x1b[0m"
  # Worktree info
  wt_name=$(echo "$input" | jq -r '.worktree.name // ""')
  wt_branch=$(echo "$input" | jq -r '.worktree.branch // ""')
  wt_original_branch=$(echo "$input" | jq -r '.worktree.original_branch // ""')
  if [ -n "$wt_name" ]; then
    worktree_part=" \x1b[2;37m[\x1b[0m\x1b[1;36m${wt_name}\x1b[0m\x1b[2;37m:\x1b[0m\x1b[36m${wt_branch}\x1b[0m \x1b[2;37m<- ${wt_original_branch}]\x1b[0m"
  else
    worktree_part=""
  fi

  # Show repo name if it differs from both dir_name and project_name
  git_icon="\xee\x9c\xa5"
  if [ -n "$repo_name" ] && [ "$repo_name" != "$dir_name" ] && [ "$repo_name" != "$project_name" ]; then
    git_part=" (${git_icon} \x1b[33m${repo_name}\x1b[0m > \x1b[36m${git_branch}\x1b[0m > ${git_status})${worktree_part}"
  else
    git_part=" (${git_icon} \x1b[36m${git_branch}\x1b[0m > ${git_status})${worktree_part}"
  fi
else
  git_part=""
fi

# IDE detection
ide_icon=""
ide_name=""
if [ "$TERM_PROGRAM" = "vscode" ]; then
  ide_icon="\xee\xa3\x9a"  # nf-dev-vscode
  ide_name="VS Code"
elif [ "$TERM_PROGRAM" = "cursor" ]; then
  ide_icon="\xef\x84\xa1"  # nf-fa-code (fallback)
  ide_name="Cursor"
elif [ "$TERM_PROGRAM" = "windsurf" ]; then
  ide_icon="\xef\x84\xa1"  # nf-fa-code (fallback)
  ide_name="Windsurf"
elif [ "$TERMINAL_EMULATOR" = "JetBrains-JetbrainsIde" ]; then
  jb_hist="${__INTELLIJ_COMMAND_HISTFILE__:-}"
  case "$jb_hist" in
    *IntelliJIdea*) ide_icon="\xee\x9e\xb5"; ide_name="IntelliJ" ;;    # nf-dev-intellij
    *PhpStorm*)     ide_icon="\xee\xa1\xa2"; ide_name="PhpStorm" ;;     # nf-dev-phpstorm
    *WebStorm*)     ide_icon="\xee\xa3\xa4"; ide_name="WebStorm" ;;     # nf-dev-webstorm
    *PyCharm*)      ide_icon="\xee\xa1\xb7"; ide_name="PyCharm" ;;      # nf-dev-pycharm
    *RubyMine*)     ide_icon="\xee\xa2\x96"; ide_name="RubyMine" ;;     # nf-dev-rubymine
    *Rider*)        ide_icon="\xee\xa2\x8f"; ide_name="Rider" ;;        # nf-dev-rider
    *CLion*)        ide_icon="\xee\x9e\x8e"; ide_name="CLion" ;;        # nf-dev-clion
    *GoLand*)       ide_icon="\xee\x9f\xaf"; ide_name="GoLand" ;;       # nf-dev-goland
    *DataGrip*)     ide_icon="\xee\x9e\xbd"; ide_name="DataGrip" ;;     # nf-dev-datagrip
    *)              ide_icon="\xee\xa0\x88"; ide_name="JetBrains" ;;     # nf-dev-jetbrains
  esac
else
  ide_icon="\xee\x9d\xa0"  # nf-dev-bash
  ide_name=""
fi

if [ -n "$ide_name" ]; then
  ide_part=" ${ide_icon} \x1b[2;37m${ide_name}\x1b[0m"
else
  ide_part=" ${ide_icon}"
fi

# Agent name (if running as an agent)
agent_name=$(echo "$input" | jq -r '.agent.name // ""')
if [ -n "$agent_name" ]; then
  agent_part="\x1b[1;32m${agent_name}\x1b[0m "
else
  agent_part=""
fi

# Line 1: <Agent name> [Model / Context | Progress bar] <Folder icon> <Dir name> + <added dirs> <IDE icon> <IDE name>
printf "${agent_part}[\x1b[1;33m%s\x1b[0m | ${warn}${bar} %d%% \x1b[2;37m/ %s\x1b[0m] \xf0\x9f\x93\x82 \x1b[1;34m%s\x1b[0m${added_dirs_part}${ide_part}\n" \
  "$model_display" "$pct" "$context_fmt" "$dir_name"
# Line 2: <Project name> <Git section> <Clock icon> <start time (duration)>
clock_icon="\xef\x80\x97"
printf "\x1b[1;35m%s\x1b[0m${git_part}${time_part:+ ${clock_icon}${time_part}}" "$project_name"
