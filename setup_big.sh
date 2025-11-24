cp /home/ubuntu/prometheus/authorized_keys /home/ubuntu/.ssh/authorized_keys
#sudo sh /home/ubuntu/prometheus/install_docker.sh
cd /home/ubuntu/prometheus && sudo docker compose up -d
sudo sh /home/ubuntu/prometheus/iptables.sh
sudo apt-get install -y iptables-persistent
sudo iptables-save -t mangle | sudo tee /etc/iptables/rules.v4 > /dev/null
sudo mkdir -p /mnt/ssd 
sudo chown -R ubuntu:ubuntu /mnt/ssd
cd /mnt/ssd && git clone https://github.com/gonka-ai/gonka.git -b main
cp /home/ubuntu/prometheus/node-config-big.json /mnt/ssd/gonka/deploy/join/node-config.json
cd /mnt/ssd/gonka/deploy/join
sudo mkdir /mnt/ssd/hf 
sudo chown ubuntu:ubuntu /mnt/ssd/hf
export HF_HOME=/mnt/ssd/hf 
sudo apt update 
sudo apt install -y pipx 
pipx ensurepath 
pipx install huggingface_hub
/home/ubuntu/.local/bin/hf download Qwen/Qwen3-235B-A22B-Instruct-2507-FP8


