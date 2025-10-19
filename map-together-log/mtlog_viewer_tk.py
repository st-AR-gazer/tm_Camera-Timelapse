import os
import sys
import time
import json
import math
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

def type_name(tid: int) -> str:
    return MT_NAMES.get(tid, f"Unknown({tid})")

def collection_name(idx: int) -> str:
    return "Nadeo" if idx == 26 else f"#{idx}"

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
        return type_name(self.type_id)

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
        lines.append(f"{base_off + i:08x}  {hexes:<{width*3}}  {ascii_}")
    return "\n".join(lines)

def rd_u16_le(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o+2], "little")

def rd_u32_le(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o+4], "little")

def rd_f32_le(b: bytes, o: int) -> float:
    return struct.unpack_from("<f", b, o)[0]

def is_ascii_printable(bs: bytes) -> bool:
    for ch in bs:
        if ch in (9, 10, 13):
            continue
        if ch < 32 or ch >= 127:
            return False
    return True

def roundf(x: float, n: int = 6) -> float:
    try:
        if math.isfinite(x):
            return float(f"{x:.{n}f}")
    except Exception:
        pass
    return x

MAGIC_BLKS = b"BLKs"  # 0x734b4c42
MAGIC_SKNs = b"SKNs"  # 0x734e4b53
MAGIC_ITMs = b"ITMs"  # 0x734d5449

def find_sections(payload: bytes) -> Dict[str, Dict[str, int]]:
    out = {}
    for tag, key in ((MAGIC_BLKS, "BLKs"), (MAGIC_SKNs, "SKNs"), (MAGIC_ITMs, "ITMs")):
        i = payload.find(tag)
        if i < 0:
            out[key] = {"offset": -1, "count": 0}
            continue
        cnt_off = i + 4
        cnt = rd_u16_le(payload, cnt_off) if cnt_off + 2 <= len(payload) else 0
        out[key] = {"offset": i, "count": cnt, "count_offset": cnt_off}
    return out

def next_block_like_start(payload: bytes, search_from: int, hard_limit: int) -> Optional[int]:
    i = max(0, search_from)
    while i + 2 < hard_limit:
        if i + 2 > len(payload):
            return None
        nlen = rd_u16_le(payload, i)
        if 1 <= nlen <= 96 and i + 2 + nlen + 6 <= hard_limit:
            name_b = payload[i+2:i+2+nlen]
            if is_ascii_printable(name_b):
                j = i + 2 + nlen
                coll = rd_u32_le(payload, j)
                if 0 <= coll <= 500:
                    a_len_off = j + 4
                    a_len = rd_u16_le(payload, a_len_off)
                    if 0 <= a_len <= 128 and a_len_off + 2 + a_len <= hard_limit:
                        author_b = payload[a_len_off+2:a_len_off+2+a_len]
                        if is_ascii_printable(author_b):
                            return i
        i += 1
    return None

def parse_blocks(payload: bytes, blks_off: int, blks_count: int, section_end: int) -> Dict[str, Any]:
    result = {"count": blks_count, "entries": []}
    if blks_off < 0 or blks_count == 0:
        return result
    p = blks_off + 4 + 2
    for bi in range(blks_count):
        entry = {}
        start_here = p
        try:
            name_len = rd_u16_le(payload, p); p += 2
            name_off = p
            name = safe_decode(payload[p:p+name_len]); p += name_len

            coll_off = p
            coll_idx = rd_u32_le(payload, p); p += 4

            a_len = rd_u16_le(payload, p); p += 2
            author_off = p
            author = safe_decode(payload[p:p+a_len]); p += a_len

            coord_off = p
            x = rd_u32_le(payload, p); y = rd_u32_le(payload, p+4); z = rd_u32_le(payload, p+8); p += 12

            dir_off = p
            dir_val = rd_u16_le(payload, p); p += 2

            pos_off = p
            px = rd_f32_le(payload, p); py = rd_f32_le(payload, p+4); pz = rd_f32_le(payload, p+8); p += 12

            pyr_off = p
            prx = rd_f32_le(payload, p); pry = rd_f32_le(payload, p+4); prz = rd_f32_le(payload, p+8); p += 12

            if bi < blks_count - 1:
                nxt = next_block_like_start(payload, p, section_end)
                end_this = nxt if nxt is not None else section_end
            else:
                end_this = section_end

            tail = payload[p:end_this] if end_this > p else b""
            p = end_this

            entry = {
                "name": name,
                "name_offset": name_off,
                "collection_idx": coll_idx,
                "collection_name": collection_name(coll_idx),
                "collection_offset": coll_off,
                "author": author,
                "author_offset": author_off,
                "coord_nat3": {"x": x, "y": y, "z": z},
                "coord_nat3_offset": coord_off,
                "dir": dir_val,
                "dir_offset": dir_off,
                "dir_degrees": int(dir_val % 8) * 45 if dir_val >= 4 else int(dir_val) * 90,
                "pos": {"x": roundf(px), "y": roundf(py), "z": roundf(pz)},
                "pos_offset": pos_off,
                "pyr": {"x": roundf(prx), "y": roundf(pry), "z": roundf(prz)},
                "pyr_degrees": {"x": roundf(math.degrees(prx)), "y": roundf(math.degrees(pry)), "z": roundf(math.degrees(prz))},
                "pyr_offset": pyr_off,
            }
            if tail:
                entry["tail_raw"] = {
                    "offset": end_this - len(tail),
                    "length": len(tail),
                    "hex": payload[end_this-len(tail):end_this].hex()
                }
        except Exception as ex:
            entry["error"] = f"block parse error at {start_here}: {ex}"
            nxt = next_block_like_start(payload, p, section_end)
            p = nxt if nxt is not None else section_end
        result["entries"].append(entry)
    return result

def next_item_like_start(payload: bytes, search_from: int, hard_limit: int) -> Optional[int]:
    return next_block_like_start(payload, search_from, hard_limit)

def find_dir_pos_pyr_after(payload: bytes, from_off: int, end_off: int) -> Optional[Dict[str, Any]]:
    i = from_off
    while i + 2 + 12 + 12 <= end_off:
        d = rd_u16_le(payload, i)
        try:
            px = rd_f32_le(payload, i+2); py = rd_f32_le(payload, i+6); pz = rd_f32_le(payload, i+10)
            rx = rd_f32_le(payload, i+14); ry = rd_f32_le(payload, i+18); rz = rd_f32_le(payload, i+22)
            if all(math.isfinite(v) for v in (px,py,pz,rx,ry,rz)):
                if (abs(px) < 1e7 and abs(py) < 1e7 and abs(pz) < 1e7
                    and abs(rx) < 20 and abs(ry) < 20 and abs(rz) < 20):
                    return {
                        "dir": d, "dir_offset": i,
                        "pos": {"x": roundf(px), "y": roundf(py), "z": roundf(pz)},
                        "pos_offset": i+2,
                        "pyr": {"x": roundf(rx), "y": roundf(ry), "z": roundf(rz)},
                        "pyr_degrees": {"x": roundf(math.degrees(rx)), "y": roundf(math.degrees(ry)), "z": roundf(math.degrees(rz))},
                        "pyr_offset": i+14,
                    }
        except Exception:
            pass
        i += 2
    return None

def parse_items(payload: bytes, itms_off: int, itms_count: int, section_end: int) -> Dict[str, Any]:
    result = {"count": itms_count, "entries": []}
    if itms_off < 0 or itms_count == 0:
        return result
    p = itms_off + 4 + 2
    for ii in range(itms_count):
        entry = {}
        start_here = p
        try:
            nlen = rd_u16_le(payload, p); p += 2
            name_off = p
            name = safe_decode(payload[p:p+nlen]); p += nlen

            u32_after_name_off = p
            u32_after_name = rd_u32_le(payload, p); p += 4

            alen = rd_u16_le(payload, p); p += 2
            author_off = p
            author = safe_decode(payload[p:p+alen]); p += alen

            if ii < itms_count - 1:
                nxt = next_item_like_start(payload, p, section_end)
                end_this = nxt if nxt is not None else section_end
            else:
                end_this = section_end

            trio = find_dir_pos_pyr_after(payload, p, end_this)
            if trio:
                p = end_this
                entry = {
                    "name": name,
                    "name_offset": name_off,
                    "u32_after_name": u32_after_name,
                    "u32_after_name_offset": u32_after_name_off,
                    "author": author,
                    "author_offset": author_off,
                    "dir": trio["dir"],
                    "dir_offset": trio["dir_offset"],
                    "dir_degrees": int(trio["dir"] % 8) * 45 if trio["dir"] >= 4 else int(trio["dir"]) * 90,
                    "pos": trio["pos"],
                    "pos_offset": trio["pos_offset"],
                    "pyr": trio["pyr"],
                    "pyr_degrees": trio["pyr_degrees"],
                    "pyr_offset": trio["pyr_offset"],
                }
                tstart = trio["pyr_offset"] + 12
                if end_this > tstart:
                    entry["tail_raw"] = {
                        "offset": tstart,
                        "length": end_this - tstart,
                        "hex": payload[tstart:end_this].hex()
                    }
            else:
                entry = {
                    "name": name, "name_offset": name_off,
                    "u32_after_name": u32_after_name, "u32_after_name_offset": u32_after_name_off,
                    "author": author, "author_offset": author_off,
                    "note": "dir/pos/pyr not located within item body"
                }
                if end_this > p:
                    entry["raw_after_author"] = {
                        "offset": p,
                        "length": end_this - p,
                        "hex": payload[p:end_this].hex()
                    }
                p = end_this
        except Exception as ex:
            entry["error"] = f"item parse error at {start_here}: {ex}"
            nxt = next_item_like_start(payload, p, section_end)
            p = nxt if nxt is not None else section_end
        result["entries"].append(entry)
    return result

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
    limit = int.from_bytes(payload[0:4], "little")
    info["limit_hz"] = limit
    return info

def decode_place_delete_setskin(payload: bytes, type_id: int) -> Dict[str, Any]:
    doc: Dict[str, Any] = {}
    secs = find_sections(payload)
    doc["sections"] = {
        k: {"offset": v.get("offset", -1), "count": v.get("count", 0)}
        for k,v in secs.items()
    }
    notes: List[str] = []

    blks_off = secs.get("BLKs", {}).get("offset", -1)
    blks_cnt = secs.get("BLKs", {}).get("count", 0)
    skns_off = secs.get("SKNs", {}).get("offset", -1)
    itms_off = secs.get("ITMs", {}).get("offset", -1)

    end_blks = skns_off if (blks_off >= 0 and skns_off >= 0) else (len(payload))
    end_skns = itms_off if (skns_off >= 0 and itms_off >= 0) else (len(payload))
    end_itms = len(payload)

    if blks_off >= 0:
        doc["blocks"] = parse_blocks(payload, blks_off, blks_cnt, end_blks)
        if doc["blocks"]["count"] == 0:
            notes.append("BLKs present but count=0.")
    else:
        notes.append("No BLKs section found.")

    if skns_off >= 0:
        cnt = secs["SKNs"]["count"]
        start = skns_off + 6
        doc["skins"] = {"count": cnt, "raw_offset": start, "raw_length": max(0, end_skns - start)}
    else:
        notes.append("No SKNs section found.")

    if itms_off >= 0:
        itms_cnt = secs["ITMs"]["count"]
        doc["items"] = parse_items(payload, itms_off, itms_cnt, end_itms)
    else:
        notes.append("No ITMs section found.")

    if notes:
        doc["notes"] = notes
    return doc

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
        widths = (80,120,200,120,240,220)
        ui = self._make_tab_shell("All Records", cols, widths)
        self.tab_all = ui
        ui["tree"].bind("<<TreeviewSelect>>", lambda e: self._on_select_in_tab(None))

    def _ensure_type_tab(self, type_id: int):
        if type_id in self.tabs:
            return
        name = type_name(type_id)
        if type_id == 20:
            cols = ("index","player","time","msg_type","message")
            widths = (80,240,220,100,500)
        elif type_id == 16:
            cols = ("index","player","time","limit")
            widths = (80,240,220,120)
        else:
            cols = ("index","offset","player","time","payload_len")
            widths = (80,120,240,220,120)

        ui = self._make_tab_shell(name, cols, widths)
        ui["tree"].bind("<<TreeviewSelect>>", lambda e, tid=type_id: self._on_select_in_tab(tid))
        self.tabs[type_id] = ui

    def _choose_file(self):
        path = filedialog.askopenfilename(
            title="Open Map Together Log",
            filetypes=[("MapTogether logs","*.map_together_log"), ("All files","*.*")]
        )
        if not path:
            return
        self._load(path)

    def _load(self, path: str):
        try:
            if self.parser:
                self.parser.close()
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
                if rec is None:
                    break
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
                if rec is None:
                    break
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
            if not ui:
                return None
            tree = ui["tree"]
        sel = tree.selection()
        if not sel:
            return None
        idx = int(sel[0])
        if 0 <= idx < len(self.records):
            return self.records[idx]
        return None

    def _on_select_in_tab(self, tab_type_id: Optional[int]):
        rec = self._get_selected_record(tab_type_id)
        if not rec:
            return

        if rec._decoded is None:
            payload = self.parser.read_payload(rec)
            if rec.type_id == 20:
                rec._decoded = decode_chat(payload)
            elif rec.type_id == 16:
                rec._decoded = decode_admin_set_action_limit(payload)
            elif rec.type_id in (1,2,4):
                rec._decoded = decode_place_delete_setskin(payload, rec.type_id)
            else:
                rec._decoded = {}

        header = {
            "index": rec.index,
            "type_id": rec.type_id,
            "type": rec.type_name,
            "file_offset_hex": f"0x{rec.file_offset:x}",
            "payload_offset_hex": f"0x{rec.file_offset + 8:x}",
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
                    type_id = k
                    break
            if type_id is None:
                return
            subset = [r for r in self.records if r.type_id == type_id]
            data = [self._record_to_json(r, ensure_decoded=True) for r in subset]
            fname = f"{title.replace(' ','_').lower()}.json"

        path = filedialog.asksaveasfilename(
            title="Export JSON",
            defaultextension=".json",
            filetypes=[("JSON","*.json")],
            initialfile=fname
        )
        if not path:
            return
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
    style = ttk.Style()
    try:
        style.theme_use("clam")
    except Exception:
        pass
    App(root)
    root.mainloop()

if __name__ == "__main__":
    main()
