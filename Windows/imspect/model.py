"""Image edit history and self-contained, non-executable Imspect workspaces."""
from __future__ import annotations

import io
import json
import math
import os
import tempfile
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .engine import MAX_PIXELS, channel_adjust, validate_image

MAX_WORKSPACE_BYTES = 2 * 1024**3
MAX_METADATA_BYTES = 16 * 1024**2


@dataclass
class ImageItem:
    id: str
    name: str
    pixels: np.ndarray
    original: np.ndarray
    revision: int = 0
    history: list = field(default_factory=list)
    channel_values: list = field(default_factory=lambda: [0.0, 0.0, 0.0])
    channel_base: np.ndarray = None
    _undo: list = field(default_factory=list, repr=False)
    _channel_snapshot: object = field(default=None, repr=False)

    def __post_init__(self):
        self.pixels = validate_image(self.pixels, copy=True)
        self.original = validate_image(self.original, copy=True)
        self.channel_base = validate_image(self.pixels if self.channel_base is None else self.channel_base, copy=True)
        if self.channel_base.shape != self.pixels.shape:
            raise ValueError("Channel baseline and image dimensions differ.")
        if not isinstance(self.id,str) or not self.id or not isinstance(self.name,str):
            raise ValueError("An image needs a name and stable identifier.")
        if len(self.channel_values) != 3 or any(not isinstance(v,(int,float)) or not math.isfinite(v) or abs(v)>1 for v in self.channel_values):
            raise ValueError("Invalid channel settings.")
        self.channel_values = list(self.channel_values)
        if not isinstance(self.history,list) or any(not isinstance(v,str) for v in self.history):
            raise ValueError("Invalid image edit history.")

    @classmethod
    def from_array(cls, name, array):
        a = validate_image(array)
        return cls(str(uuid.uuid4()), str(name), a, a)

    def _snapshot(self):
        return (self.pixels.copy(),self.channel_base.copy(),list(self.channel_values),list(self.history))

    def _remember(self, state):
        self._undo.append(state)
        del self._undo[:-10]

    def apply(self, pixels, description):
        a = validate_image(pixels,copy=True)
        self._remember(self._snapshot())
        self.pixels = a
        self.channel_base = a.copy()
        self.channel_values = [0.0,0.0,0.0]
        self.history.append(str(description))
        self._channel_snapshot = None
        self.revision += 1

    def undo(self):
        if self._channel_snapshot is not None:
            state = self._channel_snapshot
            self._channel_snapshot = None
        elif self._undo:
            state = self._undo.pop()
        else:
            return False
        self.pixels,self.channel_base,self.channel_values,self.history = state
        self.revision += 1
        return True

    def restore(self):
        self.apply(self.original,"Restore original")

    def set_channels(self, values, commit=True):
        values = list(values)
        result = channel_adjust(self.channel_base,values)
        if self._channel_snapshot is None:
            self._channel_snapshot = self._snapshot()
        before = self._channel_snapshot
        self.pixels = result
        self.channel_values = values
        self.revision += 1
        if commit:
            if values != before[2]:
                self._remember(before)
                self.history.append("RGB controls: " + ", ".join(f"{v:+.3f}" for v in values))
            self._channel_snapshot = None


def _json_bytes(value):
    try:
        return json.dumps(value,ensure_ascii=False,allow_nan=False,separators=(",", ":")).encode("utf-8")
    except (ValueError,TypeError,RecursionError) as exc:
        raise ValueError("Workspace metadata must be finite JSON values.") from exc


def _validate_metadata(state, annotations):
    if not isinstance(state,dict) or not isinstance(annotations,list):
        raise ValueError("Workspace state must be an object and annotations a list.")
    def finite(value, low, high, label):
        if type(value) not in (int,float) or not math.isfinite(value) or not low <= value <= high:
            raise ValueError("Invalid workspace " + label + ".")
    def point(value,label):
        if not isinstance(value,(list,tuple)) or len(value)!=2:
            raise ValueError("Invalid workspace " + label + ".")
        for v in value:
            finite(v,-1e7,1e7,label)
    for key in ("selected","partner","reference"):
        if key in state and (type(state[key]) is not int or abs(state[key])>1000):
            raise ValueError("Invalid workspace image selection.")
    for key,allowed in {"mode":("split","flicker","wipe"),"view_mode":("images","difference","mse","ssim","fft"),"kernel":("nearest","linear","cubic","lanczos2","lanczos3")}.items():
        if key in state and state[key] not in allowed:
            raise ValueError("Invalid workspace " + key + ".")
    for key,lo,hi in (("zoom",1/16384,16384),("gain",.000001,1e6),("wipe_position",0,1),("draw_width",.1,4096),("font_size",1,4096)):
        if key in state: finite(state[key],lo,hi,key)
    if "center" in state: point(state["center"],"center")
    roi=state.get("roi")
    if roi is not None:
        if not isinstance(roi,(list,tuple)) or len(roi)!=4 or any(type(v) is not int for v in roi) or any(abs(v)>1e7 for v in roi) or min(roi[:2])<0 or min(roi[2:])<1:
            raise ValueError("Invalid workspace region.")
    for key in ("draw_color",):
        if key in state and (not isinstance(state[key],str) or len(state[key])>128):
            raise ValueError("Invalid workspace color.")
    if len(annotations)>100000:
        raise ValueError("Too many workspace annotations.")
    total_points=0
    for annotation in annotations:
        if not isinstance(annotation,dict) or annotation.get("tool") not in ("rectangle","circle","dot","line","brush","text"):
            raise ValueError("Invalid workspace annotation.")
        point(annotation.get("start"),"annotation position")
        if "end" in annotation: point(annotation["end"],"annotation position")
        for key,lo,hi in (("width",.1,4096),("font_size",1,4096)):
            if key in annotation: finite(annotation[key],lo,hi,"annotation " + key)
        if "color" in annotation and (not isinstance(annotation["color"],str) or len(annotation["color"])>128):
            raise ValueError("Invalid annotation color.")
        if "image_id" in annotation and annotation["image_id"] is not None and not isinstance(annotation["image_id"],str):
            raise ValueError("Invalid annotation image identifier.")
        if "text" in annotation and (not isinstance(annotation["text"],str) or len(annotation["text"])>10000):
            raise ValueError("Invalid annotation text.")
        if "points" in annotation:
            points=annotation["points"]
            if not isinstance(points,list) or len(points)>100000:
                raise ValueError("Invalid brush points.")
            total_points+=len(points)
            if total_points>1000000: raise ValueError("Too many brush points.")
            for p in points: point(p,"brush point")


def save_workspace(path, items, state, annotations):
    path = Path(path)
    _validate_metadata(state,annotations)
    if len(items) > 1000 or len({item.id for item in items}) != len(items):
        raise ValueError("A workspace supports at most 1000 uniquely identified images.")
    entries = []
    total = 0
    for i,item in enumerate(items):
        arrays = {}
        for kind in ("pixels","original","channel_base"):
            a = validate_image(getattr(item,kind))
            total += a.nbytes + 512
            arrays[kind] = f"images/{i}/{kind}.npy"
        entries.append({"id":item.id,"name":item.name,"history":item.history,"channel_values":item.channel_values,"arrays":arrays})
    if total > MAX_WORKSPACE_BYTES:
        raise ValueError("Workspace is too large; maximum uncompressed size is 2 GiB.")
    manifest = _json_bytes({"format":"imspect-windows","version":1,"items":entries,"state":state,"annotations":annotations})
    if len(manifest)>MAX_METADATA_BYTES:
        raise ValueError("Workspace metadata is too large.")
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,temp_path = tempfile.mkstemp(prefix=path.name+".",suffix=".tmp",dir=str(path.parent))
    os.close(fd)
    try:
        with zipfile.ZipFile(temp_path,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=3,allowZip64=True) as z:
            z.writestr("manifest.json",manifest)
            for i,item in enumerate(items):
                for kind,entry in entries[i]["arrays"].items():
                    with z.open(entry,"w",force_zip64=True) as f:
                        np.save(f,np.asarray(getattr(item,kind),dtype=np.float32),allow_pickle=False)
        os.replace(temp_path,path)
    except BaseException:
        Path(temp_path).unlink(missing_ok=True)
        raise


def _read_array(z, name, infos):
    if not isinstance(name,str) or name not in infos or infos[name].file_size > MAX_PIXELS*16+1024:
        raise ValueError("Invalid workspace image member.")
    with z.open(name) as stream:
        try:
            version = np.lib.format.read_magic(stream)
            if version == (1,0):
                shape,fortran,dtype = np.lib.format.read_array_header_1_0(stream)
            elif version == (2,0):
                shape,fortran,dtype = np.lib.format.read_array_header_2_0(stream)
            else:
                raise ValueError("Unsupported array format.")
            if len(shape)!=3 or shape[2]!=4 or not all(isinstance(x,int) and x>0 for x in shape) or shape[0]*shape[1]>MAX_PIXELS or dtype != np.dtype("float32"):
                raise ValueError("Invalid workspace array dimensions or type.")
            payload_bytes = math.prod(shape)*dtype.itemsize
            if payload_bytes != infos[name].file_size-stream.tell():
                raise ValueError("Truncated or oversized workspace array.")
        except Exception as exc:
            raise ValueError("Invalid workspace image: " + str(exc)) from exc
    with z.open(name) as stream:
        return validate_image(np.load(stream,allow_pickle=False))


def load_workspace(path):
    try:
        with zipfile.ZipFile(path,"r") as z:
            listed = z.infolist()
            infos = {i.filename:i for i in listed}
            if len(listed)>3001 or len(infos)!=len(listed) or sum(i.file_size for i in listed)>MAX_WORKSPACE_BYTES+MAX_METADATA_BYTES:
                raise ValueError("Workspace archive exceeds size limits or contains duplicate entries.")
            if "manifest.json" not in infos or infos["manifest.json"].file_size>MAX_METADATA_BYTES:
                raise ValueError("Missing or oversized workspace manifest.")
            if any(i.flag_bits & 1 or i.filename.startswith(("/","\\")) or ".." in i.filename.replace("\\","/").split("/") for i in listed):
                raise ValueError("Unsupported archive entry.")
            def reject_constant(value):
                raise ValueError("Non-finite workspace metadata.")
            metadata = json.loads(z.read("manifest.json"),parse_constant=reject_constant)
            if not isinstance(metadata,dict) or metadata.get("format")!="imspect-windows" or metadata.get("version")!=1:
                raise ValueError("This is not a supported Windows .imspectw workspace.")
            entries = metadata.get("items")
            state,annotations = metadata.get("state"),metadata.get("annotations")
            if not isinstance(entries,list) or len(entries)>1000 or not isinstance(state,dict) or not isinstance(annotations,list):
                raise ValueError("Invalid workspace structure.")
            _validate_metadata(state,annotations)
            result = []
            identifiers = set()
            for entry in entries:
                if not isinstance(entry,dict) or not isinstance(entry.get("id"),str) or not entry["id"] or entry["id"] in identifiers or not isinstance(entry.get("name"),str):
                    raise ValueError("Invalid or duplicate image identifier.")
                identifiers.add(entry["id"])
                if not isinstance(entry.get("arrays"),dict):
                    raise ValueError("Missing image arrays.")
                arrays = {kind:_read_array(z,entry["arrays"].get(kind),infos) for kind in ("pixels","original","channel_base")}
                item = ImageItem(id=entry["id"],name=entry["name"],history=entry.get("history",[]),channel_values=entry.get("channel_values",[0,0,0]),**arrays)
                result.append(item)
            return result,state,annotations
    except (zipfile.BadZipFile,json.JSONDecodeError,UnicodeError,KeyError,TypeError,OverflowError,RecursionError) as exc:
        raise ValueError("Could not open this Windows workspace: " + str(exc)) from exc
