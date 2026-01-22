#!/bin/bash

# Очистка только таблицы mangle (Docker обычно не использует её)
iptables -t mangle -F
iptables -t mangle -X

# === OUTPUT: исходящие соединения ===
# Разрешить установленные соединения (ВАЖНО: первым!)
iptables -t mangle -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Разрешить локальный интерфейс
iptables -t mangle -A OUTPUT -o lo -j ACCEPT

# DNS (необходимо для резолвинга имён)
iptables -t mangle -A OUTPUT -p udp --dport 53 -j ACCEPT -m comment --comment "DNS"
iptables -t mangle -A OUTPUT -p tcp --dport 53 -j ACCEPT -m comment --comment "DNS"

# Разрешённые IP для исходящих соединений, наши ноды
iptables -t mangle -A OUTPUT -d 195.242.13.239 -j ACCEPT -m comment --comment "node2.gonka.ai"
iptables -t mangle -A OUTPUT -d 89.169.103.180 -j ACCEPT -m comment --comment "node1.gonka.ai"
iptables -t mangle -A OUTPUT -d 195.242.10.196 -j ACCEPT -m comment --comment "node3.gonka.ai"

iptables -t mangle -A OUTPUT -d 85.234.79.243 -j ACCEPT -m comment --comment "tower"
iptables -t mangle -A OUTPUT -d 85.234.66.95 -j ACCEPT -m comment --comment "mordor"
iptables -t mangle -A OUTPUT -d 85.234.66.129 -j ACCEPT -m comment --comment "prime"
iptables -t mangle -A OUTPUT -d 85.234.66.223 -j ACCEPT -m comment --comment "quatro"
iptables -t mangle -A OUTPUT -d 85.234.66.191 -j ACCEPT -m comment --comment "rock"
iptables -t mangle -A OUTPUT -d 85.234.66.219 -j ACCEPT -m comment --comment "bingo"

# Разрешить Docker интерфейсы (чтобы не сломать контейнеры)
iptables -t mangle -A OUTPUT -o docker0 -j ACCEPT -m comment --comment "Docker bridge"
iptables -t mangle -A OUTPUT -o br-+ -j ACCEPT -m comment --comment "Docker networks"

# Блокировка всего остального исходящего трафика
iptables -t mangle -A OUTPUT -j DROP

# === PREROUTING: входящие соединения ===
# Разрешить установленные соединения
iptables -t mangle -A PREROUTING -m state --state ESTABLISHED,RELATED -j ACCEPT

# Разрешённые подсети/IP для входящих соединений
iptables -t mangle -A PREROUTING -s 62.106.76.0/24 -j ACCEPT -m comment --comment "Nick local"
iptables -t mangle -A PREROUTING -s 186.22.19.0/24 -j ACCEPT -m comment --comment "Mitch local"
iptables -t mangle -A PREROUTING -s 94.130.78.127/32 -j ACCEPT -m comment --comment "vpn europe"
iptables -t mangle -A PREROUTING -s 158.69.184.200/32 -j ACCEPT -m comment --comment "vpn canada"
iptables -t mangle -A PREROUTING -s 178.162.199.12/32 -j ACCEPT -m comment --comment "vpn aka-root back"


# Разрешённые порты
#iptables -t mangle -A PREROUTING -p tcp -m tcp --dport 80 -j ACCEPT
#iptables -t mangle -A PREROUTING -p tcp -m tcp --dport 443 -j ACCEPT
#iptables -t mangle -A PREROUTING -p tcp -m tcp --dport 5000 -j ACCEPT -m comment --comment "gonka"
#iptables -t mangle -A PREROUTING -p tcp -m tcp --dport 26657 -j ACCEPT -m comment --comment "gonka"
#iptables -t mangle -A PREROUTING -p tcp -m tcp --dport 8000 -j ACCEPT -m comment --comment "gonka"

# входящие тоже только от разрешенных нод
iptables -t mangle -A PREROUTING -s 195.242.13.239 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "node2.gonka.ai"
iptables -t mangle -A PREROUTING -s 89.169.103.180 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "node1.gonka.ai"
iptables -t mangle -A PREROUTING -s 195.242.10.196 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "node3.gonka.ai"
iptables -t mangle -A PREROUTING -s 85.234.79.243 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "tower"
iptables -t mangle -A PREROUTING -s 85.234.66.95 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "mordor"
iptables -t mangle -A PREROUTING -s 85.234.66.129 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "prime"
iptables -t mangle -A PREROUTING -s 85.234.66.223 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "quatro"
iptables -t mangle -A PREROUTING -s 85.234.66.191 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "rock"
iptables -t mangle -A PREROUTING -s 85.234.66.219 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "bingo"
iptables -t mangle -A PREROUTING -s 85.234.66.27 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "aragorn"
iptables -t mangle -A PREROUTING -s 93.119.168.209 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "phoenix"
iptables -t mangle -A PREROUTING -s 176.56.203.151 -p tcp -m multiport --dports 5000,26657,8000 -j ACCEPT -m comment --comment "freya"


# Блокировка всего остального на интерфейсе
iptables -t mangle -A PREROUTING -i eth0 -j DROP

echo "Правила iptables mangle применены успешно"

# sudo iptables -t mangle -L OUTPUT -n --line-numbers
# чтобы найти правило, когда его пора удалить
# sudo iptables -t mangle -D OUTPUT 16