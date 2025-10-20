# Update bashrc
sudo cp bash-rc ~/.bashrc

# Install Brave
sudo snap install brave

# Install Ghostty, and ghostty config
sudo snap install ghostty
sudo cp ghostty-config ~/.config/ghostty/config

# Instlal git, and git config
sudo apt install -y git
sudo cp git-config ~/.gitconfig

# Install Nvim
sudo snap install --edge --classic nvim
sudo cp nvim-init.lua ~/.config/nvim/init.lua

# Install Native gcc
sudo apt install -y build-essential

# Install ARM gcc
sudo apt install -y gcc-arm-none-eabi

# Install Zig
sudo snap install --beta --classic zig

# Install invoke
sudo apt install -y python3-invoke

# Install Node.js and npm
sudo apt install -y nodejs npm

# Install Variety, Hook in Desktop Backgrounds
sudo apt install -y variety
mkdir ~/backgrounds
mkdir root-and-rail
git clone https://github.com/djhoggatt/root-and-rail ./root-and-rail
sudo cp ./root-and-rail/images /usr/local/bin/
sudo rm -rf ./root-and-rail

# Install microcom
sudo apt install -y microcom

# Install JLink
sudo apt install -y JLink_Linux_V872_x86_64.deb

# Install ninja and meson
sudo apt install ninja-build meson -y
