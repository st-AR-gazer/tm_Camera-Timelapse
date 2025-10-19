from __future__ import annotations
import io
import json
import mmap
import struct
import datetime
from dataclasses import dataclass
from typing import Optional, Dict, Any, Iterable, Tuple, List

MT_TYPES: Dict[int, str] = {
    0: "Unknown",
    1: "Place",
    2: "Delete",
    3: "Resync",
    4: "SetSkin",
    5: "SetWaypoint",
    6: "SetMapName",
    7: "PlayerJoin",
    8: "PlayerLeave",
    9: "Admin_PromoteMod",
    10: "Admin_DemoteMod",
    11: "Admin_KickPlayer",
    12: "Admin_BanPlayer",
    13: "Admin_ChangeAdmin",
    14: "PlayerCamCursor",
    15: "VehiclePos",
    16: "Admin_SetActionLimit",
    17: "Admin_SetVariable",
    18: "Admin_SetRoomPlayerLimit",
    19: "Admin_AlertStatusToAll",
    20: "ChatMsg",
    21: "Ping",
    22: "ServerStats",
}

def _u16(b: bytes, o: int) -> Tuple[int, int]:
    return struct.unpack_from("<H", b, o)[0], o + 2

def _lpstring(b: bytes, o: int) -> Tuple[str, int]:
    n, o = _u16(b, o)
    end = o + n
    s = b[o:end].decode("utf-8", errors="replace")
    return s, end

@dataclass
class MTRecord:
    index: int
    type_id: int
    type_name: str
    record_off: int
    payload_off: int
    payload_len: int
    meta_off: int
    meta_len: int
    player_id: str
    timestamp_ms: int
    file_path: Optional[str] = None

    @property
    def time_iso(self) -> str:
        try:
            return datetime.datetime.utcfromtimestamp(self.timestamp_ms / 1000.0).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        except Exception:
            return str(self.timestamp_ms)

    def header_dict(self) -> Dict[str, Any]:
        return {
            "index": self.index,
            "type_id": self.type_id,
            "type": self.type_name,
            "file_offset_hex": f"0x{self.record_off:x}",
            "payload_offset_hex": f"0x{self.payload_off:x}",
            "payload_len": self.payload_len,
            "meta_len": self.meta_len,
            "player": self.player_id,
            "timestamp_ms": self.timestamp_ms,
            "time": self.time_iso,
        }

def iter_mt_records(file_path: str) -> Iterable[MTRecord]:
    with open(file_path, "rb") as f:
        with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
            size = mm.size()
            off = 0
            idx = 0
            while off + 8 <= size:
                rec_start = off
                try:
                    type_id = struct.unpack_from("<I", mm, off)[0]; off += 4
                    payload_len = struct.unpack_from("<I", mm, off)[0]; off += 4
                except Exception:
                    break
                if payload_len < 0 or off + payload_len > size:
                    break
                payload_off = off
                off += payload_len
                if off + 4 > size:
                    break
                meta_flag = struct.unpack_from("<I", mm, off)[0]; off += 4
                meta_len = meta_flag & 0x7FFF_FFFF
                if meta_len < 10 or off + meta_len > size:
                    break
                meta_body_off = off
                name_len = struct.unpack_from("<H", mm, off)[0]; off += 2
                if name_len + 8 > meta_len:
                    break
                name_bytes = mm[off:off+name_len]; off += name_len
                try:
                    player_id = name_bytes.decode("utf-8", errors="replace")
                except Exception:
                    player_id = ""
                timestamp_ms = struct.unpack_from("<Q", mm, off)[0]; off += 8
                type_name = MT_TYPES.get(type_id, f"Unknown({type_id})")
                yield MTRecord(
                    index=idx,
                    type_id=type_id,
                    type_name=type_name,
                    record_off=rec_start,
                    payload_off=payload_off,
                    payload_len=payload_len,
                    meta_off=meta_body_off,
                    meta_len=meta_len,
                    player_id=player_id,
                    timestamp_ms=timestamp_ms,
                    file_path=file_path,
                )
                idx += 1

def read_payload_bytes(rec: MTRecord) -> bytes:
    if not rec.file_path:
        return b""
    with open(rec.file_path, "rb") as f:
        f.seek(rec.payload_off)
        return f.read(rec.payload_len)

def payload_hex(rec: MTRecord, window: tuple[int, int] | None = None, ascii_gutter: bool = False) -> str:
    data = read_payload_bytes(rec)
    start = 0
    if window is not None:
        start = max(0, min(window[0], len(data)))
        end = start + max(0, min(window[1], len(data) - start))
        data = data[start:end]
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_part = " ".join(f"{b:02x}" for b in chunk)
        if ascii_gutter:
            ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
            lines.append(f"{start+i:08x}: {hex_part:<47}  {ascii_part}")
        else:
            lines.append(f"{start+i:08x}: {hex_part}")
    return "\n".join(lines)

def decode_chat_payload(data: bytes) -> Dict[str, Any]:
    o = 0
    if len(data) < 3:
        return {"error": "truncated"}
    msg_ty = data[o]; o += 1
    try:
        msg, o = _lpstring(data, o)
    except Exception as e:
        return {"msg_type": msg_ty, "error": f"{type(e).__name__}: {e}"}
    return {"msg_type": msg_ty, "message": msg}

def decode_admin_action_limit_payload(data: bytes) -> Dict[str, Any]:
    if len(data) < 4:
        return {"error": "truncated"}
    limit_ms = struct.unpack_from("<I", data, 0)[0]
    hz = (1000.0 / limit_ms) if limit_ms else None
    return {"limit_per_action_ms": limit_ms, "limit_hz": hz}

def _find_tag(data: bytes, tag: bytes) -> int | None:
    p = data.find(tag)
    return p if p >= 0 else None

def decode_macroblock_sections(data: bytes) -> Dict[str, Any]:
    out: Dict[str, Any] = {"sections": {}, "notes": []}
    if len(data) >= 8:
        ver, size_field = struct.unpack_from("<II", data, 0)
        out["maybe_version"] = ver
        out["maybe_size_field"] = size_field
    for tag in (b"BLKs", b"SKNs", b"ITMs"):
        p = _find_tag(data, tag)
        if p is not None and p + 6 <= len(data):
            count = struct.unpack_from("<H", data, p + 4)[0]
            out["sections"][tag.decode()] = {"offset": p, "count": count}
        else:
            out["sections"][tag.decode()] = None
    itms = out["sections"].get("ITMs")
    items: List[Dict[str, Any]] = []
    if itms and itms["count"] > 0:
        o = itms["offset"] + 4 + 2
        for _ in range(itms["count"]):
            entry: Dict[str, Any] = {"offset": o}
            try:
                model, o = _lpstring(data, o)
                entry["model"] = model
                if o + 2 <= len(data):
                    col_len = struct.unpack_from("<H", data, o)[0]
                    if o + 2 + col_len <= len(data):
                        collection, o2 = _lpstring(data, o)
                        entry["collection"] = collection
                        o = o2
                    else:
                        entry["collection"] = None
                tail_take = min(80, max(0, len(data) - o))
                entry["raw_tail_hex"] = " ".join(f"{b:02x}" for b in data[o:o+tail_take])
                o += tail_take
            except Exception as e:
                entry["error"] = f"{type(e).__name__}: {e}"
            items.append(entry)
    out["items"] = items
    out["blocks"] = {"count": (out["sections"].get("BLKs") or {}).get("count", 0)}
    out["skins"] = {"count": (out["sections"].get("SKNs") or {}).get("count", 0)}
    return out

def decode_record_details(rec: MTRecord) -> Dict[str, Any]:
    data = read_payload_bytes(rec)
    ty = rec.type_id
    if ty == 20:
        return decode_chat_payload(data)
    if ty == 16:
        return decode_admin_action_limit_payload(data)
    if ty in (1, 2):
        return decode_macroblock_sections(data)
    if ty == 4:
        return {"raw_len": len(data), "note": "SetSkin decoding pending writer/reader functions."}
    return {"raw_len": len(data)}
