#!/usr/bin/env python3
"""vhalctl - talk to the firmware's built-in VHAL emulator socket.

The vehicle HAL (android.hardware.automotive.vehicle@2.0-service) is
ECARX's fork of AOSP EmulatedVehicleHal. With ro.kernel.qemu unset it
starts SocketComm: a TCP listener on guest port 33452 speaking the AOSP
vehicle-emulator protocol - 4-byte big-endian length prefix + proto2
emulator.EmulatorMessage (VehicleHalProto.proto, Android 9).

SET_PROPERTY_CMD lands in VehicleHalManager::setPropertyFromVehicle: the
property store is updated and onChangeEvent fans out to subscribers
(CarService, SX11SensorManager, ...). It looks to the framework exactly
like MCU telemetry arriving on the RX path - no SPI/MCU involved, which
is precisely what an emulator wants. (Writes from this socket never
reach composeMcuData/CAN - verified live on the real car.)

Notable properties (of the 1744 the firmware's VHAL defines):
  NIGHT_MODE            0x21408015  (0=day, 1=night; boots as 2!)
  GEAR_SELECTION        0x2140800f  (ECARX enum: 1=PARK 2=REVERSE 3=NEUTRAL
                                     4=DRIVE; gear FWD map 4->1;2->2;1->3;8->4;
                                     boots as 2 = REVERSE without an MCU!)
  CURRENT_GEAR          0x11400401  (actual gearbox state, RX-fed on the car)
  PARKING_BRAKE_ON      0x2140800c
  IGNITION_STATE        0x2140800b  (boots as 8)
  ED_EV_BATTERY_PERCENTAGE 0x2140a6ed (boots as 0)
  PERF_VEHICLE_SPEED    0x11600207  (float, km/h)

Usage:
  vhalctl.py night day|night
  vhalctl.py park                       parked-car baseline (gear/current PARK,
                                        e-brake on, day, SoC 80%, speed 0) -
                                        the state the MCU would report for a
                                        parked car; run.sh applies it at boot
  vhalctl.py set PROP VALUE [AREAID]    PROP hex 0x… or decimal
  vhalctl.py setf PROP FLOAT [AREAID]
  vhalctl.py get PROP [AREAID]
  vhalctl.py all                        dump every property value
"""
import os
import socket
import struct
import sys

HOST = os.environ.get("EX2_VHAL_HOST", "127.0.0.1")
PORT = int(os.environ.get("EX2_VHAL_PORT", "33452"))

MSG_TYPE = {
    "GET_CONFIG_CMD": 0, "GET_CONFIG_RESP": 1,
    "GET_CONFIG_ALL_CMD": 2, "GET_CONFIG_ALL_RESP": 3,
    "GET_PROPERTY_CMD": 4, "GET_PROPERTY_RESP": 5,
    "GET_PROPERTY_ALL_CMD": 6, "GET_PROPERTY_ALL_RESP": 7,
    "SET_PROPERTY_CMD": 8, "SET_PROPERTY_RESP": 9,
    "SET_PROPERTY_ASYNC": 10,
}
STATUS = {
    0: "RESULT_OK", 1: "ERROR_UNKNOWN", 2: "ERROR_UNIMPLEMENTED_CMD",
    3: "ERROR_INVALID_PROPERTY", 4: "ERROR_INVALID_AREA_ID",
    5: "ERROR_PROPERTY_UNINITIALIZED", 6: "ERROR_WRITE_ONLY_PROPERTY",
    7: "ERROR_MEMORY_ALLOCATION_FAILED", 8: "ERROR_INVALID_OPERATION",
}

NIGHT_MODE = 0x21408015

# Parked-car baseline: what the MCU would report for a stationary car in
# daytime. Without an MCU the store boots on compiled-in defaults that make
# no sense (GEAR_SELECTION=2 is REVERSE in the ECARX enum, NIGHT_MODE=2 is
# night, battery 0%) and apps react to them - FlymeAutoRestrictionService
# locks the UI "in R gear", the energy app shows 0%, etc.
PARK_BASELINE = [
    # (prop, kind, value)
    (0x2140800F, "int", 1),      # GEAR_SELECTION = PARK
    (0x11400401, "int", 1),      # CURRENT_GEAR = PARK (RX mirror)
    (0x2140800C, "int", 1),      # PARKING_BRAKE_ON = on
    (NIGHT_MODE, "int", 0),      # NIGHT_MODE = day
    (0x2140A6ED, "int", 80),     # ED_EV_BATTERY_PERCENTAGE = 80%
    (0x11600207, "float", 0.0),  # PERF_VEHICLE_SPEED = 0 km/h
]


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def tag(field, wt):
    return varint((field << 3) | wt)


def enc_prop_value(prop, area_id, int32s=(), int64s=(), floats=(), string=None, status=None):
    m = tag(1, 0) + varint(prop)          # prop (required)
    m += tag(4, 0) + varint(area_id)      # area_id
    if status is not None:
        m += tag(10, 0) + varint(status)
    for v in int32s:
        m += tag(5, 0) + varint(v & 0xFFFFFFFF)
    for v in int64s:
        m += tag(6, 0) + varint(v & 0xFFFFFFFFFFFFFFFF)
    for v in floats:
        m += tag(7, 5) + struct.pack("<f", v)
    if string is not None:
        raw = string.encode()
        m += tag(8, 2) + varint(len(raw)) + raw
    return bytes(m)


def enc_prop_get(prop, area_id):
    return tag(1, 0) + varint(prop) + tag(2, 0) + varint(area_id)


def enc_msg(msg_type, gets=(), values=()):
    m = tag(1, 0) + varint(msg_type)
    for g in gets:
        m += tag(3, 2) + varint(len(g)) + g
    for v in values:
        m += tag(5, 2) + varint(len(v)) + v
    return bytes(m)


def read_varint(buf, i):
    shift = res = 0
    while True:
        b = buf[i]
        i += 1
        res |= (b & 0x7F) << shift
        if not b & 0x80:
            return res, i
        shift += 7


def parse_fields(buf):
    """Yield (field_number, wire_type, value_bytes_or_int, new_index)."""
    i = 0
    while i < len(buf):
        key, i = read_varint(buf, i)
        field, wt = key >> 3, key & 7
        if wt == 0:
            val, i = read_varint(buf, i)
        elif wt == 1:
            val, i = buf[i:i + 8], i + 8
        elif wt == 2:
            n, i = read_varint(buf, i)
            val, i = buf[i:i + n], i + n
        elif wt == 5:
            val, i = buf[i:i + 4], i + 4
        else:
            raise ValueError(f"wire type {wt}")
        yield field, wt, val, i


def dec_prop_value(buf):
    out = {"prop": 0, "area_id": 0, "int32": [], "int64": [],
           "float": [], "string": None, "status": None, "timestamp": None}
    for field, wt, val, _ in parse_fields(buf):
        if field == 1 and wt == 0:
            out["prop"] = val
        elif field == 2 and wt == 0:
            out["value_type"] = val
        elif field == 3 and wt == 0:
            out["timestamp"] = val
        elif field == 4 and wt == 0:
            out["area_id"] = val
        elif field == 5 and wt == 0:
            out["int32"].append(val - (1 << 32) if val >> 31 else val)
        elif field == 5 and wt == 2:  # packed
            j = 0
            while j < len(val):
                v, j = read_varint(val, j)
                out["int32"].append(v - (1 << 32) if v >> 31 else v)
        elif field == 6 and wt == 0:
            out["int64"].append(val)
        elif field == 7 and wt == 5:
            out["float"].append(struct.unpack("<f", val)[0])
        elif field == 8 and wt == 2:
            out["string"] = val.decode(errors="replace")
        elif field == 10 and wt == 0:
            out["status"] = val
    return out


def exchange(payload):
    with socket.create_connection((HOST, PORT), timeout=5) as s:
        s.sendall(struct.pack(">I", len(payload)) + payload)
        hdr = b""
        while len(hdr) < 4:
            chunk = s.recv(4 - len(hdr))
            if not chunk:
                raise ConnectionError("VHAL closed before header")
            hdr += chunk
        n = struct.unpack(">I", hdr)[0]
        body = b""
        while len(body) < n:
            chunk = s.recv(n - len(body))
            if not chunk:
                raise ConnectionError("VHAL closed mid-message")
            body += chunk
        return body


def parse_resp(buf):
    msg_type = status = None
    values = []
    for field, wt, val, _ in parse_fields(buf):
        if field == 1 and wt == 0:
            msg_type = val
        elif field == 2 and wt == 0:
            status = val
        elif field == 5 and wt == 2:
            values.append(dec_prop_value(val))
    return msg_type, status, values


def fmt_value(v):
    bits = []
    if v["int32"]:
        bits.append("int32=" + ",".join(map(str, v["int32"])))
    if v["int64"]:
        bits.append("int64=" + ",".join(map(str, v["int64"])))
    if v["float"]:
        bits.append("float=" + ",".join(f"{x:g}" for x in v["float"]))
    if v["string"] is not None:
        bits.append(f"string={v['string']!r}")
    if v["status"] is not None:
        bits.append(f"status={v['status']}")
    return " ".join(bits) or "(no value)"


def parse_prop(text):
    return int(text, 0)


def cmd_set(args):
    prop = parse_prop(args[0])
    value = int(args[1], 0)
    area = int(args[2], 0) if len(args) > 2 else 0
    resp = exchange(enc_msg(MSG_TYPE["SET_PROPERTY_CMD"],
                            values=[enc_prop_value(prop, area, int32s=[value])]))
    mt, st, _ = parse_resp(resp)
    ok = mt == MSG_TYPE["SET_PROPERTY_RESP"] and st == 0
    print(f"set 0x{prop:08x} area {area} = {value}: "
          f"{STATUS.get(st, st)}{' ' if ok else ' (FAILED)'}")
    return 0 if ok else 1


def cmd_setf(args):
    prop = parse_prop(args[0])
    value = float(args[1])
    area = int(args[2], 0) if len(args) > 2 else 0
    resp = exchange(enc_msg(MSG_TYPE["SET_PROPERTY_CMD"],
                            values=[enc_prop_value(prop, area, floats=[value])]))
    mt, st, _ = parse_resp(resp)
    ok = mt == MSG_TYPE["SET_PROPERTY_RESP"] and st == 0
    print(f"set 0x{prop:08x} area {area} = {value:g}: "
          f"{STATUS.get(st, st)}{' ' if ok else ' (FAILED)'}")
    return 0 if ok else 1


def cmd_get(args):
    prop = parse_prop(args[0])
    area = int(args[1], 0) if len(args) > 1 else 0
    resp = exchange(enc_msg(MSG_TYPE["GET_PROPERTY_CMD"],
                            gets=[enc_prop_get(prop, area)]))
    mt, st, values = parse_resp(resp)
    if st is not None and st != 0:
        print(f"get 0x{prop:08x}: {STATUS.get(st, st)}")
        return 1
    for v in values:
        print(f"0x{v['prop']:08x} area {v['area_id']}: {fmt_value(v)}")
    return 0


def cmd_all(_args):
    resp = exchange(enc_msg(MSG_TYPE["GET_PROPERTY_ALL_CMD"]))
    _, _, values = parse_resp(resp)
    for v in values:
        print(f"0x{v['prop']:08x} area {v['area_id']}: {fmt_value(v)}")
    print(f"# {len(values)} properties", file=sys.stderr)
    return 0


def cmd_night(args):
    mode = {"day": 0, "night": 1}.get(args[0])
    if mode is None:
        print("usage: vhalctl.py night day|night", file=sys.stderr)
        return 2
    return cmd_set([f"0x{NIGHT_MODE:x}", str(mode)])


def cmd_park(_args):
    rc = 0
    for prop, kind, value in PARK_BASELINE:
        try:
            if kind == "float":
                rc |= cmd_setf([f"0x{prop:x}", repr(value)])
            else:
                rc |= cmd_set([f"0x{prop:x}", str(value)])
        except (ConnectionError, OSError) as e:
            print(f"set 0x{prop:08x}: {e}", file=sys.stderr)
            rc = 1
    return rc


COMMANDS = {"set": cmd_set, "setf": cmd_setf, "get": cmd_get,
            "all": cmd_all, "night": cmd_night, "park": cmd_park}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 2
    return COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
