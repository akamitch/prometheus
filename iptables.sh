# Очистка только таблицы mangle (Docker обычно не использует её)
iptables -t mangle -F
iptables -t mangle -X
iptables -t mangle -I OUTPUT -j ACCEPT
iptables -t mangle -I PREROUTING -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t mangle -I PREROUTING -s 62.106.76.0/24 -j ACCEPT -m comment --comment "Nick local"
iptables -t mangle -I PREROUTING -s 186.22.19.0/24 -j ACCEPT -m comment --comment "Mitch local"
iptables -t mangle -I PREROUTING -s 94.130.78.127/32 -j ACCEPT -m comment --comment "vpn europe"
iptables -t mangle -I PREROUTING -s 158.69.184.200/32 -j ACCEPT -m comment --comment "vpn canada"
iptables -t mangle -I PREROUTING -s 178.162.199.12/32 -j ACCEPT -m comment --comment "vpn aka-root back"
iptables -t mangle -I PREROUTING -p tcp -m tcp --dport 80 -j ACCEPT
iptables -t mangle -I PREROUTING -p tcp -m tcp --dport 443 -j ACCEPT
iptables -t mangle -I PREROUTING -p tcp -m tcp --dport 5000 -j ACCEPT -m comment --comment "gonka"
iptables -t mangle -I PREROUTING -p tcp -m tcp --dport 26657 -j ACCEPT -m comment --comment "gonka"
iptables -t mangle -I PREROUTING -p tcp -m tcp --dport 8000 -j ACCEPT -m comment --comment "gonka"
iptables -t mangle -A PREROUTING -i eth0 -j DROP


