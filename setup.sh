sudo apt install -y git zsh snapd retroarch device-tree-compiler python3 python3-spidev python3-gpiozero wget ca-certificates gcc python3-pygame libc6-dev
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
sudo chsh -s (which zsh)
curl -LsSf https://astral.sh/uv/install.sh | sh

curl --output-dir -O scripts 
