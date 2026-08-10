#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assets_home="$script_dir/assets/home"

# Update bashrc
# Motivation: There are a lot of different shells. Most of them are very similar. While I don't
# like scripting in bash, it is very common, and I do most of my scripting in python anyways.
cp "$assets_home/.bashrc" "$HOME/.bashrc"

# Install qutebrowser.
# Motivation: qutebrowser gives me a keyboard-first browser with native vim-style navigation,
# and this setup keeps the browser integrated with the translucent Wayland desktop.
sudo apt install -y qutebrowser
if apt-cache show python3-pyqt6.qtwebengine >/dev/null 2>&1; then
    sudo apt install -y python3-pyqt6.qtwebengine
elif apt-cache show python3-pyqt5.qtwebengine >/dev/null 2>&1; then
    sudo apt install -y python3-pyqt5.qtwebengine
fi
mkdir -p "$HOME/.config/qutebrowser/styles"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
cp "$assets_home/.config/qutebrowser/config.py" "$HOME/.config/qutebrowser/config.py"
cp "$assets_home/.config/qutebrowser/autoconfig.yml" "$HOME/.config/qutebrowser/autoconfig.yml"
cp "$assets_home/.config/qutebrowser/styles/translucent-page.css" "$HOME/.config/qutebrowser/styles/translucent-page.css"
cp "$assets_home/.local/bin/qutebrowser" "$HOME/.local/bin/qutebrowser"
chmod 755 "$HOME/.local/bin/qutebrowser"
cp "$assets_home/.local/share/applications/org.qutebrowser.qutebrowser.desktop" "$HOME/.local/share/applications/org.qutebrowser.qutebrowser.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" || true
fi
sudo install -m 755 "$script_dir/assets/usr/local/bin/qutebrowser-hint-overlay-workaround" /usr/local/bin/qutebrowser-hint-overlay-workaround
sudo qutebrowser-hint-overlay-workaround
xdg-mime default org.qutebrowser.qutebrowser.desktop x-scheme-handler/http x-scheme-handler/https text/html

# Install Thunar and make it the default file browser.
sudo apt install -y thunar xdg-utils
xdg-mime default thunar.desktop inode/directory
if command -v gio >/dev/null 2>&1; then
    gio mime inode/directory thunar.desktop
fi

# Install Ghostty, and ghostty config
# Motivation: Ghostty is super easy to configure, and has enough native features such that I don't
# need other applications (e.g. tmux or screen).
sudo snap install --classic ghostty
mkdir -p "$HOME/.config/ghostty"
cp "$assets_home/.config/ghostty/config" "$HOME/.config/ghostty/config"

# Install git, and git config
# Motivation: A non-linear graph-based version control system is simply the best way to manage
# code, particularly in environment where multiple people are working on the same codebase at
# the same time. Git isn't perfect, but with proper branching and merging strategies, it works
# very well.
sudo apt install -y git
cp "$assets_home/.gitconfig" "$HOME/.gitconfig"

# Install Nvim
# Motivation: Nvim supports lua scripting. So I can make a single init file, that sets everything
# up the exact way I want it, and is portable across different systems. Vim isn't for everyone, but
# I'm used to it, and normal vim isn't as easy to configure as nvim.
sudo snap install --edge --classic nvim
mkdir -p "$HOME/.config/nvim"
cp "$assets_home/.config/nvim/init.lua" "$HOME/.config/nvim/init.lua"

# Install Native gcc
# Motivation: Some projects or tests need to be compiled for the native architecture.
sudo apt install -y build-essential

# Install ARM gcc
# Motivation: Most of my development is for ARM microcontrollers.
sudo apt install -y gcc-arm-none-eabi

# Install ninja and meson
# Motivation: Build systems for C are difficult. Meson using ninja has been the smoothest
# experience I've had so far, and integrates well with python scripting.
sudo apt install -y ninja-build meson

# Install personal command line tools
# Motivation: I do a lot of scripting in python. These are stock-python scripts (no third party
# tooling) exposed on PATH. git-tools is wired up as git aliases (git graph/localdiff/filelog),
# and jira-tools wraps the jira-cli.
mkdir -p "$HOME/.local/bin"
cp "$assets_home/.local/bin/git-tools" "$HOME/.local/bin/git-tools"
cp "$assets_home/.local/bin/github-tools" "$HOME/.local/bin/github-tools"
cp "$assets_home/.local/bin/jira-tools" "$HOME/.local/bin/jira-tools"
chmod 755 "$HOME/.local/bin/git-tools" "$HOME/.local/bin/github-tools" "$HOME/.local/bin/jira-tools"

# Install Zig
# Motivation: Zig is, in my opinion, the best replacement for C. It adds in all of the features that
# C should have had and nothing more. I enjoy programming in C, and Zig makes it even better.
sudo snap install --beta --classic zig

# Install Node.js and npm
# Motivation: Some tools I use for web development and other tasks require node.js and npm.
sudo apt install -y nodejs npm

# Install Variety, Hook in Desktop Backgrounds
# Motivation: I like rotating backgrounds for variety, and variety makes it easy to do so.
sudo apt install -y variety
mkdir -p "$HOME/backgrounds"
git clone https://github.com/djhoggatt/root-and-rail
cp ./root-and-rail/images/* "$HOME/backgrounds/"
rm -rf ./root-and-rail

# Install microcom
# Motivation: All I want is a simple serial terminal that I can run from the command line
# with minimal configuration.
sudo apt install -y microcom

# Install go-grip
# Motivation: Getting a good markdown viewer is actually surprisingly difficult. In particular,
# getting something with native mermaid support is quite difficult. It may be best to switch to
# pandoc -> pdf -> pdf TUI viewer, but this requires an external mermaid filter for pandoc (also
# latex, but that's fine), which I was having trouble setting up. The easiest thing, that really
# "just worked" was go-grip. Regular grip also has mermaid issues. This does open up a browser
# window. I tried using it in conjunction with browsesh, but browsesh had it's own issues, and
# the rendering was very poor.
sudo apt install -y golang-go
go install github.com/chrishrb/go-grip@latest
sudo ln -sf "$HOME/go/bin/go-grip" /bin/go-grip

# Setup git credentials
#
# git config --global user.name djhoggatt
# ssh-keygen -t ed25519 -C "djhoggatt@gmail.com"

#Install wee-slack
# Motivation: Need a slack interface into my terminal, so that I can monitor slack from the 
# terminal. This prevents me from needed a separate browser window open for messaging.
sudo apt install weechat-python python3-websocket
mkdir -p ~/.local/share/weechat/python/autoload
cd ~/.local/share/weechat/python
curl -L -o wee_slack.py https://raw.githubusercontent.com/wee-slack/wee-slack/master/wee_slack.py
ln -s ../wee_slack.py autoload/wee_slack.py
