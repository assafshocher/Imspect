from __future__ import annotations
import io
import json
import zipfile
import numpy as np
import pytest
from imspect.model import ImageItem,save_workspace,load_workspace


def sample():
    a=np.full((12,16,4),.3,np.float32); a[...,3]=1
    return a


def test_edit_undo_restore_and_independent_copies():
    a=sample(); item=ImageItem.from_array("First",a)
    a[:]=0
    assert item.pixels[0,0,0]==pytest.approx(.3)
    newer=item.pixels.copy(); newer[...,0]=.7
    item.apply(newer,"Red")
    assert item.history==["Red"] and item.revision==1
    assert item.undo()
    assert item.pixels[0,0,0]==pytest.approx(.3)
    assert not item.undo()
    item.apply(newer,"Red"); item.restore()
    np.testing.assert_array_equal(item.pixels,item.original)
    assert item.undo() and item.pixels[0,0,0]==pytest.approx(.7)


def test_channel_drag_is_single_undo_and_fixed_baseline():
    item=ImageItem.from_array("Test",sample())
    item.set_channels([.5,0,0],commit=False)
    item.set_channels([.7,0,0],commit=False)
    item.set_channels([.7,0,0],commit=True)
    assert item.pixels[0,0,0]==pytest.approx(.79)
    assert len(item._undo)==1
    item.set_channels([0,0,0])
    np.testing.assert_array_equal(item.pixels,item.original)
    assert item.undo()
    assert item.channel_values==[.7,0,0]
    assert item.undo()
    np.testing.assert_array_equal(item.pixels,item.original)


def test_workspace_is_selfcontained_and_preserves_gain(tmp_path):
    item=ImageItem.from_array("Some image",sample())
    item.set_channels([.4,-.2,0])
    state={"selected":0,"zoom":2.25,"center":[8,6],"roi":[1,1,4,5]}
    annotations=[{"tool":"line","start":[1,1],"end":[8,9],"color":"#ffcc00","width":2}]
    path=tmp_path/"session.imspectw"
    save_workspace(path,[item],state,annotations)
    items,new_state,new_annotations=load_workspace(path)
    got=items[0]
    assert got.id==item.id and got.name==item.name and got.history==item.history
    assert got.channel_values==item.channel_values and new_state==state and new_annotations==annotations
    np.testing.assert_array_equal(got.pixels,item.pixels)
    np.testing.assert_array_equal(got.original,item.original)
    got.set_channels([0,0,0])
    np.testing.assert_array_equal(got.pixels,got.original)


def test_undo_bounded_and_empty_workspace(tmp_path):
    item=ImageItem.from_array("Test",sample())
    for i in range(15): item.apply(item.pixels,str(i))
    assert len(item._undo)==10
    path=tmp_path/"empty.imspectw"; save_workspace(path,[],{},[])
    assert load_workspace(path)==([],{},[])


def test_bad_workspace_rejected_and_atomic_previous_preserved(tmp_path):
    path=tmp_path/"good.imspectw"; save_workspace(path,[],{},[])
    before=path.read_bytes()
    with pytest.raises(ValueError): save_workspace(path,[],{"zoom":float("nan")},[])
    assert path.read_bytes()==before
    path.write_bytes(b"not a zip")
    with pytest.raises(ValueError): load_workspace(path)
    with zipfile.ZipFile(path,"w") as z:
        z.writestr("manifest.json",json.dumps({"format":"imspect-windows","version":1,"items":[],"state":{},"annotations":[]}))
        z.writestr("../bad",b"x")
    with pytest.raises(ValueError): load_workspace(path)


def test_no_object_array_or_hostile_shape_loading(tmp_path):
    path=tmp_path/"evil.imspectw"
    for array in [np.asarray([object()],dtype=object),np.ones((1,1,4),np.float64)]:
        stream=io.BytesIO(); np.save(stream,array)
        manifest={"format":"imspect-windows","version":1,"items":[{"id":"x","name":"Bad","arrays":dict.fromkeys(["pixels","original","channel_base"],"a.npy")}],"state":{},"annotations":[]}
        with zipfile.ZipFile(path,"w") as z:
            z.writestr("manifest.json",json.dumps(manifest)); z.writestr("a.npy",stream.getvalue())
        with pytest.raises(ValueError): load_workspace(path)


def test_workspace_rejects_invalid_view_and_annotation_metadata(tmp_path):
    path=tmp_path/"bad-state.imspectw"
    for state,annotations in [({"center":[1]},[]),({"zoom":0},[]),({"mode":["split"]},[]),({},[{"tool":"brush","start":[0,0],"points":[[1e99,0]]}])]:
        with pytest.raises(ValueError): save_workspace(path,[],state,annotations)
        manifest={"format":"imspect-windows","version":1,"items":[],"state":state,"annotations":annotations}
        with zipfile.ZipFile(path,"w") as z: z.writestr("manifest.json",json.dumps(manifest))
        with pytest.raises(ValueError): load_workspace(path)
