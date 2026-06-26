# 
## Start
Download dnsmasq
```bash
sudo apt update && sudo apt install dnsmasq -y
```

The google vm have a process occupying port 53 already, so we forward message of port 53 to port 5353
```bash
sudo iptables -t nat -A PREROUTING -i ens4 -p udp --dport 53 -j REDIRECT --to-ports 5353
```

## How to configurate dnsmasq
In the vm /etc/dnsmasq.conf

```bash
port=5353 
interface=ens4 
bind-interfaces 
addn-hosts=/etc/dnsmasq-nds.hosts
server=8.8.8.8
```

Notice "interface=ens4" is known from running

```bash
ip route get 8.8.8.8
```

now we need to hijact the NDS requests
```bash
# copy the hijact logic to /usr/local/bin/ 
sudo cp dns_sinkhole/scripts/update-nds-ip.sh /usr/local/bin/update-nds-ip.sh
sudo chmod +x /usr/local/bin/update-nds-ip.sh

sudo mkdir -p /etc/systemd/system/dnsmasq.service.d/

echo -e "[Service]\nExecStartPre=+/usr/local/bin/update-nds-ip.sh" | sudo tee /etc/systemd/system/dnsmasq.service.d/override.conf

sudo systemctl daemon-reload
```

## How to make dnsmasq start by itself
```bash
sudo systemctl restart dnsmasq 
sudo systemctl enable dnsmasq 
```

and the port redirect logic add to .bashrc so it sourced during startup
```bash
# add this to .bashrc
sudo iptables -t nat -A PREROUTING -i ens4 -p udp --dport 53 -j REDIRECT --to-ports 5353
```

## Testing
On VM, run 
```bash
sudo ss -lntup | grep 5353
sudo tcpdump -nni any udp port 53
```
On Macbook run
```bash
nc -zu -v -w 2 <VM_EXTERNAL_IP> 53
```