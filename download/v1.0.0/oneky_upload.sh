#!/bin/sh -
set -e

if [ $# -lt 5 ]; then
  echo "Usage: $0 <dummy_port> <altID> <usbVID> <usbPID> <binfile>" >&2
  exit 1
fi

dummy_port_fullpath="$1"
altID="$2"
usbVID=${3#"0x"}
usbPID=${4#"0x"}
binfile="$5"

EXT=""
UNAME_OS="$(uname -s)"
case "${UNAME_OS}" in
  Linux*)
    dummy_port_fullpath="/dev/$1"
    UNAME_ARCH="$(uname -m)"
    case "${UNAME_ARCH}" in
      x86_64)        OS_DIR="linux/x86_64" ;;
      aarch64|arm64) OS_DIR="linux/aarch64" ;;
      *) echo "Unsupported Linux architecture: ${UNAME_ARCH}." >&2 && exit 1 ;;
    esac
    ;;
  Darwin*)
    dummy_port_fullpath="/dev/$1"
    OS_DIR="macosx"
    ;;
  Windows*)
    dummy_port_fullpath="$1"
    OS_DIR="win"
    EXT=".exe"
    ;;
  *)
    echo "Unknown host OS: ${UNAME_OS}." >&2 && exit 1
    ;;
esac

DIR=$(cd "$(dirname "$0")" && pwd)

# ===================================================
# Step 1 — ส่ง boot command ผ่าน python
# ===================================================
echo "--- Triggering bootloader on ${dummy_port_fullpath} ---"
python3 - <<EOF
import serial, time, sys

port = "${dummy_port_fullpath}"
try:
    s = serial.Serial(port, 115200, timeout=1.0)
    time.sleep(0.1)
    s.write(b'boot\n')
    s.flush()
    deadline = time.time() + 3.0
    while time.time() < deadline:
        if s.in_waiting:
            resp = s.readline().decode('utf-8', errors='ignore').strip()
            print("Board: " + resp)
            if resp == 'OK':
                break
    s.close()
    print("Reset triggered")
except Exception as e:
    print("Serial: " + str(e), file=sys.stderr)
EOF

# ===================================================
# Step 2 — หา STM32_Programmer_CLI
# ===================================================
CUBE_PROG=""

if [ "${OS_DIR}" = "win" ]; then
  for candidate in \
    "C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeProgrammer\bin\STM32_Programmer_CLI.exe" \
    "/c/Program Files (x86)/STMicroelectronics/STM32Cube/STM32CubeProgrammer/bin/STM32_Programmer_CLI.exe"
  do
    if [ -f "${candidate}" ]; then
      CUBE_PROG="${candidate}"
      break
    fi
  done
else
  for candidate in \
    "/usr/local/bin/STM32_Programmer_CLI" \
    "/opt/STM32CubeProgrammer/bin/STM32_Programmer_CLI"
  do
    if [ -f "${candidate}" ]; then
      CUBE_PROG="${candidate}"
      break
    fi
  done
fi

if [ -z "${CUBE_PROG}" ]; then
  echo "ERROR: STM32CubeProgrammer not found" >&2
  echo "Download: https://www.st.com/en/development-tools/stm32cubeprog.html" >&2
  exit 1
fi

echo "Using: ${CUBE_PROG}"

# ===================================================
# Step 3 — รอ DFU device ด้วย STM32CubeProgrammer
# ===================================================
echo "--- Waiting for DFU device ---"
WAIT_COUNTER=10
while [ $WAIT_COUNTER -gt 0 ]; do
  if "${CUBE_PROG}" -l usb 2>&1 | grep -q "USB"; then
    echo "DFU device found!"
    break
  fi
  WAIT_COUNTER=$((WAIT_COUNTER - 1))
  echo "Waiting... (${WAIT_COUNTER} left)"
  sleep 1
done

if [ $WAIT_COUNTER -eq 0 ]; then
  echo "ERROR: DFU device not found after 10s" >&2
  exit 1
fi

# ===================================================
# Step 4 — flash ด้วย STM32CubeProgrammer
# ===================================================
echo "--- Flashing ---"
"${CUBE_PROG}" \
  -c port=USB1 \
  -d "${binfile}" 0x0800C000 \
  -v \
  -g 0x08000000

# ===================================================
# Step 4.5 — รอ app boot แล้วส่ง reset
# ===================================================
echo "--- Waiting for app to boot ---"
python3 - <<EOF
import serial, time, sys

port = "${dummy_port_fullpath}"

deadline = time.time() + 10.0
s = None
while time.time() < deadline:
    try:
        s = serial.Serial(port, 115200, timeout=1.0)
        print("Port opened: " + port)
        break
    except:
        time.sleep(0.3)

if s is None:
    print("Port not found, skipping reset")
    sys.exit(0)

time.sleep(0.5)

s.write(b'reset\n')
s.flush()

deadline2 = time.time() + 2.0
while time.time() < deadline2:
    if s.in_waiting:
        resp = s.readline().decode('utf-8', errors='ignore').strip()
        print("Board: " + resp)
        if resp == 'OK':
            break
s.close()
print("Reset to interface done")
EOF

# ===================================================
# Step 5 — รอ COM port กลับมา
# ===================================================
sleep 1
printf "Waiting for %s serial..." "${dummy_port_fullpath}"
COUNTER=40
if [ "${OS_DIR}" = "win" ]; then
  while [ $COUNTER -gt 0 ]; do
    if "${DIR}/${OS_DIR}/check_port${EXT}" "${dummy_port_fullpath}"; then
      break
    fi
    COUNTER=$((COUNTER - 1))
    printf "."
    sleep 0.1
  done
else
  while [ ! -r "${dummy_port_fullpath}" ] && [ $COUNTER -gt 0 ]; do
    COUNTER=$((COUNTER - 1))
    printf "."
    sleep 0.1
  done
fi

if [ $COUNTER -eq 0 ]; then
  echo " Timed out (but flash was successful)."
else
  echo " Done."
fi