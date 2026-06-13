#.SILENT:
SHELL:=$(shell which bash)
ROOT_DIR=$(dir $(realpath $(lastword $(MAKEFILE_LIST))))
DOWNLOADCMD=curl -s -O -L -k
ALPINE_VER=3.24
ALPINE_FILE=alpine-rpi-$(ALPINE_VER).0-aarch64.tar.gz
ALPINE_URL=https://dl-cdn.alpinelinux.org/alpine/v$(ALPINE_VER)/releases/aarch64/$(ALPINE_FILE)
ALPINE_DIR=$(ROOT_DIR)alpine-$(ALPINE_VER)/
TAR_DIR=$(ROOT_DIR)
DISCS:=$(shell lsblk -O -J | jq -r '[.blockdevices[] | select(.type=="disk" and .tran=="usb")] | to_entries[] | [.key+1,.value.path,.value.vendor,.value.model,.value.size] | @csv ')

define REPO
/media/mmcblk0p1/apks
https://ftp.sunet.se/mirror/alpinelinux.org/v$(ALPINE_VER)/main
https://ftp.sunet.se/mirror/alpinelinux.org/v$(ALPINE_VER)/community
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

apk add wpa_supplicant lighttpd alsa-utils bluez-alsa bluez-alsa-utils ffmpeg terminus-font

cat << "EOF" > /etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
EOF

rc-service wpa_supplicant start
until [ -e "/var/run/wpa_supplicant/wlan0" ]; do :; done

wpa_cli set country SE
wpa_cli add_network 0
wpa_cli set_network 0 ssid '"South Beach Ocean Resort"'
wpa_cli set_network 0 psk '"Henning!"'
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
sed -i 's/#\(ClientAliveInterval \).*/\160/' /etc/ssh/sshd_config
sed -i 's/#\(ClientAliveCountMax \).*/\12/' /etc/ssh/sshd_config

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

sed -i 's/\(a2dp-sink\)/\1 --a2dp-volume/' /etc/conf.d/bluealsa

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
    :root {
      --bg-primary: #121212;
      --bg-secondary: #1a1a1a;
      --bg-tertiary: #1e1e1e;
      --bg-quaternary: #2a2a2a;
      --bg-hover: #333333;
      --bg-group: #3a3a3a;
      --bg-selected: #004d40;
      --border-color: #444;
      --border-dark: #555;
      --text-primary: #e0e0e0;
      --text-secondary: #aaa;
      --text-highlight: #f0f0f0;
      --accent-blue: #0056b3;
      --accent-blue-hover: #007bff;
      --accent-red: #c82333;
      --accent-red-hover: #dc3545;
      --accent-yellow: #ffc107;
      --accent-green: #aaffee;
      --spacing: 10px;
      --border-radius: 5px;
      --transition: 0.2s ease;
    }

    body {
      background-color: var(--bg-primary);
      color: var(--text-primary);
      font-family: Arial, sans-serif;
      margin-bottom: 70px;
    }

    mark {
      background-color: var(--accent-yellow);
      color: var(--bg-primary);
      padding: 0 2px;
    }

    #searchInput {
      margin-top: 20px;
      padding: var(--spacing);
      font-size: 1em;
      width: 100%;
      box-sizing: border-box;
      background-color: var(--bg-tertiary);
      color: var(--text-primary);
      border: 1px solid var(--border-color);
      border-radius: var(--border-radius);
    }

    #customUrlContainer {
      display: flex;
      align-items: center;
      gap: var(--spacing);
      margin-top: 20px;
    }

    #customUrlInput {
      flex: 1 1 auto;
      max-width: 90%;
      padding: var(--spacing);
      font-size: 1em;
      box-sizing: border-box;
      background-color: var(--bg-tertiary);
      color: var(--text-primary);
      border: 1px solid var(--border-color);
      border-radius: var(--border-radius);
    }

    #playCustomUrlButton,
    .output-buttons button,
    .bluetooth-btn {
      padding: var(--spacing) 15px;
      font-size: 1em;
      background-color: var(--accent-blue);
      color: white;
      border: none;
      border-radius: var(--border-radius);
      cursor: pointer;
      transition: background-color var(--transition);
    }

    #playCustomUrlButton {
      margin-left: auto;
      flex-shrink: 0;
      white-space: nowrap;
      height: 100%;
    }

    #playCustomUrlButton:hover,
    .output-buttons button:hover,
    .bluetooth-btn:hover {
      background-color: var(--accent-blue-hover);
    }

    #outputOff {
      background-color: var(--accent-red);
    }

    #outputOff:hover {
      background-color: var(--accent-red-hover);
    }

    .output-buttons button.active {
      background-color: var(--accent-blue-hover);
    }

    .output-buttons button.active-off {
      background-color: var(--accent-red-hover);
    }

    .output-buttons {
      gap: var(--spacing);
      display: flex;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 20px;
      font-size: 1em;
      empty-cells: hide;
    }

    th, td {
      border: 1px solid var(--border-color);
      padding: 4px;
      text-align: left;
      vertical-align: middle;
    }

    th {
      background-color: var(--bg-tertiary);
    }

    tr:nth-child(even) {
      background-color: var(--bg-quaternary);
    }

    tr:nth-child(odd) {
      background-color: var(--bg-secondary);
    }

    tr.clickable-row {
      cursor: pointer;
      transition: background-color var(--transition);
    }

    tr.clickable-row:hover {
      background-color: var(--bg-hover);
    }

    tr.selected-row {
      background-color: var(--bg-selected);
      color: var(--text-primary);
      font-weight: bold;
    }

    tr.group-header td {
      background-color: var(--bg-group);
      color: var(--text-highlight);
      font-weight: bold;
      text-align: center;
      padding: 10px;
      border-bottom: 2px solid var(--border-dark);
      cursor: default;
    }

    td img.logo {
      width: 40px;
      height: 24px;
      object-fit: contain;
      border-radius: var(--border-radius);
      display: block;
    }

    #log-message {
      user-select: all;
      -webkit-user-select: all;
    }

    #log {
      position: fixed;
      bottom: 0;
      left: 0;
      width: 100%;
      background-color: var(--bg-quaternary);
      border-top: 1px solid var(--border-color);
      padding: var(--spacing);
      font-size: 1em;
      color: var(--text-secondary);
      box-sizing: border-box;
      z-index: 1000;
      display: flex;
      align-items: center;
      justify-content: flex-start;
      flex-wrap: wrap;
      gap: var(--spacing);
    }

    #log.loading {
      color: white;
    }

    #log.success {
      color: var(--accent-green);
    }

    #log.error {
      color: var(--accent-red);
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
        <button id="outputJack" aria-label="Välj ljudutgång till Jack">Jack</button>
        <button id="outputHDMI" aria-label="Välj ljudutgång till HDMI">HDMI</button>
        <button id="outputBluetooth" aria-label="Välj ljudutgång till Bluetooth">Bluetooth</button>
        <button id="outputOff" aria-label="Stäng av ljud">Stäng av</button>
    </div>
    <button class="bluetooth-btn" id="connectBluetoothButton" aria-label="Anslut till Bluetooth">Anslut Blåtand</button>
    <button class="bluetooth-btn" id="disconnectBluetoothButton" aria-label="Koppla bort från Bluetooth">Koppla bort Blåtand</button>
    <button class="bluetooth-btn" id="bluetoothVolumeUp" aria-label="Höj volymen på Bluetooth">Volym Upp</button>
    <button class="bluetooth-btn" id="bluetoothVolumeDown" aria-label="Sänk volymen på Bluetooth">Volym Ned</button>
</div>

<script>
  function setCookie(key, value, days = 7) {
      const d = new Date();
      d.setTime(d.getTime() + (days * 24 * 60 * 60 * 1000));
      const expires = "expires=" + d.toUTCString();
      document.cookie = `$${key}=$${encodeURIComponent(value)};$${expires};path=/;SameSite=Lax`;
  }

  function getCookie(key) {
      const cookies = document.cookie.split(';');
      for (const cookie of cookies) {
          const [cookieName, ...valueParts] = cookie.trim().split('=');
          if (cookieName === key) {
              return decodeURIComponent(valueParts.join('='));
          }
      }
      return "";
  }

  let currentOutput = getCookie('selectedOutput') || 'jack';
  let selectedChannelUrl = getCookie('selectedChannelUrl');

  function updateButtonStyles() {
      document.querySelectorAll('.output-buttons button').forEach(btn => {
          btn.classList.remove('active', 'active-off');
      });
      if (currentOutput !== 'off') {
          const btnId = currentOutput === 'hdmi' ? 'outputHDMI' : 'output' + currentOutput.charAt(0).toUpperCase() + currentOutput.slice(1);
          const btn = document.getElementById(btnId);
          if (btn) btn.classList.add('active');
      } else {
          const offBtn = document.getElementById('outputOff');
          if (offBtn) offBtn.classList.add('active-off');
      }
  }

  async function sendCgiRequest(channelUrl, outputDevice, command = null, channelName = null) {
      const logElement = document.getElementById('log-message');
      let fullUrl = `$${pre_url}`;

      if (command) {
          fullUrl += `command=$${command}`;
      } else if (channelUrl || outputDevice) {
          fullUrl += `url=$${encodeURIComponent(channelUrl || '')}&output=$${outputDevice}`;
          if (channelName) {
              fullUrl += `&name=$${encodeURIComponent(channelName)}`;
          }
      } else {
          return;
      }

      document.getElementById('log').className = 'loading';

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 15000);

      try {
          const response = await fetch(fullUrl, { signal: controller.signal });
          if (!response.ok) throw new Error(`HTTP-fel: $${response.status}`);
          
          const responseText = await response.text();
          logElement.textContent = responseText.trim() || 'Kommando skickat.';
          document.getElementById('log').className = 'success';

      } catch (error) {
          const errorMsg = error.name === 'AbortError' 
              ? `Tidsgräns överskreds` 
              : `Fel: $${error.message}`;
          logElement.textContent = `$${errorMsg}. CGI-anrop: $${fullUrl}`;
          document.getElementById('log').className = 'error';
      } finally {
          clearTimeout(timeoutId);
      }
      return window.location.origin + fullUrl;
  }

  async function handleRowClick(event) {
      const clickedRow = event.currentTarget;
      const channelUrl = clickedRow.dataset.url;
      const channelName = clickedRow.dataset.name;

      document.querySelectorAll('tr.selected-row').forEach(row => row.classList.remove('selected-row'));
      clickedRow.classList.add('selected-row');

      const outputToUse = currentOutput || 'off';
      const apiUrl = await sendCgiRequest(channelUrl, outputToUse, null, channelName);
      setCookie('selectedChannelUrl', channelUrl);
      document.getElementById('customUrlInput').value = channelUrl;
      if (apiUrl) document.getElementById('log-message').textContent = decodeURIComponent(apiUrl);
      updateButtonStyles();
  }

  async function handlePlayCustomUrl() {
      const customUrlInput = document.getElementById('customUrlInput');
      const customUrl = customUrlInput.value.trim();

      if (customUrl) {
          document.querySelectorAll('tr.selected-row').forEach(row => row.classList.remove('selected-row'));
          const outputToUse = currentOutput || 'off';
          const apiUrl = await sendCgiRequest(customUrl, outputToUse, null, "Egen URL");
          setCookie('selectedChannelUrl', customUrl);
          if (apiUrl) document.getElementById('log-message').textContent = decodeURIComponent(apiUrl);
          updateButtonStyles();
      }
  }

  async function handleOffClick() {
      document.querySelectorAll('tr.selected-row').forEach(row => row.classList.remove('selected-row'));
      await sendCgiRequest("", currentOutput);
      document.getElementById('customUrlInput').value = "";
      setCookie('selectedChannelUrl', "");
      currentOutput = 'off';
      setCookie('selectedOutput', currentOutput);
      updateButtonStyles();
  }
  
  async function handleConnectBluetooth() {
      await sendCgiRequest(null, null, 'bluetooth_connect');
  }

  async function handleDisconnectBluetooth() {
      await sendCgiRequest(null, null, 'bluetooth_disconnect');
  }

  async function handleOutputSwitch(event) {
      const clickedButton = event.target;
      if (clickedButton.tagName !== 'BUTTON' || clickedButton.id === 'outputOff') return;

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

      if (newOutput === 'bluetooth') {
          await sendCgiRequest(null, null, 'bluetooth_connect');
      }
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
              row.dataset.name = item.name;
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

          if (selectedChannelUrl) {
              document.querySelectorAll('tr[data-url]').forEach(row => {
                  if (row.dataset.url === selectedChannelUrl) {
                      row.classList.add('selected-row');
                  }
              });
              document.getElementById('customUrlInput').value = selectedChannelUrl;
          }
          updateButtonStyles();

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
      if (!tbody) return;
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
                  const escapedTerm = searchTerm.replace(/[.*+?^$${}()|[\]\\]/g, '\\$$&');
                  const regex = new RegExp(`($${escapedTerm})`, 'gi');
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

  document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
          event.preventDefault();
          location.reload();
      }
  });

  const pre_url = "/radio.sh?";
  loadAndBuildTable('radio_channels.json', 'table-container');

  document.querySelector('.output-buttons')?.addEventListener('click', handleOutputSwitch);
  document.getElementById('outputOff')?.addEventListener('click', handleOffClick);
  document.getElementById('playCustomUrlButton')?.addEventListener('click', handlePlayCustomUrl);
  document.getElementById('connectBluetoothButton')?.addEventListener('click', handleConnectBluetooth);
  document.getElementById('disconnectBluetoothButton')?.addEventListener('click', handleDisconnectBluetooth);
  document.getElementById('bluetoothVolumeUp')?.addEventListener('click', () => sendCgiRequest(null, null, 'bluetooth_volume_up'));
  document.getElementById('bluetoothVolumeDown')?.addEventListener('click', () => sendCgiRequest(null, null, 'bluetooth_volume_down'));
</script>
</body>
</html>
EOF

cat << "EOF" | base64 -d | zcat > /home/radio/radio_channels.json
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
58W/X/wB6Tr6NUZtAAA=
EOF

cat << "EOF" > /etc/asound.conf
pcm.bluealsa_raw {
    type bluealsa
    device "1C:AA:DA:C2:EA:23"
    profile "a2dp"
}

pcm.bt_speaker {
    type plug
    slave {
        pcm "bluealsa_raw"
        format "S16_LE"
        rate 48000
        channels 2
    }
    hint {
        show on
        description "Bluetooth Speaker (Fixed 48kHz)"
    }
}

pcm.!default {
    type copy
    slave.pcm "bt_speaker"
}

ctl.!default {
    type bluealsa
}
EOF

cat << "EOF" > /home/radio/radio.sh
#!/bin/ash

BT_MAC="78:A1:68:A5:EB:CF"
BT_SINK="/org/bluealsa/hci0/dev_$${BT_MAC//:/_}/a2dpsrc/sink"
echo "HTTP/1.1 200 OK"
echo "Content-Type: text/plain; charset=UTF-8"
echo ""

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
COMMAND=""
CHANNEL_NAME="" # Ny variabel för kanalnamnet

OLDIFS="$$IFS"
IFS='&'
set -- $$QUERY_STRING
IFS="$$OLDIFS"

for param in "$$@"; do
    case "$$param" in
        url=*)
            CHANNEL_URL=$$(urldecode "$${param#url=}")
            ;;
        output=*)
            OUTPUT_DEVICE="$${param#output=}"
            ;;
        command=*)
            COMMAND="$${param#command=}"
            ;;
        name=*) # Nytt fall för att fånga kanalnamnet
            CHANNEL_NAME=$$(urldecode "$${param#name=}")
            ;;
    esac
done

if [ ! -z "$$COMMAND" ]; then
    if [ "$$COMMAND" == "bluetooth_connect" ]; then
        bluetoothctl connect $$BT_MAC > /dev/null 2>&1
        if [ $$? -eq 0 ]; then
            echo "BT Anslutning lyckades."
        else
            echo "Fel vid BT Anslutning."
        fi
        exit 0
    elif [ "$$COMMAND" == "bluetooth_disconnect" ]; then
        bluetoothctl disconnect $$BT_MAC > /dev/null 2>&1
        if [ $$? -eq 0 ]; then
            echo "BT Frånkoppling lyckades."
        else
            echo "Fel vid BT Frånkoppling."
        fi
        exit 0
    elif [ "$$COMMAND" == "bluetooth_volume_up" ]; then
        bluealsa-cli volume "$$BT_SINK" $$(( vol=$$(bluealsa-cli volume "$$BT_SINK" | awk '{print $$3}'), vol + 10 ))
        echo "Volymen höjdes på Bluetooth.($$(($$vol+10)))"
        exit 0
    elif [ "$$COMMAND" == "bluetooth_volume_down" ]; then
        bluealsa-cli volume "$$BT_SINK" $$(( vol=$$(bluealsa-cli volume "$$BT_SINK" | awk '{print $$3}'), vol - 10 ))
        echo "Volymen sänktes på Bluetooth.($$(($$vol-10)))"
        exit 0
    else
        echo "Okänt kommando: $$COMMAND"
        exit 1
    fi
fi

if [ "$$OUTPUT_DEVICE" == "off" ]; then
    echo "Stänger av strömmen/radion."
    pkill -KILL ffmpeg
    exit 0
fi

if [ -z "$$OUTPUT_DEVICE" ]; then
    echo "Fel: 'output' parameter saknas eller är tom."
    exit 1
fi

if [ -z "$$CHANNEL_NAME" ]; then
    CHANNEL_NAME="Okänd kanal"
fi

if [ "$$OUTPUT_DEVICE" == "jack" ]; then
  pkill -KILL ffmpeg
  nohup ffmpeg -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 2 -i "$$CHANNEL_URL" -f alsa sysdefault:CARD=Headphones > /dev/null 2>&1 &
  echo "Startade $$CHANNEL_NAME på Jack."
elif [ "$$OUTPUT_DEVICE" == "hdmi" ]; then
  pkill -KILL ffmpeg
  nohup ffmpeg -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 2 -i "$$CHANNEL_URL" -f alsa sysdefault:CARD=b1 > /dev/null 2>&1 &
  echo "Startade $$CHANNEL_NAME på HDMI."
elif [ "$$OUTPUT_DEVICE" == "bluetooth" ]; then
  pkill -KILL ffmpeg
  nohup ffmpeg -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 2 -i "$$CHANNEL_URL" -f alsa default > /dev/null 2>&1 &
  echo "Startade $$CHANNEL_NAME på Bluetooth-strömning."
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

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp

auto wlan0
allow-hotplug wlan0
iface wlan0 inet dhcp

hostname radio
"
TIMEZONEOPTS="Europe/Stockholm"
PROXYOPTS="none"
APKREPOSOPTS="/media/mmcblk0p1/apks
https://ftp.sunet.se/mirror/alpinelinux.org/v$(ALPINE_VER)/main
https://ftp.sunet.se/mirror/alpinelinux.org/v$(ALPINE_VER)/community
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
	mcopy -v -i radio.img@@$$((512*2048)) -s alpine-$(ALPINE_VER)/* ::
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

distclean:
	git clean -ffdx
