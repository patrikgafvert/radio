#.SILENT:
SHELL:=$(shell which bash)
ROOT_DIR=$(dir $(realpath $(lastword $(MAKEFILE_LIST))))
DOWNLOADCMD=curl -s -O -L -k
ALPINE_VER=3.22
ALPINE_FILE=alpine-rpi-$(ALPINE_VER).1-aarch64.tar.gz
ALPINE_URL=https://dl-cdn.alpinelinux.org/alpine/v$(ALPINE_VER)/releases/aarch64/$(ALPINE_FILE)
ALPINE_DIR=$(ROOT_DIR)alpine-$(ALPINE_VER)/
TAR_DIR=$(ROOT_DIR)
DISCS:=$(shell lsblk -O -J | jq -r '[.blockdevices[] | select(.type=="disk" and .tran=="usb")] | to_entries[] | [.key+1,.value.path,.value.vendor,.value.model,.value.size] | @csv ')

define REPO
/media/mmcblk0p1/apks
https://ftp.sunet.se/mirror/alpinelinux.org/v3.22/main
https://ftp.sunet.se/mirror/alpinelinux.org/v3.22/community
endef

define AUTOSCRIPT
#!/bin/sh
exec > /dev/tty1 2>&1

trap 'reboot' EXIT INT

rm -f /etc/local.d/auto-setup-alpine.start
rm -f /etc/runlevels/default/local

timeout 300 setup-alpine -ef /etc/auto-setup-alpine/answers

rm -rf /etc/auto-setup-alpine

apk update
apk upgrade

apk add wpa_supplicant lighttpd alsa-utils bluez-alsa ffmpeg terminus-font

cat << "EOF" > /etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
EOF

rc-service wpa_supplicant start
until [ -e "/var/run/wpa_supplicant/wlan0" ]; do :; done

wpa_cli set country SE
wpa_cli add_network 0
wpa_cli set_network 0 ssid '"COMHEM_61a6ad-5G"'
wpa_cli set_network 0 psk '"uzyvdzgt"'
wpa_cli enable_network 0
wpa_cli select_network 0
wpa_cli save_config

rc-update add wpa_supplicant boot
rc-update add wpa_cli boot
rc-update del crond default
rc-update del syslog boot

sed -i 's|\(consolefont="\)[^"]*\(".*\)|\1ter-128n.psf.gz\2|' /etc/conf.d/consolefont
rc-update add consolefont boot

echo "radio:radio" | chpasswd
echo "root:radio" | chpasswd

cat << "EOF" > /etc/doas.d/site.conf
permit nopass :wheel
permit nopass keepenv root
EOF

sed -i 's/#\(PermitRootLogin \).*/\1yes/' /etc/ssh/sshd_config

cat << "EOF" >> /etc/modules
snd-bcm2835
EOF

modprobe snd-bcm2835
rc-service alsa start
amixer -M -D default:CARD=Headphones sset PCM 80%
amixer -M -D default:CARD=b1 sset PCM 80%
rc-service alsa save
rc-update add alsa
rc-update add bluealsa

lbu add /var/lib/alsa/asound.state
lbu include /var/lib/bluetooth

cat << "EOF" > /etc/lighttpd/lighttpd.conf
server.document-root = "/home/radio"
server.port = 80
server.username = "radio"
server.groupname = "radio"
server.pid-file = "/run/lighttpd.pid"
mimetype.assign = (".html" => "text/html",".txt" => "text/plain",".jpg" => "image/jpeg",".png" => "image/png")
server.modules = ("mod_cgi")
index-file.names = ("index.html")
cgi.assign += (".sh" => "/bin/ash")
EOF
rc-update add lighttpd default

cat << "EOF" > /home/radio/db_dump.sh
#!/usr/bin/sh
sqlite3 radio_channels.db 'SELECT "group", "logo_url","name","genre","description","url" from channels order by "group","name";' -json > radio_channels.json
EOF
chmod +x /home/radio/db_dump.sh

cat << "EOF" > /home/radio/import.py
#!/usr/bin/env python3

import sqlite3
import json

# Läs JSON
with open("radio_channels.json", "r", encoding="utf-8") as f:
    data = json.load(f)

if not data:
    raise ValueError("JSON-filen är tom.")

conn = sqlite3.connect("radio_channels.db")
cursor = conn.cursor()

# === Hämta fältnamn ===
fields = data[0].keys()

# === Skapa tabell dynamiskt, med fältnamn inom "" ===
columns_sql = ', '.join([f'"{field}" TEXT' for field in fields])
create_sql = f'CREATE TABLE IF NOT EXISTS channels ({columns_sql})'
cursor.execute(create_sql)

# === INSERT-sats: samma sak här, fältnamn inom "" ===
quoted_fields = ', '.join([f'"{field}"' for field in fields])
placeholders = ', '.join([f':{field}' for field in fields])
insert_sql = f'INSERT INTO channels ({quoted_fields}) VALUES ({placeholders})'

# === Lägg in data ===
cursor.executemany(insert_sql, data)

conn.commit()
conn.close()

print("Importen är klar.")
EOF
chmod +x /home/radio/import.py

cat << "EOF" > /home/radio/index.html
<!DOCTYPE html>
<html lang="sv">
<head>
  <meta charset="UTF-8">
  <title>Radio</title>
  <style>
    body {
      background-color: #121212;
      color: #e0e0e0;
      font-family: Arial, sans-serif;
      margin-bottom: 70px;
    }

    mark {
      background-color: #ffc107;
      color: #121212;
      padding: 0 2px;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 20px;
      font-size: 1em;
      empty-cells: hide;
    }

    th, td {
      border: 1px solid #444;
      padding: 4px 4px;
      text-align: left;
      vertical-align: middle;
    }

    th {
      background-color: #1e1e1e;
    }

    tr:nth-child(even) { background-color: #2a2a2a; }
    tr:nth-child(odd) { background-color: #1a1a1a; }

    tr.clickable-row { cursor: pointer; transition: background-color 0.2s ease; }
    tr.clickable-row:hover { background-color: #333333; }

    tr.selected-row {
      background-color: #004d40;
      color: #e0e0e0;
      font-weight: bold;
    }

    td img.logo {
      width: 40px;
      height: 24px;
      object-fit: contain;
      border-radius: 5px;
      display: block;
    }

    tr.group-header td {
      background-color: #3a3a3a;
      color: #f0f0f0;
      font-weight: bold;
      text-align: center;
      padding: 10px;
      border-bottom: 2px solid #555;
      cursor: default;
    }

    #log {
      position: fixed;
      bottom: 0;
      left: 0;
      width: 100%;
      background-color: #2a2a2a;
      border-top: 1px solid #444;
      padding: 10px;
      font-size: 1em;
      color: #aaa;
      box-sizing: border-box;
      z-index: 1000;
      display: flex;
      align-items: center;
      justify-content: flex-start;
      flex-wrap: wrap;
      gap: 10px;
    }

    #log.loading { color: #ffffff; }
    #log.success { color: #aaffee; }
    #log.error { color: #ff8888; }

    #searchInput {
      margin-top: 20px;
      font-size: 1em;
      padding: 10px;
      width: 100%;
      box-sizing: border-box;
      background-color: #1e1e1e;
      color: #e0e0e0;
      border: 1px solid #444;
      border-radius: 5px;
    }

    #customUrlContainer {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-top: 20px;
    }

    #customUrlInput {
      flex: 1 1 auto;
      max-width: 90%;
      padding: 10px;
      font-size: 1em;
      box-sizing: border-box;
      background-color: #1e1e1e;
      color: #e0e0e0;
      border: 1px solid #444;
      border-radius: 5px;
    }

    #playCustomUrlButton {
      margin-left: auto;
      flex-shrink: 0;
      white-space: nowrap;
      padding: 10px 15px;
      font-size: 1em;
      background-color: #0056b3;
      color: white;
      border: none;
      border-radius: 5px;
      cursor: pointer;
      transition: background-color 0.2s ease;
      height: 100%;
    }

    #playCustomUrlButton:hover {
      background-color: #007bff;
    }

    .output-buttons {
      gap: 10px;
      display: flex;
    }

    .output-buttons button {
      padding: 10px 15px;
      font-size: 1em;
      background-color: #0056b3;
      color: white;
      border: none;
      border-radius: 5px;
      cursor: pointer;
      transition: background-color 0.2s ease;
    }

    .output-buttons button:hover {
      background-color: #007bff;
    }

    .output-buttons button.active {
      background-color: #007bff;
    }

    #outputOff {
      background-color: #c82333;
    }

    #outputOff:hover {
      background-color: #dc3545;
    }

    .output-buttons button.active-off {
      background-color: #dc3545;
    }

    #log-message {
      flex-grow: 1;
    }
  </style>
</head>
<body>
<input type="text" id="searchInput" placeholder="Sök kanal...">

<div id="customUrlContainer">
    <input type="text" id="customUrlInput" placeholder="Ange egen URL...">
    <button id="playCustomUrlButton" aria-label="Spela egen URL">Spela URL</button>
</div>

<div id="table-container">Laddar data...</div>

<div id="log">
    <div id="log-message"></div>
    <div class="output-buttons">
        <button id="outputJack" aria-label="Välj ljudutgång till Jack">Output: Jack</button>
        <button id="outputHDMI" aria-label="Välj ljudutgång till HDMI">Output: HDMI</button>
        <button id="outputBluetooth" aria-label="Välj ljudutgång till Bluetooth">Output: Bluetooth</button>
        <button id="outputOff" aria-label="Stäng av ljud">Stäng av</button>
    </div>
</div>

<script>
  function setCookie(key, value, days = 7) {
      const d = new Date();
      d.setTime(d.getTime() + (days * 24 * 60 * 60 * 1000));
      const expires = "expires=" + d.toUTCString();
      document.cookie = `$${key}=$${encodeURIComponent(value)};$${expires};path=/;SameSite=Lax`;
  }

  function getCookie(key) {
      const name = key + "=";
      const decodedCookie = decodeURIComponent(document.cookie);
      const ca = decodedCookie.split(';');
      for(let i = 0; i <ca.length; i++) {
          let c = ca[i];
          while (c.charAt(0) === ' ') {
              c = c.substring(1);
          }
          if (c.indexOf(name) === 0) {
              return c.substring(name.length, c.length);
          }
      }
      return "";
  }


  function clearSelectedRows() {
      const currentlySelected = document.querySelector('tr.selected-row');
      if (currentlySelected) {
          currentlySelected.classList.remove('selected-row');
      }
  }

  function highlightSelectedRowFromStorage() {
      const storedChannelUrl = getCookie('selectedChannelUrl');
      if (!storedChannelUrl) return;

      const clickableRows = document.querySelectorAll('tr[data-url]');
      clickableRows.forEach(row => {
          if (row.dataset.url === storedChannelUrl) {
              row.classList.add('selected-row');
          }
      });
  }

  let currentOutput = getCookie('selectedOutput') || 'jack';

  function updateButtonStyles() {
      document.querySelectorAll('.output-buttons button').forEach(btn => {
          btn.classList.remove('active', 'active-off');
      });

      if (currentOutput !== 'off') {
          const btn = document.getElementById('output' + currentOutput.charAt(0).toUpperCase() + currentOutput.slice(1));
          if (btn) btn.classList.add('active');
      } else {
          const offBtn = document.getElementById('outputOff');
          if (offBtn) offBtn.classList.add('active-off');
      }
  }

  async function sendCgiRequest(channelUrl, outputDevice) {
      const logElement = document.getElementById('log-message');
      let fullUrl = `$${pre_url}url=$${encodeURIComponent(channelUrl)}&output=$${outputDevice}`;

      if (!channelUrl) {
          fullUrl = `$${pre_url}url=&output=$${outputDevice}`;
          logElement.textContent = `Skickar begäran för att stänga av... URL: $${fullUrl}`;
      } else {
          logElement.textContent = `Skickar begäran... URL: $${fullUrl}`;
      }

      document.getElementById('log').className = 'loading';

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 15000);

      try {
          const response = await fetch(fullUrl, { signal: controller.signal });
          if (!response.ok) throw new Error(`HTTP-fel: $${response.status}`);

          const responseText = await response.text();
          logElement.textContent = `Kanal/Utgång ändrad! Svar: $${responseText}`;
          document.getElementById('log').className = 'success';
      } catch (error) {
          logElement.textContent = error.name === 'AbortError' ? 'Tidsgräns överskreds.' : `Fel: $${error.message}`;
          document.getElementById('log').className = 'error';
      } finally {
          clearTimeout(timeoutId);
      }
      return fullUrl;
  }

  async function handleRowClick(event) {
      const clickedRow = event.currentTarget;
      const channelUrl = clickedRow.dataset.url;
      const customUrlInput = document.getElementById('customUrlInput');

      clearSelectedRows();
      clickedRow.classList.add('selected-row');

      await sendCgiRequest(channelUrl, currentOutput);
      setCookie('selectedChannelUrl', channelUrl);
      setCookie('selectedOutput', currentOutput);
      setCookie('lastCustomUrl', channelUrl);
      customUrlInput.value = channelUrl;
      updateButtonStyles();
  }

  async function handlePlayCustomUrl() {
      const customUrlInput = document.getElementById('customUrlInput');
      const customUrl = customUrlInput.value.trim();

      if (customUrl) {
          clearSelectedRows();
          await sendCgiRequest(customUrl, currentOutput);
          setCookie('selectedChannelUrl', customUrl);
          setCookie('selectedOutput', currentOutput);
          setCookie('lastCustomUrl', customUrl);
          updateButtonStyles();
      } else {
          document.getElementById('log-message').textContent = 'Vänligen ange en URL i fältet för egen URL.';
          document.getElementById('log').className = 'error';
      }
  }

  async function handleOffClick() {
      clearSelectedRows();
      await sendCgiRequest("", currentOutput);
      document.getElementById('customUrlInput').value = "";
      setCookie('selectedChannelUrl', "");
      setCookie('lastCustomUrl', "");
      currentOutput = 'off';
      setCookie('selectedOutput', currentOutput);
      updateButtonStyles();
  }

  async function loadAndBuildTable(jsonUrl, targetDivId) {
      try {
          const response = await fetch(jsonUrl);
          if (!response.ok) throw new Error(`HTTP-fel: $${response.status}`);
          const data = await response.json();

          data.sort((a, b) => {
              const groupCompare = a.group.localeCompare(b.group);
              return groupCompare !== 0 ? groupCompare : a.name.localeCompare(b.name);
          });

          const table = document.createElement('table');
          const thead = document.createElement('thead');
          const tbody = document.createElement('tbody');

          const columns = ['logo_url', 'name', 'genre', 'description'];
          const headerRow = document.createElement('tr');
          columns.forEach(key => {
              const th = document.createElement('th');
              th.textContent = key === 'logo_url' ? '' :
                  key === 'name' ? 'Kanalnamn' :
                  key === 'genre' ? 'Genre' : 'Beskrivning';
              headerRow.appendChild(th);
          });
          thead.appendChild(headerRow);
          table.appendChild(thead);

          let currentGroup = null;
          data.forEach(item => {
              if (item.group && item.group !== currentGroup) {
                  const groupHeaderRow = document.createElement('tr');
                  groupHeaderRow.classList.add('group-header');
                  const groupHeaderCell = document.createElement('td');
                  groupHeaderCell.textContent = item.group;
                  groupHeaderCell.colSpan = columns.length;
                  groupHeaderRow.appendChild(groupHeaderCell);
                  tbody.appendChild(groupHeaderRow);
                  currentGroup = item.group;
              }

              const row = document.createElement('tr');
              row.classList.add('clickable-row');
              row.dataset.url = item.url;
              row.addEventListener('click', handleRowClick);

              columns.forEach(key => {
                  const td = document.createElement('td');
                  if (key === 'logo_url') {
                      const img = document.createElement('img');
                      img.src = item[key] || '';
                      img.alt = `Logotyp för $${item.name || ''}`;
                      img.classList.add('logo');
                      td.appendChild(img);
                  } else {
                      td.textContent = item[key] || '';
                  }
                  row.appendChild(td);
              });
              tbody.appendChild(row);
          });

          table.appendChild(tbody);
          const container = document.getElementById(targetDivId);
          container.innerHTML = '';
          container.appendChild(table);
          highlightSelectedRowFromStorage();
          updateButtonStyles();

          const lastCustomUrl = getCookie('lastCustomUrl');
          if (lastCustomUrl) {
              document.getElementById('customUrlInput').value = lastCustomUrl;
          }

      } catch (error) {
          document.getElementById(targetDivId).innerText = `Fel vid inläsning: $${error.message}`;
      }
  }

  function debounce(func, delay) {
      let timeout;
      return function(...args) {
          clearTimeout(timeout);
          timeout = setTimeout(() => func.apply(this, args), delay);
      };
  }

  function handleSearch() {
      const searchTerm = document.getElementById('searchInput').value.toLowerCase();
      const tbody = document.querySelector('#table-container table tbody');
      const rows = Array.from(tbody.children);

      let currentGroupHeader = null;
      let groupHasVisibleRows = false;

      rows.forEach(row => {
          if (row.classList.contains('group-header')) {
              if (currentGroupHeader && !groupHasVisibleRows) {
                  currentGroupHeader.style.display = 'none';
              } else if (currentGroupHeader) {
                  currentGroupHeader.style.display = '';
              }
              currentGroupHeader = row;
              groupHasVisibleRows = false;
              return;
          }

          const cells = Array.from(row.querySelectorAll('td'));
          let rowMatches = false;

          cells.forEach(cell => {
              const originalText = cell.textContent || '';
              cell.innerHTML = originalText;

              if (searchTerm && originalText.toLowerCase().includes(searchTerm)) {
                  rowMatches = true;
                  const regex = new RegExp(`($${searchTerm})`, 'gi');
                  cell.innerHTML = originalText.replace(regex, '<mark>$$1</mark>');
              }
          });

          if (!searchTerm) {
              row.style.display = '';
              groupHasVisibleRows = true;
          } else if (rowMatches) {
              row.style.display = '';
              groupHasVisibleRows = true;
          } else {
              row.style.display = 'none';
          }
      });

      if (currentGroupHeader && !groupHasVisibleRows) {
          currentGroupHeader.style.display = 'none';
      } else if (currentGroupHeader) {
          currentGroupHeader.style.display = '';
      }
  }

  document.getElementById('searchInput').addEventListener('input', debounce(handleSearch, 200));

  document.addEventListener('keydown', function(event) {
      if (event.key === 'Escape') {
          event.preventDefault();
          location.reload();
      }
  });

  const pre_url = "/radio.sh?";
  loadAndBuildTable('radio_channels.json', 'table-container');

  document.querySelector('.output-buttons').addEventListener('click', function(event) {
      const clickedButton = event.target;
      if (clickedButton.tagName === 'BUTTON' && clickedButton.id !== 'outputOff') {
          let newOutput = '';
          switch (clickedButton.id) {
              case 'outputJack': newOutput = 'jack'; break;
              case 'outputHDMI': newOutput = 'hdmi'; break;
              case 'outputBluetooth': newOutput = 'bluetooth'; break;
              default: return;
          }

          currentOutput = newOutput;
          setCookie('selectedOutput', currentOutput);
          updateButtonStyles();
          document.getElementById('log-message').textContent = `Utgång inställd till $${newOutput.charAt(0).toUpperCase() + newOutput.slice(1)}.`;
      }
  });

  document.getElementById('outputOff').addEventListener('click', handleOffClick);
  document.getElementById('playCustomUrlButton').addEventListener('click', handlePlayCustomUrl);
</script>
</body>
</html>
EOF

cat << "EOF" | base64 -d | zcat > /home/radio/radio_channels.json
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
EOF

cat << "EOF" > /home/radio/radio.sh
#!/bin/ash
echo "HTTP/1.1 200 OK"
echo "Content-Type: text/plain; charset=UTF-8"
echo ""

# Funktion för att avkoda URL-strängar
urldecode() {
    local url_encoded="$${1//+/ }"
    printf '%b' "$${url_encoded//%/\\x}"
}

if [ -z "$$QUERY_STRING" ]; then
    echo "Fel: Ingen QUERY_STRING hittades."
    exit 1
fi

CHANNEL_URL=""
OUTPUT_DEVICE=""

OLDIFS="$$IFS"
IFS='&'
set -- $$QUERY_STRING
IFS="$$OLDIFS"

for param in "$$@"; do
    case "$$param" in
        url=*)
            # Avkoda URL:en här
            CHANNEL_URL=$$(urldecode "$${param#url=}")
            ;;
        output=*)
            OUTPUT_DEVICE="$${param#output=}"
            ;;
    esac
done

if [ -z "$$OUTPUT_DEVICE" ]; then
    echo "Fel: 'output' parameter saknas eller är tom."
    exit 1
fi

if [ -z "$$CHANNEL_URL" ]; then
    echo "Ingen kanal vald. Stänger av strömmen/radion."
    pkill -KILL ffmpeg
else
    echo "Kanal: $$CHANNEL_URL"
    echo "Utgång: $$OUTPUT_DEVICE"
    if [ "$$OUTPUT_DEVICE" == "jack" ]; then
      pkill -KILL ffmpeg
      nohup ffmpeg -loglevel quiet -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 2 -i "$$CHANNEL_URL" -f alsa default:CARD=Headphones > /dev/null 2>&1 &
    elif [ "$$OUTPUT_DEVICE" == "hdmi" ]; then
      pkill -KILL ffmpeg
      nohup ffmpeg -loglevel quiet -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 2 -i "$$CHANNEL_URL" -f alsa default:CARD=b1 > /dev/null 2>&1 &
    elif [ "$$OUTPUT_DEVICE" == "bluetooth" ]; then
      pkill -KILL ffmpeg
      nohup ffmpeg -loglevel quiet -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 2 -i "$$CHANNEL_URL" -f alsa bluealsa > /dev/null 2>&1 &
    fi
fi

exit 0
EOF
chmod +x /home/radio/radio.sh

sed -i 's/^#alsactl_opts/alsactl_opts/' /etc/conf.d/alsa

#cat << "EOF" > /etc/local.d/radio.start
#!/bin/ash
#doas -u radio ash -c 'QUERY_STRING="url=https://live1.sr.se/p4sth-aac-320&output=jack" /home/radio/radio.sh'
#EOF
#chmod +x /etc/local.d/radio.start
#rc-update add local

cat << "EOF" | base64 -d | zcat > /home/radio/favicon.ico
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
EOF

sed -i '/^tty[2-6]/d' /etc/inittab

echo -n > /etc/motd

lbu ci -dv
endef

define ANSWERS
KEYMAPOPTS="se se"
HOSTNAMEOPTS="radio"
DEVDOPTS="mdev"
INTERFACESOPTS="auto lo
iface lo inet loopback

allow-hotplug eth0
auto eth0
iface eth0 inet dhcp

allow-hotplug wlan0
auto wlan0
iface wlan0 inet dhcp

hostname radio
"
TIMEZONEOPTS="Europe/Stockholm"
PROXYOPTS="none"
APKREPOSOPTS="/media/mmcblk0p1/apks
https://ftp.sunet.se/mirror/alpinelinux.org/v3.22/main
https://ftp.sunet.se/mirror/alpinelinux.org/v3.22/community
"
USEROPTS="-a -u -g audio,input,video,netdev radio"
SSHDOPTS="openssh"
NTPOPTS="busybox"
DISKOPTS="none"
LBUOPTS="mmcblk0p1"
APKCACHEOPTS="/media/mmcblk0p1/cache"
endef

export REPO ANSWERS AUTOSCRIPT

all:	fetch-alpine make_ovl make_img

fetch-alpine:
	mkdir -p $(ALPINE_DIR)
	if [ ! -f "$(ALPINE_FILE)" ]; then $(DOWNLOADCMD) $(ALPINE_URL); fi
	cd $(ALPINE_DIR) && tar -xf ../$(ALPINE_FILE)

make_img:
	dd if=/dev/zero of=radio.img bs=1M count=1024
	echo -e "n\np\n1\n\n\nt\nc\na\nw\n" | fdisk radio.img
	mformat -v RADIO -i radio.img@@$$((512*2048)) -F ::
	mcopy -v -i radio.img@@$$((512*2048)) -s alpine-3.22/* ::
	7z a radio radio.img

make_ovl:
	mkdir -p $(ROOT_DIR)ovl/etc/apk
	mkdir -p $(ROOT_DIR)ovl/etc/local.d
	mkdir -p $(ROOT_DIR)ovl/etc/runlevels/default
	mkdir -p $(ROOT_DIR)ovl/etc/auto-setup-alpine
	
	touch $(ROOT_DIR)ovl/etc/.default_boot_services

	ln -sf /etc/init.d/local $(ROOT_DIR)ovl/etc/runlevels/default
	
	printf "%s\n" "$${REPO}" > $(ROOT_DIR)ovl/etc/apk/repositories
	printf "%s\n" "$${ANSWERS}" > $(ROOT_DIR)ovl/etc/auto-setup-alpine/answers
	printf "%s\n" "$${AUTOSCRIPT}" > $(ROOT_DIR)ovl/etc/local.d/auto-setup-alpine.start

	chmod 755 $(ROOT_DIR)ovl/etc/local.d/auto-setup-alpine.start

	cd $(ROOT_DIR) && tar --owner=0 --group=0 -czf $(ALPINE_DIR)localhost.apkovl.tar.gz -C ovl .
	cd $(ALPINE_DIR) && echo -e "disable_audio_dither=1\ndisable_overscan=1\ndtparam=audio=on" > usercfg.txt
