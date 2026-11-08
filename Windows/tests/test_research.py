"""Optional worker integration, without model downloads or subprocesses."""
import json
import os
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import numpy as np
import pytest
from PySide6.QtCore import QProcess
from PySide6.QtWidgets import QApplication, QMessageBox

from imspect import engine
from imspect.model import ImageItem
from imspect.research import ResearchDialog


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def dialog(app, monkeypatch):
    item=ImageItem.from_array("Candidate",np.ones((80,100,4),np.float32))
    result=ResearchDialog(item,item,(21,9,64,64))
    monkeypatch.setattr(QMessageBox,"warning",lambda *args:QMessageBox.StandardButton.Ok)
    monkeypatch.setattr(QMessageBox,"information",lambda *args:QMessageBox.StandardButton.Ok)
    monkeypatch.setattr(result,"start",lambda *args:True)
    yield result
    result.close()
    result.deleteLater()
    app.processEvents()


def old_result(dialog):
    dialog.result={"ok":True,"heatmap":"stale.png"}
    dialog.map_result=np.ones((1,1,4),np.float32)
    dialog._map_context=((80,100),None)
    dialog.add_map.setEnabled(True)
    dialog.save.setEnabled(True)


def assert_cleared(dialog):
    assert dialog.result is None
    assert dialog.map_result is None
    assert not dialog.add_map.isEnabled()
    assert not dialog.save.isEnabled()


def test_lpips_roi_map_uses_original_source_coordinates(dialog,tmp_path,monkeypatch):
    pixels=np.ones((64,64,4),np.float32)
    pixels[...,0]=.25
    path=tmp_path/"map.png"
    engine.save_png(pixels,path)
    dialog.result={"ok":True,"heatmap":str(path)}
    dialog._map_context=((80,100),(21,9,64,64))
    accepted=[]
    monkeypatch.setattr(dialog,"accept",lambda:accepted.append(True))
    dialog.accept_map()
    assert accepted==[True]
    assert dialog.map_result.shape==(80,100,4)
    np.testing.assert_allclose(dialog.map_result[9:73,21:85],pixels,atol=1/65535)
    outside=dialog.map_result.copy()
    outside[9:73,21:85]=0
    assert not np.any(outside)


def test_full_image_map_retains_dimensions(dialog,tmp_path,monkeypatch):
    pixels=np.ones((80,100,4),np.float32)
    path=tmp_path/"map.png"
    engine.save_png(pixels,path)
    dialog.result={"ok":True,"heatmap":str(path)}
    dialog._map_context=((80,100),None)
    monkeypatch.setattr(dialog,"accept",lambda:None)
    dialog.accept_map()
    np.testing.assert_array_equal(dialog.map_result,pixels)


@pytest.mark.parametrize("roi",[None,(21,9,64,64)])
def test_wrong_map_dimensions_are_rejected(dialog,tmp_path,monkeypatch,roi):
    path=tmp_path/"wrong.png"
    engine.save_png(np.ones((32,32,4),np.float32),path)
    old_result(dialog)
    dialog.result={"ok":True,"heatmap":str(path)}
    dialog._map_context=((80,100),roi)
    accepted=[]
    monkeypatch.setattr(dialog,"accept",lambda:accepted.append(True))
    dialog.accept_map()
    assert not accepted
    assert_cleared(dialog)


def test_new_request_clears_previous_score_map_and_response(dialog):
    old_result(dialog)
    response=Path(dialog.temp.name)/"response.json"
    response.write_text('{"ok":true,"score":0.5}')
    dialog.request({"protocol":1,"operation":"capabilities"})
    assert_cleared(dialog)
    assert dialog._map_context is None
    assert not response.exists()


def test_validation_failure_clears_previous_result(dialog):
    old_result(dialog)
    dialog.allow.setChecked(False)
    dialog.run_metric()
    assert_cleared(dialog)


def test_process_error_clears_previous_result(dialog):
    old_result(dialog)
    dialog.process_error(QProcess.ProcessError.FailedToStart)
    assert_cleared(dialog)


def test_environment_setup_clears_previous_result(dialog,tmp_path,monkeypatch):
    old_result(dialog)
    dialog.local=tmp_path
    monkeypatch.setattr(QMessageBox,"question",lambda *args:QMessageBox.StandardButton.Yes)
    dialog.install_environment()
    assert_cleared(dialog)


def test_metric_request_retains_source_geometry_and_declared_quantization(dialog):
    dialog.allow.setChecked(True)
    dialog.map.setChecked(True)
    dialog.run_metric()
    payload=json.loads((Path(dialog.temp.name)/"request.json").read_text())
    assert payload["operation"]=="lpips"
    assert payload["roi"]==[21,9,64,64]
    assert payload["heatmap_max"]==1
    assert dialog._map_context==((80,100),(21,9,64,64))
    assert engine.load_image(payload["image"]).shape==(80,100,4)


def test_malformed_response_clears_stale_map(dialog):
    old_result(dialog)
    (Path(dialog.temp.name)/"response.json").write_text("not json")
    dialog.stage="metric"
    dialog.finished(0,QProcess.ExitStatus.NormalExit)
    assert_cleared(dialog)
