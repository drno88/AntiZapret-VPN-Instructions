#!/bin/bash
set -e

#
# Установка AmneziaWG-Go (amneziawg-go, userspace)
#
# AntiZapret : 10.29.9.0/24, порт 53443
# Full VPN   : 10.28.9.0/24, порт 53080
#
# Запуск: bash setup-amneziawg2.sh
#
# Справка по параметрам:
#   https://publish.obsidian.md/zapret/amnezia-2-0/reference
#   https://github.com/amnezia-vpn/amneziawg-go
#   https://github.com/amnezia-vpn/amneziawg-tools
#

export LC_ALL=C

handle_error() {
	echo -e "\e[1;31mОшибка на строке $1: $2\e[0m"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# Проверка необходимости перезагрузить
if [[ -f /var/run/reboot-required ]] || pidof apt apt-get dpkg unattended-upgrades >/dev/null 2>&1; then
	echo 'Error: You need to reboot this server before installation!'
	exit 2
fi

# Проверка прав root
if [[ "$EUID" -ne 0 ]]; then
	echo 'Error: You need to run this as root!'
	exit 3
fi

# Проверка на OpenVZ и LXC
if [[ "$(systemd-detect-virt)" == 'openvz' || "$(systemd-detect-virt)" == 'lxc' ]]; then
	echo 'Error: OpenVZ and LXC are not supported!'
	exit 4
fi

# Проверка версии системы
OS="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
VERSION="$(lsb_release -rs | cut -d '.' -f1)"

if [[ "$OS" == 'debian' ]]; then
	if (( VERSION < 12 )); then
		echo "Error: Debian $VERSION is not supported! Minimal supported version is 12"
		exit 5
	fi
elif [[ "$OS" == 'ubuntu' ]]; then
	if (( VERSION < 22 )); then
		echo "Error: Ubuntu $VERSION is not supported! Minimal supported version is 22"
		exit 6
	fi
else
	echo "Error: Your Linux distribution ($OS) is not supported!"
	exit 7
fi

# Проверка свободного места (минимум 2Гб — нужно для сборки Go + бинарников)
if [[ $(df --output=avail / | tail -n 1) -lt $((2 * 1024 * 1024)) ]]; then
	echo 'Error: Low disk space! You need 2GB of free space!'
	exit 8
fi

# Проверка что основной антизапрет уже установлен
if [[ ! -f /root/antizapret/up.sh ]]; then
	echo 'Error: AntiZapret VPN is not installed! Run setup.sh first'
	exit 9
fi

# Проверка наличия сетевого интерфейса и IPv4-адреса
DEFAULT_INTERFACE="$(ip route get 1.2.3.4 2>/dev/null | grep -oP 'dev \K\S+')"
if [[ -z "$DEFAULT_INTERFACE" ]]; then
	echo 'Error: Default network interface not found!'
	exit 10
fi

echo
echo -e '\e[1;32mУстановка AmneziaWG-Go...\e[0m'
echo

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y git make curl

# Устанавливаем Go 1.24+, если нет или старше
NEED_GO=y
if command -v go &>/dev/null; then
	GOMINOR="$(go version | grep -oP 'go1\.\K[0-9]+')"
	[[ "$GOMINOR" -ge 24 ]] && NEED_GO=n
fi

if [[ "$NEED_GO" == 'y' ]]; then
	echo 'Устанавливаем Go...'
	GO_VER="$(curl -sf 'https://go.dev/dl/?mode=json' | grep -oP '"version":\s*"\Kgo[0-9.]+' | head -1)"
	ARCH="$(dpkg --print-architecture)"
	[[ "$ARCH" == 'arm64' ]] && GOARCH='arm64' || GOARCH='amd64'
	curl -sfL "https://dl.google.com/go/${GO_VER}.linux-${GOARCH}.tar.gz" | tar -C /usr/local -xz
	ln -sf /usr/local/go/bin/go /usr/local/bin/go
	echo "Go установлен: $(go version)"
fi

# Останавливаем сервисы перед пересборкой (чтобы не было "text file busy")
systemctl disable --now amneziawg@antizapret2 2>/dev/null || true
systemctl disable --now amneziawg@vpn2 2>/dev/null || true

# Собираем amneziawg-go
echo 'Сборка amneziawg-go...'
rm -rf /tmp/amneziawg-go
git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-go.git /tmp/amneziawg-go
cd /tmp/amneziawg-go
make
install -m 755 amneziawg-go /usr/local/bin/amneziawg-go
echo 'amneziawg-go установлен в /usr/local/bin/amneziawg-go'

# Собираем amneziawg-tools (awg, awg-quick)
echo 'Сборка amneziawg-tools...'
rm -rf /tmp/amneziawg-tools
git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools.git /tmp/amneziawg-tools
make -C /tmp/amneziawg-tools/src
make -C /tmp/amneziawg-tools/src install PREFIX=/usr/local
echo 'awg и awg-quick установлены в /usr/local/bin/'

rm -rf /tmp/amneziawg-go /tmp/amneziawg-tools

mkdir -p /etc/amneziawg/templates
chmod 700 /etc/amneziawg

# Генерируем ключи сервера (если нет)
if [[ ! -f /etc/amneziawg/key ]]; then
	echo 'Генерируем ключи сервера...'
	PRIVATE_KEY="$(awg genkey)"
	PUBLIC_KEY="$(echo "$PRIVATE_KEY" | awg pubkey)"
	printf 'PRIVATE_KEY=%s\nPUBLIC_KEY=%s\n' "$PRIVATE_KEY" "$PUBLIC_KEY" > /etc/amneziawg/key
	chmod 600 /etc/amneziawg/key
	echo 'Ключи сохранены в /etc/amneziawg/key'
fi
source /etc/amneziawg/key

# Параметры обфускации (если файл ещё не создан или устаревший — без поля I1)
if [[ ! -f /etc/amneziawg/obfs ]] || ! grep -q "^I1='" /etc/amneziawg/obfs; then
	JC=7
	JMIN=50
	JMAX=1000
	S1=68
	S2=149
	S3=32
	S4=16
	H1='471800590-471800690'
	H2='1246894907-1246895000'
	H3='923637689-923637690'
	H4='1769581055-1869581055'

	I1_TLS='<b 0x160303003a020000360303cc2cead5190af433d0345004067af01c2d93f5b12b3be32a608efd11d9e8b9560e0cd623e0c25aae0bf22195532fd8c02c000000>'
	I1_QUIC='<b 0xcc0000000108f2b74ee971b3056f088b3ae6000a58de5a004204815a27b9b61e68aeb17cd4575dc3c20de4f759f54827dae8ee806368fa5f77edd8723df36d83c607f0604901aa880869003dcfe7ea037f938192cd60cf254e0ff7a1a7adf1b88353afab896b617e30c2127af3ed035d586a1ea1d012a59e75539f7bf57f0b2639597415b4b98c0a20814d6c94b72eb7c5f56e94b82ab05a31cdae3d84b82c3294d6bc5f872c809a1b44222511b4ac8cb5f3f6ab41ce5275ed440e6ef95fb2362bb7ce9840b9c4174bcbc420983bb6721249a32f59ebc5be129007b15101eeb6dfa094fb8966b83817ec8f494f30eb547a620e04d4d378fdec8f2df1313538d2d12ddb4d7cd7ab0bcc7931f3cfd0bfa3e663ec1f614e2292119bd5d3bf49813aad947e3f09703b0d9f9c214f408a55ffabe94120b78fa6ccad53960732c41732d4f7aadd85ab7bec6d5ed544f33feaef8ef52adf337c5d6dbdcbb3d619830d3480e4eaeff48d8984cfdc0606ab215f75babd5555a78d7a890a8a6f0dd1c06d6e0bb822e6fb3db59e6c981e67539f3251be0c803eb6b48473a5e2e50ea6e1d714979d4244f92d4a0231616b78c43242fee7e6761fe1df167e3c876fff9ffde223c36542bd4c52dd2dcc08bb7c9012efb9fdd82e78815fac3fa718e901910a3fba0516e4eae2cf79b8e090d5a5fae4099247fa6ac19617ae44f1350a72f06aeace0a68ea0f335ed02af771058f2ae957c725dfa3d6a609c96729764d611697>'
	I1_SIP='<b 0x494e56495445207369703a626f624062696c6f78692e636f6d205349502f322e300d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a4d61782d466f7277617264733a2037300d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74616374203c7369703a616c69636540706333332e61746c616e74612e636f6d3e0d0a436f6e74656e742d547970653a206170706c69636174696f6e2f7364700d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>'
	I2_SIP='<b 0x5349502f322e302031303020547279696e670d0a5669613a205349502f322e302f55445020706333332e61746c616e74612e636f6d3b6272616e63683d7a39684734624b3737366173646864730d0a546f3a20426f62203c7369703a626f624062696c6f78692e636f6d3e0d0a46726f6d3a20416c696365203c7369703a616c6963654061746c616e74612e636f6d3e3b7461673d313932383330313737340d0a43616c6c2d49443a20613834623463373665363637313040706333332e61746c616e74612e636f6d0d0a435365713a2033313431353920494e564954450d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>'

	echo
	echo 'Выберите тип маскировки первого пакета (I1):'
	echo '  1) TLS ClientHello — мимикрия под HTTPS (рекомендуется)'
	echo '  2) QUIC Initial    — мимикрия под QUIC/HTTP3'
	echo '  3) SIP INVITE      — мимикрия под VoIP звонок (VoIP часто в whitelist)'
	I1_CHOICE=''
	until [[ "$I1_CHOICE" == '1' || "$I1_CHOICE" == '2' || "$I1_CHOICE" == '3' ]]; do
		read -rp 'Выбор [1]: ' -e -i 1 I1_CHOICE
	done

	if [[ "$I1_CHOICE" == '2' ]]; then
		I1="$I1_QUIC"
		I2=''
		echo 'Выбран QUIC Initial'
	elif [[ "$I1_CHOICE" == '3' ]]; then
		I1="$I1_SIP"
		I2="$I2_SIP"
		echo 'Выбран SIP INVITE'
	else
		I1="$I1_TLS"
		I2=''
		echo 'Выбран TLS ClientHello'
	fi

	cat > /etc/amneziawg/obfs << EOF
JC=$JC
JMIN=$JMIN
JMAX=$JMAX
S1=$S1
S2=$S2
S3=$S3
S4=$S4
H1=$H1
H2=$H2
H3=$H3
H4=$H4
I1='$I1'
I2='$I2'
EOF
	chmod 600 /etc/amneziawg/obfs
	echo 'Параметры обфускации сохранены в /etc/amneziawg/obfs'
fi
source /etc/amneziawg/obfs

# MTU = 1420 - S4 (S4 добавляет prefix к каждому пакету, уменьшая полезный MTU)
MTU=$((1420 - S4))

# Серверный конфиг antizapret2
# Параметры S1-S4, H1-H4 должны совпадать с клиентом — сервер тоже применяет их при приёме
# I1-I5 (signature packets) на сервере не нужны — они отправляются только initiator-ом
if [[ ! -f /etc/amneziawg/antizapret2.conf ]]; then
	cat > /etc/amneziawg/antizapret2.conf << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.29.9.1/24
ListenPort = 53443
MTU = $MTU
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
PostUp = ip link set dev %i txqueuelen 10000

EOF
	chmod 600 /etc/amneziawg/antizapret2.conf
fi

# Серверный конфиг vpn2
if [[ ! -f /etc/amneziawg/vpn2.conf ]]; then
	cat > /etc/amneziawg/vpn2.conf << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.28.9.1/24
ListenPort = 53080
MTU = $MTU
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
PostUp = ip link set dev %i txqueuelen 10000

EOF
	chmod 600 /etc/amneziawg/vpn2.conf
fi

# Клиентский шаблон antizapret2
# I1: мимикрия под TLS ClientHello (по умолчанию)
# IPS подставляется из /etc/wireguard/ips при создании клиента
cat > /etc/amneziawg/templates/antizapret2-client.conf << EOF
[Interface]
PrivateKey = \${CLIENT_PRIVATE_KEY}
Address = \${CLIENT_IP}/32
DNS = 10.29.9.1
MTU = $MTU
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
I1 = $I1
I2 = $I2
I3 =
I4 =
I5 =

[Peer]
PublicKey = $PUBLIC_KEY
PresharedKey = \${CLIENT_PRESHARED_KEY}
Endpoint = \${SERVER_HOST}:53443
AllowedIPs = 10.29.9.0/24\${IPS}
PersistentKeepalive = 15
EOF

# Клиентский шаблон vpn2
cat > /etc/amneziawg/templates/vpn2-client.conf << EOF
[Interface]
PrivateKey = \${CLIENT_PRIVATE_KEY}
Address = \${CLIENT_IP}/32
DNS = 1.1.1.1, 1.0.0.1
MTU = $MTU
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
I1 = $I1
I2 = $I2
I3 =
I4 =
I5 =

[Peer]
PublicKey = $PUBLIC_KEY
PresharedKey = \${CLIENT_PRESHARED_KEY}
Endpoint = \${SERVER_HOST}:53080
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 15
EOF

# Обновляем kresd.conf (содержит view:addr для новых подсетей 10.29.9.x / 10.28.9.x)
echo 'Обновляем kresd.conf...'
curl -sfL --connect-timeout 15 \
	'https://raw.githubusercontent.com/drno88/AntiZapret-VPN-Amnezia/refs/heads/main/setup/etc/knot-resolver/kresd.conf' \
	-o /etc/knot-resolver/kresd.conf
systemctl restart kresd@1 kresd@2
echo 'kresd перезапущен'

# Обновляем client.sh (добавлена поддержка AmneziaWG 2.0, опции 9-11)
echo 'Обновляем client.sh...'
curl -sfL --connect-timeout 15 \
	'https://raw.githubusercontent.com/drno88/AntiZapret-VPN-Amnezia/refs/heads/main/setup/root/antizapret/client.sh' \
	-o /root/antizapret/client.sh
chmod +x /root/antizapret/client.sh
echo 'client.sh обновлён'

# Systemd юнит — использует awg-quick с amneziawg-go как userspace backend
cat > /etc/systemd/system/amneziawg@.service << 'EOF'
[Unit]
Description=AmneziaWG-Go interface - %i
After=network-online.target antizapret.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
ExecStart=/usr/local/bin/awg-quick up /etc/amneziawg/%i.conf
ExecStop=/usr/local/bin/awg-quick down /etc/amneziawg/%i.conf

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable amneziawg@antizapret2
systemctl enable amneziawg@vpn2
systemctl restart amneziawg@antizapret2
systemctl restart amneziawg@vpn2

echo
echo -e '\e[1;32mAmneziaWG-Go установлен!\e[0m'
echo
echo "Публичный ключ сервера : $PUBLIC_KEY"
echo
echo 'Интерфейсы:'
echo "  antizapret2 : 10.29.9.0/24, порт 53443"
echo "  vpn2        : 10.28.9.0/24, порт 53080"
echo
echo "MTU : $MTU (1420 - S4=$S4)"
echo
echo 'Файлы:'
echo '  /etc/amneziawg/key              — ключи сервера'
echo '  /etc/amneziawg/obfs             — параметры обфускации'
echo '  /etc/amneziawg/antizapret2.conf — конфиг сервера antizapret2'
echo '  /etc/amneziawg/vpn2.conf        — конфиг сервера vpn2'
echo '  /etc/amneziawg/templates/       — шаблоны клиентских конфигов'
echo
echo 'IPS для клиентов antizapret2 берётся из /etc/wireguard/ips'
echo '(генерируется doall.sh — подставляется как AllowedIPs = 10.29.9.0/24${IPS})'
exit 0
