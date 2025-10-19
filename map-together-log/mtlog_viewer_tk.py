"""
Map Together log inspector (structure-aware; pos/dir for blocks; item transforms)

- Fast meta scan (payload lazy-read)
- Tabs per type + All Records; every tab has a resizable side panel (details + hex)
- Hex view shows the *entire record* (header+payload+meta) as: offset | hex | ASCII
- Decoders:
  * ChatMsg, Admin_SetActionLimit: exact
  * Place/Delete/SetSkin: section counts (BLKs/SKNs/ITMs) + entries
      Blocks: name, collection, u32_after_name, dir, coord_nat3, pos/pyr/scale/pivot hints
      Items:  name, collection, coord_nat3, dir, pos vec3, pyr vec3, scale, pivot vec3,
              tail flags (isFlying, variantIx) when detected
  * Heuristic helpers: LPStrings, GUID/.sk refs, transform-window snapshots
"""

import os
import sys
import time
import json
import math
import re
import struct
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, List, Optional, Tuple, Any

try:
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox
except Exception as e:
    print("Tkinter is required (bundled with Python). Error:", e)
    sys.exit(1)

MT_NAMES: Dict[int, str] = {
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

@dataclass
class Record:
    index: int
    file_offset: int
    type_id: int
    payload_len: int
    meta_len: int
    player_id: str
    timestamp_ms: int
    _decoded: Optional[Dict[str, Any]] = field(default=None, repr=False)

    @property
    def type_name(self) -> str:
        return MT_NAMES.get(self.type_id, f"Unknown({self.type_id})")

    def iso_time(self) -> str:
        try:
            return datetime.fromtimestamp(self.timestamp_ms / 1000.0).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        except Exception:
            return str(self.timestamp_ms)

    def record_len_total(self) -> int:
        return 8 + self.payload_len + 4 + self.meta_len

def safe_decode(bs: bytes) -> str:
    return bs.decode("utf-8", errors="replace")

def hex_dump(chunk: bytes, base_off: int = 0, width: int = 16) -> str:
    lines = []
    for i in range(0, len(chunk), width):
        row = chunk[i:i+width]
        hexes = " ".join(f"{b:02x}" for b in row)
        ascii_ = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        lines.append(f"{base_off + i:08x}: {hexes:<{width*3}} {ascii_}")
    return "\n".join(lines)

def extract_lpstrings(payload: bytes, max_strings: int = 256) -> List[Tuple[int, str]]:
    out = []
    i, n = 0, len(payload)
    while i + 2 <= n and len(out) < max_strings:
        ln = int.from_bytes(payload[i:i+2], "little")
        i2 = i + 2
        if 0 < ln <= 0x7FFF and i2 + ln <= n:
            raw = payload[i2:i2+ln]
            txt = safe_decode(raw)
            printable = sum(1 for c in raw if 32 <= c < 127)
            if ln <= 2 or (printable / max(1, ln) >= 0.60):
                out.append((i, txt))
                i = i2 + ln
                continue
        i += 1
    return out

def find_guid_and_skin_refs(payload: bytes, limit=16):
    try:
        txt = payload.decode('utf-8', errors='ignore')
    except:
        return []
    guids = re.findall(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', txt)
    skins = re.findall(r'[0-9a-fA-F\-]{36}\.sk', txt)
    out = []
    for g in guids[:limit]:
        out.append({"guid": g})
    for s in skins[:max(0, limit-len(out))]:
        out.append({"skin_ref": s})
    return out

def float_triplet_candidates(payload: bytes, start=0, end=None, limit=8):
    out=[]
    if end is None: end = len(payload)
    for i in range(start, end-12+1, 4):
        f1,f2,f3 = struct.unpack_from('<fff', payload, i)
        if all(math.isfinite(v) for v in (f1,f2,f3)):
            if not (abs(f1)<1e-6 and abs(f2)<1e-6 and abs(f3)<1e-6):
                if all(abs(v) < 1e7 for v in (f1,f2,f3)):
                    out.append({"offset": i, "x": round(f1,4), "y": round(f2,4), "z": round(f3,4)})
                    if len(out)>=limit: break
    return out

def transform_window_candidates(payload: bytes, start=0, end=None, limit=3):
    cand=[]
    if end is None: end=len(payload)
    for i in range(start, end-64+1, 4):
        floats = struct.unpack_from('<16f', payload, i)
        near1 = sum(1 for f in floats if abs(f-1.0) < 1e-4)
        near0 = sum(1 for f in floats if abs(f) < 1e-5)
        if near1 >= 3 and near0 >= 6:
            tx_rm, ty_rm, tz_rm = floats[3], floats[7], floats[11]
            tx_cm, ty_cm, tz_cm = floats[12], floats[13], floats[14]
            cand.append({
                "offset": i,
                "near1": near1, "near0": near0,
                "row_major_t": [round(tx_rm,4), round(ty_rm,4), round(tz_rm,4)],
                "col_major_t": [round(tx_cm,4), round(ty_cm,4), round(tz_cm,4)],
            })
            if len(cand) >= limit: break
    return cand

def _find_sections(payload: bytes):
    out = {}
    for tag in (b"BLKs", b"SKNs", b"ITMs"):
        p = payload.find(tag)
        if p >= 0 and p + 6 <= len(payload):
            out[tag.decode()] = {
                "offset": p,
                "count": int.from_bytes(payload[p+4:p+6], "little")
            }
    return out

def _read_lpstring(b: bytes, p: int):
    if p + 2 > len(b): return p, ""
    ln = int.from_bytes(b[p:p+2], "little"); p += 2
    if ln < 0 or p + ln > len(b): return p, ""
    s = b[p:p+ln].decode("utf-8", "replace"); p += ln
    return p, s

def _find_next_lpstring_start(b: bytes, start: int, end: int, max_len: int = 96):
    i = start
    while i + 2 <= end:
        ln = int.from_bytes(b[i:i+2], "little")
        if 1 <= ln <= max_len and i + 2 + ln <= end:
            raw = b[i+2:i+2+ln]
            printable = sum(1 for x in raw if 32 <= x < 127)
            if printable / ln >= 0.85:
                return i
        i += 1
    return None

def _scan_nat3_near(b: bytes, start: int, end: int):
    for i in range(start, max(start, end - 12) + 1):
        x = int.from_bytes(b[i:i+4], "little")
        y = int.from_bytes(b[i+4:i+8], "little")
        z = int.from_bytes(b[i+8:i+12], "little")
        if x < 4096 and y < 4096 and z < 4096:
            return i, (x, y, z)
    return None, None

def _scan_dir_near(b: bytes, start: int, end: int):
    for i in range(start, max(start, end - 4) + 1):
        v = int.from_bytes(b[i:i+4], "little")
        if v in (0,1,2,3,4,5,6,7):
            return i, v
    return None, None

def _scan_half_pi_near(b: bytes, start: int, end: int):
    for i in range(start, max(start, end - 4) + 1):
        f = struct.unpack_from("<f", b, i)[0]
        if math.isfinite(f) and abs(abs(f) - math.pi/2) < 1e-3:
            return i, round(f, 6)
    return None, None

def _parse_block_entries(payload: bytes, blks_off: int, count: int, next_off: int):
    entries=[]
    p = blks_off + 6
    end = next_off
    for i in range(count):
        if p >= end: break
        p1, name = _read_lpstring(payload, p)
        if not name: break
        p = p1

        u32_after_name = None
        if p + 4 <= end:
            u32_after_name = int.from_bytes(payload[p:p+4], "little"); p += 4

        p, collection = _read_lpstring(payload, p)

        if i < count - 1:
            nx = _find_next_lpstring_start(payload, p, end)
            region_end = nx if nx else end
        else:
            region_end = end

        off_nat3, nat3 = _scan_nat3_near(payload, p, region_end)
        off_dir,  dirv = _scan_dir_near(payload, p, region_end)
        off_hpi,  hpi  = _scan_half_pi_near(payload, p, region_end)

        pos=None; off_pos=None
        for j in range(p, region_end-12+1, 4):
            f1,f2,f3 = struct.unpack_from('<fff', payload, j)
            if all(math.isfinite(x) for x in (f1,f2,f3)) and -50000 < f1 < 50000 and -50000 < f2 < 50000 and -50000 < f3 < 50000:
                if abs(f1)+abs(f2)+abs(f3) > 1.0:
                    pos=(round(f1,4), round(f2,4), round(f3,4)); off_pos=j; break

        entry = {
            "name": name,
            "collection": collection,
            "u32_after_name": u32_after_name,
        }
        if nat3:
            entry["coord_nat3"] = {"x": nat3[0], "y": nat3[1], "z": nat3[2]}
            entry["coord_nat3_offset"] = off_nat3
        if dirv is not None:
            entry["dir"] = dirv
            entry["dir_offset"] = off_dir
        if hpi is not None:
            entry["rotation_hint_half_pi"] = hpi
            entry["rotation_hint_offset"] = off_hpi
        if pos:
            entry["pos_hint"] = {"x": pos[0], "y": pos[1], "z": pos[2]}
            entry["pos_hint_offset"] = off_pos

        entries.append(entry)
        p = region_end

    return entries

def _parse_item_entries(payload: bytes, itms_off: int, count: int, next_off: int):
    entries=[]
    p = itms_off + 6
    end = next_off
    for i in range(count):
        if p >= end: break
        p, name = _read_lpstring(payload, p)
        if not name: break

        u32_after_name = None
        if p + 4 <= end:
            u32_after_name = int.from_bytes(payload[p:p+4], "little"); p += 4

        p, collection = _read_lpstring(payload, p)

        if i < count - 1:
            nx = _find_next_lpstring_start(payload, p, end)
            region_end = nx if nx else end
        else:
            region_end = end

        off_nat3, nat3 = _scan_nat3_near(payload, p, min(region_end, p + 96))
        off_dir,  dirv = _scan_dir_near(payload, p, min(region_end, p + 96))

        pos=None; off_pos=None
        for j in range(p, region_end-12+1, 4):
            f1,f2,f3=struct.unpack_from('<fff', payload, j)
            if all(math.isfinite(x) for x in (f1,f2,f3)) and -100000 < f1 < 100000 and -100000 < f2 < 100000 and -100000 < f3 < 100000:
                if abs(f1)+abs(f2)+abs(f3) > 1.0:
                    pos=(round(f1,4), round(f2,4), round(f3,4)); off_pos=j; break

        pyr=None; off_pyr=None
        if off_pos:
            for j in range(off_pos+12, min(region_end-12+1, off_pos+12+96), 4):
                f1,f2,f3=struct.unpack_from('<fff', payload, j)
                if all(-3.5 <= x <= 3.5 for x in (f1,f2,f3)):
                    pyr=(round(f1,4), round(f2,4), round(f3,4)); off_pyr=j; break

        scale=None; off_scale=None
        if off_pyr:
            for j in range(off_pyr+12, min(region_end-4+1, off_pyr+12+64), 4):
                f=struct.unpack_from('<f', payload, j)[0]
                if 0.01 <= f <= 64.0:
                    scale=round(f,4); off_scale=j; break

        pivot=None; off_pivot=None
        if off_scale:
            for j in range(off_scale+4, min(region_end-12+1, off_scale+128), 4):
                f1,f2,f3=struct.unpack_from('<fff', payload, j)
                if all(math.isfinite(x) for x in (f1,f2,f3)):
                    pivot=(round(f1,4), round(f2,4), round(f3,4)); off_pivot=j; break

        isFlying=None; variantIx=None
        tail_start = max(p, region_end - 24)
        for j in range(tail_start, region_end - 4 + 1, 4):
            v = int.from_bytes(payload[j:j+4], "little")
            if isFlying is None and v in (0,1):
                isFlying = v
            elif variantIx is None and v < 1<<20:
                variantIx = v

        entry = {
            "name": name,
            "collection": collection,
            "u32_after_name": u32_after_name,
        }
        if nat3:
            entry["coord_nat3"] = {"x": nat3[0], "y": nat3[1], "z": nat3[2]}
            entry["coord_nat3_offset"] = off_nat3
        if dirv is not None:
            entry["dir"] = dirv
            entry["dir_offset"] = off_dir
        if pos:
            entry["pos"] = {"x": pos[0], "y": pos[1], "z": pos[2]}
            entry["pos_offset"] = off_pos
        if pyr:
            entry["pyr"] = {"p": pyr[0], "y": pyr[1], "r": pyr[2]}
            entry["pyr_offset"] = off_pyr
        if scale is not None:
            entry["scale"] = scale
            entry["scale_offset"] = off_scale
        if pivot:
            entry["pivot"] = {"x": pivot[0], "y": pivot[1], "z": pivot[2]}
            entry["pivot_offset"] = off_pivot
        if isFlying is not None:
            entry["isFlying"] = isFlying
        if variantIx is not None:
            entry["variantIx"] = variantIx

        entries.append(entry)
        p = region_end

    return entries

def decode_chat(payload: bytes) -> Dict[str, Any]:
    info: Dict[str, Any] = {}
    if len(payload) < 3:
        info["warning"] = "payload too short for chat"
        return info
    msg_ty = payload[0]
    ln = int.from_bytes(payload[1:3], "little")
    if 3 + ln <= len(payload):
        msg = safe_decode(payload[3:3+ln])
    else:
        msg = safe_decode(payload[3:])
        info["warning"] = "truncated chat payload"
    info["msg_type"] = int(msg_ty)
    info["message"] = msg
    return info

def decode_admin_set_action_limit(payload: bytes) -> Dict[str, Any]:
    info: Dict[str, Any] = {}
    if len(payload) < 4:
        info["warning"] = "payload too short"
        return info
    info["limit_hz"] = int.from_bytes(payload[0:4], "little")
    return info

def decode_place_delete_setskin(payload: bytes, type_id: int) -> Dict[str, Any]:
    out: Dict[str, Any] = {}

    sections = _find_sections(payload)
    out["sections"] = sections

    blks = sections.get("BLKs")
    if blks:
        next_offsets = [v["offset"] for k,v in sections.items() if k != "BLKs" and v["offset"] > blks["offset"]]
        end = min(next_offsets) if next_offsets else len(payload)
        entries = _parse_block_entries(payload, blks["offset"], blks["count"], end)
        out["blocks"] = {"count": blks["count"], "entries": entries}
    else:
        out["blocks"] = {"count": 0}

    itms = sections.get("ITMs")
    if itms:
        next_offsets = [v["offset"] for k,v in sections.items() if k != "ITMs" and v["offset"] > itms["offset"]]
        end = min(next_offsets) if next_offsets else len(payload)
        entries = _parse_item_entries(payload, itms["offset"], itms["count"], end)
        out["items"] = {"count": itms["count"], "entries": entries}
    else:
        out["items"] = {"count": 0}

    skns = sections.get("SKNs")
    if skns:
        out["skins"] = {"count": skns["count"]}
    else:
        out["skins"] = {"count": 0}

    strings = extract_lpstrings(payload)
    if strings:
        out["lpstrings"] = [{"offset": off, "text": s} for off, s in strings]
    gu = find_guid_and_skin_refs(payload)
    if gu:
        out["guids_or_skins"] = gu

    tf = transform_window_candidates(payload, limit=3)
    if tf:
        out["transform_candidates"] = tf

    return out

class MTLogParser:
    def __init__(self, path: str):
        self.path = path
        self.fh = None
        self.offset = 0
        self.index = 0

    def open(self):
        self.close()
        self.fh = open(self.path, "rb", buffering=1024*1024)
        self.offset = 0
        self.index = 0

    def close(self):
        if self.fh:
            self.fh.close()
        self.fh = None

    def file_size(self) -> int:
        cur = self.fh.tell()
        self.fh.seek(0, os.SEEK_END)
        size = self.fh.tell()
        self.fh.seek(cur, os.SEEK_SET)
        return size

    def read_next_meta_only(self) -> Optional[Record]:
        if not self.fh:
            return None
        self.fh.seek(self.offset, os.SEEK_SET)
        head = self.fh.read(8)
        if len(head) < 8:
            return None
        type_id, payload_len = struct.unpack("<II", head)

        self.fh.seek(payload_len, os.SEEK_CUR)
        ml_raw_b = self.fh.read(4)
        if len(ml_raw_b) < 4:
            return None
        meta_len_flag, = struct.unpack("<I", ml_raw_b)
        meta_len = meta_len_flag & 0x7FFFFFFF

        meta = self.fh.read(meta_len)
        if len(meta) < meta_len:
            return None

        player_id = ""
        ts_ms = 0
        try:
            id_len, = struct.unpack_from("<H", meta, 0)
            pid = meta[2:2+id_len]
            player_id = safe_decode(pid)
            ts_ms, = struct.unpack_from("<Q", meta, 2+id_len)
        except Exception:
            pass

        rec = Record(
            index=self.index,
            file_offset=self.offset,
            type_id=type_id,
            payload_len=payload_len,
            meta_len=meta_len,
            player_id=player_id,
            timestamp_ms=ts_ms,
        )
        self.index += 1
        self.offset += 8 + payload_len + 4 + meta_len
        return rec

    def read_payload(self, rec: Record) -> bytes:
        self.fh.seek(rec.file_offset + 8, os.SEEK_SET)
        return self.fh.read(rec.payload_len)

    def read_full_record_bytes(self, rec: Record) -> bytes:
        self.fh.seek(rec.file_offset, os.SEEK_SET)
        return self.fh.read(rec.record_len_total())

class App(ttk.Frame):
    def __init__(self, master):
        super().__init__(master)
        self.master.title("Map Together Log Inspector")
        self.pack(fill="both", expand=True)

        self.records: List[Record] = []
        self.parser: Optional[MTLogParser] = None
        self.follow = tk.BooleanVar(value=False)
        self.decode_rows = tk.BooleanVar(value=True)

        self._build_toolbar()
        self._build_tabs()

        self.master.geometry("1280x860")

    def _build_toolbar(self):
        bar = ttk.Frame(self)
        bar.pack(side="top", fill="x")

        ttk.Button(bar, text="Open .map_together_log", command=self._choose_file).pack(side="left", padx=6, pady=6)
        ttk.Button(bar, text="Export current tab to JSON", command=self._export_current_tab).pack(side="left", padx=6)
        ttk.Checkbutton(bar, text="Follow file (tail)", variable=self.follow, command=self._toggle_follow).pack(side="left", padx=6)
        ttk.Checkbutton(bar, text="Decode table rows (Chat/Admin)", variable=self.decode_rows).pack(side="left", padx=6)
        self.status = ttk.Label(bar, text="Ready")
        self.status.pack(side="right", padx=6)

    def _build_tabs(self):
        self.nb = ttk.Notebook(self)
        self.nb.pack(fill="both", expand=True, padx=6, pady=6)
        self._build_all_tab()
        self.tabs: Dict[int, Dict[str, Any]] = {}

    def _make_tab_shell(self, title: str, columns: Tuple[str, ...], widths: Tuple[int, ...]) -> Dict[str, Any]:
        f = ttk.Frame(self.nb)

        hsplit = ttk.PanedWindow(f, orient="horizontal")
        hsplit.pack(fill="both", expand=True)

        left = ttk.Frame(hsplit)
        tree = ttk.Treeview(left, columns=columns, show="headings", selectmode="browse")
        for c, w in zip(columns, widths):
            tree.heading(c, text=c.title())
            tree.column(c, width=w, stretch=False)
        tree.pack(side="left", fill="both", expand=True)
        sb = ttk.Scrollbar(left, orient="vertical", command=tree.yview)
        tree.configure(yscroll=sb.set)
        sb.pack(side="left", fill="y")
        hsplit.add(left, weight=1)

        right = ttk.Frame(hsplit)
        vsplit = ttk.PanedWindow(right, orient="vertical")
        vsplit.pack(fill="both", expand=True)

        details_box = ttk.LabelFrame(vsplit, text="Record details")
        details_text = tk.Text(details_box, height=16, wrap="word", font=("Courier New", 10))
        details_text.pack(fill="both", expand=True, padx=6, pady=6)
        vsplit.add(details_box, weight=1)

        hex_box = ttk.LabelFrame(vsplit, text="Record (full) hex")
        hex_text = tk.Text(hex_box, height=18, wrap="none", font=("Courier New", 10))
        hex_text.pack(side="left", fill="both", expand=True, padx=6, pady=6)
        hex_sb = ttk.Scrollbar(hex_box, orient="vertical", command=hex_text.yview)
        hex_text.configure(yscroll=hex_sb.set)
        hex_sb.pack(side="left", fill="y")
        vsplit.add(hex_box, weight=1)

        hsplit.add(right, weight=1)
        self.nb.add(f, text=title)

        return {"frame": f, "tree": tree, "details_text": details_text, "hex_text": hex_text}

    def _build_all_tab(self):
        cols = ("index","offset","type","payload_len","player","time")
        widths = (80,120,200,120,260,220)
        ui = self._make_tab_shell("All Records", cols, widths)
        self.tab_all = ui
        ui["tree"].bind("<<TreeviewSelect>>", lambda e: self._on_select_in_tab(None))

    def _ensure_type_tab(self, type_id: int):
        if type_id in self.tabs:
            return
        name = MT_NAMES.get(type_id, f"Type {type_id}")
        if type_id == 20:
            cols = ("index","player","time","msg_type","message")
            widths = (80,260,220,100,520)
        elif type_id == 16:
            cols = ("index","player","time","limit")
            widths = (80,260,220,120)
        else:
            cols = ("index","offset","player","time","payload_len")
            widths = (80,120,260,220,120)
        ui = self._make_tab_shell(name, cols, widths)
        ui["tree"].bind("<<TreeviewSelect>>", lambda e, tid=type_id: self._on_select_in_tab(tid))
        self.tabs[type_id] = ui

    def _choose_file(self):
        path = filedialog.askopenfilename(
            title="Open Map Together Log",
            filetypes=[("MapTogether logs","*.map_together_log"), ("All files","*.*")]
        )
        if not path: return
        self._load(path)

    def _load(self, path: str):
        try:
            if self.parser: self.parser.close()
            self.records.clear()
            self.tab_all["tree"].delete(*self.tab_all["tree"].get_children())
            for ui in self.tabs.values():
                ui["tree"].delete(*ui["tree"].get_children())

            self.parser = MTLogParser(path)
            self.parser.open()
            t0 = time.time()
            added = 0
            while True:
                rec = self.parser.read_next_meta_only()
                if rec is None: break
                self.records.append(rec)
                self._append_record_to_tabs(rec)
                added += 1
            dt = time.time() - t0
            size_mb = self.parser.file_size() / (1024*1024)
            self.status.configure(text=f"Loaded {added} records from {os.path.basename(path)} ({size_mb:.2f} MB) in {dt:.2f}s")

            if self.follow.get():
                self.after(500, self._poll_follow)
        except Exception as e:
            messagebox.showerror("Open failed", str(e))

    def _poll_follow(self):
        if not self.parser or not self.follow.get():
            return
        try:
            added = 0
            while True:
                rec = self.parser.read_next_meta_only()
                if rec is None: break
                self.records.append(rec)
                self._append_record_to_tabs(rec)
                added += 1
            if added:
                self.status.configure(text=f"Appended {added} new records… total {len(self.records)}")
        finally:
            if self.follow.get():
                self.after(500, self._poll_follow)

    def _toggle_follow(self):
        if self.follow.get() and self.parser:
            self.after(500, self._poll_follow)

    def _append_record_to_tabs(self, rec: Record):
        all_tree = self.tab_all["tree"]
        all_tree.insert("", "end", iid=str(rec.index), values=(
            rec.index,
            f"0x{rec.file_offset:x}",
            f"{rec.type_name} ({rec.type_id})",
            rec.payload_len,
            rec.player_id,
            rec.iso_time(),
        ))

        self._ensure_type_tab(rec.type_id)
        ui = self.tabs[rec.type_id]
        tree = ui["tree"]

        if rec.type_id == 20 and self.decode_rows.get():
            payload = self.parser.read_payload(rec)
            d = decode_chat(payload)
            tree.insert("", "end", iid=str(rec.index), values=(
                rec.index, rec.player_id, rec.iso_time(), d.get("msg_type",""), d.get("message","")
            ))
        elif rec.type_id == 16 and self.decode_rows.get():
            payload = self.parser.read_payload(rec)
            d = decode_admin_set_action_limit(payload)
            tree.insert("", "end", iid=str(rec.index), values=(
                rec.index, rec.player_id, rec.iso_time(), d.get("limit_hz","")
            ))
        else:
            tree.insert("", "end", iid=str(rec.index), values=(
                rec.index, f"0x{rec.file_offset:x}", rec.player_id, rec.iso_time(), rec.payload_len
            ))

    def _get_selected_record(self, tab_type_id: Optional[int]) -> Optional[Record]:
        if tab_type_id is None:
            tree = self.tab_all["tree"]
        else:
            ui = self.tabs.get(tab_type_id)
            if not ui: return None
            tree = ui["tree"]
        sel = tree.selection()
        if not sel: return None
        idx = int(sel[0])
        if 0 <= idx < len(self.records): return self.records[idx]
        return None

    def _on_select_in_tab(self, tab_type_id: Optional[int]):
        rec = self._get_selected_record(tab_type_id)
        if not rec: return

        if rec._decoded is None:
            payload = self.parser.read_payload(rec)
            if rec.type_id == 20:
                rec._decoded = decode_chat(payload)
            elif rec.type_id == 16:
                rec._decoded = decode_admin_set_action_limit(payload)
            elif rec.type_id in (1,2,4):
                rec._decoded = decode_place_delete_setskin(payload, rec.type_id)
            else:
                rec._decoded = {"preview": safe_decode(payload[:128])}

        header = {
            "index": rec.index,
            "type_id": rec.type_id,
            "type": rec.type_name,
            "file_offset_hex": f"0x{rec.file_offset:x}",
            "payload_offset_hex": f"0x{rec.file_offset+8:x}",
            "payload_len": rec.payload_len,
            "meta_len": rec.meta_len,
            "player": rec.player_id,
            "timestamp_ms": rec.timestamp_ms,
            "time": rec.iso_time(),
        }
        doc = {"header": header, "decoded": rec._decoded}

        if tab_type_id is None:
            details_text = self.tab_all["details_text"]
            hex_text = self.tab_all["hex_text"]
        else:
            ui = self.tabs[tab_type_id]
            details_text = ui["details_text"]
            hex_text = ui["hex_text"]

        details_text.config(state="normal")
        details_text.delete("1.0", "end")
        details_text.insert("1.0", json.dumps(doc, indent=2, ensure_ascii=False))
        details_text.config(state="disabled")

        full = self.parser.read_full_record_bytes(rec)
        hex_text.config(state="normal")
        hex_text.delete("1.0", "end")
        hex_text.insert("1.0", hex_dump(full, base_off=rec.file_offset))
        hex_text.config(state="disabled")

    def _export_current_tab(self):
        current = self.nb.select()
        title = self.nb.tab(current, "text")
        if title == "All Records":
            data = [self._record_to_json(r) for r in self.records]
            fname = "all_records.json"
        else:
            type_id = None
            for k,v in MT_NAMES.items():
                if v == title:
                    type_id = k; break
            if type_id is None: return
            subset = [r for r in self.records if r.type_id == type_id]
            data = [self._record_to_json(r, ensure_decoded=True) for r in subset]
            fname = f"{title.replace(' ','_').lower()}.json"

        path = filedialog.asksaveasfilename(
            title="Export JSON",
            defaultextension=".json",
            filetypes=[("JSON","*.json")],
            initialfile=fname
        )
        if not path: return
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        messagebox.showinfo("Export", f"Saved {len(data)} records to {os.path.basename(path)}")

    def _record_to_json(self, r: Record, ensure_decoded: bool = False) -> Dict[str, Any]:
        if ensure_decoded and r._decoded is None:
            payload = self.parser.read_payload(r)
            if r.type_id == 20:
                r._decoded = decode_chat(payload)
            elif r.type_id == 16:
                r._decoded = decode_admin_set_action_limit(payload)
            elif r.type_id in (1,2,4):
                r._decoded = decode_place_delete_setskin(payload, r.type_id)
            else:
                r._decoded = {}

        return {
            "index": r.index,
            "file_offset": r.file_offset,
            "type_id": r.type_id,
            "type_name": r.type_name,
            "payload_len": r.payload_len,
            "meta_len": r.meta_len,
            "player_id": r.player_id,
            "timestamp_ms": r.timestamp_ms,
            "time": r.iso_time(),
            "decoded": (r._decoded or {}),
        }

def main():
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except Exception:
        pass
    App(root)
    root.mainloop()

if __name__ == "__main__":
    main()
