"""End-to-end Qt workspace behaviour without interactive file dialogs."""
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import time
from threading import Event

import numpy as np
import png
import pytest
from PySide6.QtCore import QPoint, Qt
from PySide6.QtGui import QColor
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QFileDialog, QMessageBox, QScrollArea

from imspect.app import MainWindow, apply_style
from imspect import engine


@pytest.fixture(scope="module")
def app():
    application = QApplication.instance() or QApplication([])
    apply_style(application)
    return application


def wait_until(app, predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        app.processEvents()
        if predicate():
            return
        time.sleep(.005)
    raise AssertionError("Asynchronous Qt operation did not finish before the timeout.")


def settled(app, window):
    wait_until(app, lambda: not window.edit_busy and not window.jobs and not window.metric_timer.isActive())
    app.processEvents()


@pytest.fixture
def window(app):
    result = MainWindow()
    result.testing = True
    result.resize(1480, 900)
    result.show()
    app.processEvents()
    yield result
    result.stop_play()
    settled(app, result)
    result.dirty = False
    result.close()
    result.deleteLater()
    app.processEvents()


def solid(rgb=(.5, .5, .5), width=48, height=40):
    result = np.ones((height, width, 4), np.float32)
    result[..., :3] = rgb
    return result


def pair(window, app):
    data = solid()
    window.add_arrays([("Reference", data), ("Candidate", data.copy())])
    window.select_image(1)
    settled(app, window)
    return data


def choose(combo, value):
    index = combo.findData(value)
    assert index >= 0, value
    combo.setCurrentIndex(index)


def candidate_result(window):
    return next(row for row in window.metric_results if row["id"] == window.items[1].id)


def image_read(path):
    width, height, rows, info = png.Reader(filename=str(path)).read()
    return np.vstack(list(rows)).reshape(height, width, info["planes"]), info


def test_demo_initializes_complete_workspace_and_metrics(window, app):
    window.load_demo()
    settled(app, window)
    assert len(window.items) == window.list.count() == 3
    assert "REF" in window.list.item(0).text()
    assert window.histogram.values.shape == (3, 256)
    assert len(window.metric_results) == 3
    assert window.metric_results[0]["reference"]
    assert window.metric_results[1]["mse"] > 0
    assert "Calculating" not in window.metric_label.text()
    assert window.canvas.zoom > 0
    assert not window.grab().isNull()


def test_single_noise_then_bilateral_refreshes_metrics_and_keeps_view(window, app):
    original = pair(window, app)
    choose(window.mode_combo, "flicker")
    window.canvas.zoom_by(3)
    window.canvas.pan(2.25, -1.5)
    view = (window.canvas.zoom, window.canvas.center)
    scroll = window.findChild(QScrollArea)
    scroll.verticalScrollBar().setValue(scroll.verticalScrollBar().maximum())
    scroll_position = scroll.verticalScrollBar().value()
    choose(window.edit_combo, "noise")
    window.amount_spin.setValue(25)
    window.apply_edit()
    settled(app, window)
    noisy = candidate_result(window)
    assert noisy["mse"] > .005
    assert noisy["psnr"] < 30
    assert not np.array_equal(window.items[1].pixels, original)
    np.testing.assert_array_equal(window.items[0].pixels, original)
    assert window.selected == window.canvas.selected_index == 1
    assert (window.canvas.zoom, window.canvas.center) == view
    assert scroll.verticalScrollBar().value() == scroll_position
    choose(window.edit_combo, "bilateral")
    window.amount_spin.setValue(.3)
    window.apply_edit()
    settled(app, window)
    filtered = candidate_result(window)
    assert filtered["mse"] < noisy["mse"] * .5
    assert filtered["psnr"] > noisy["psnr"]
    assert filtered["ssim"] > noisy["ssim"]
    assert window.selected == 1
    assert (window.canvas.zoom, window.canvas.center) == view
    assert len(window.items[1]._undo) == 2


def test_all_image_edits_include_reference_and_undo_together(window, app):
    original = pair(window, app)
    window.edits_all.setChecked(True)
    choose(window.edit_combo, "noise")
    window.amount_spin.setValue(12)
    window.seed_spin.setValue(123)
    window.apply_edit()
    settled(app, window)
    assert not np.array_equal(window.items[0].pixels, original)
    # Identical inputs and the same seed give identical linked edits.
    np.testing.assert_array_equal(window.items[0].pixels, window.items[1].pixels)
    assert candidate_result(window)["mse"] == 0
    assert all(len(item._undo) == 1 for item in window.items)
    assert window.selected == 1
    window.undo_edit()
    settled(app, window)
    for item in window.items:
        np.testing.assert_array_equal(item.pixels, original)


def test_delete_in_sidebar_removes_image_but_canvas_delete_only_annotation(window, app):
    pair(window, app)
    window.canvas.annotations = [{"tool": "dot", "start": [3.5, 4.5], "end": [3.5, 4.5],
                                  "image_id": None, "width": 3, "color": "#ff00ff00"}]
    QTest.keyClick(window.canvas, Qt.Key.Key_Delete)
    assert len(window.items) == 2 and not window.canvas.annotations
    window.list.setCurrentRow(1)
    QTest.keyClick(window.list, Qt.Key.Key_Delete)
    settled(app, window)
    assert len(window.items) == window.list.count() == 1
    assert window.items[0].name == "Reference"
    assert window.reference == window.selected == 0


def test_mode_and_play_updates_do_not_collapse_layout(window, app):
    pair(window, app)
    initial_center_width = window.canvas.parentWidget().width()
    for mode in ("flicker", "wipe", "split", "flicker"):
        choose(window.mode_combo, mode)
        app.processEvents()
        assert window.canvas.parentWidget().width() == initial_center_width
        assert window.canvas.width() > 350
    window.toggle_play()
    QTest.qWait(150)
    assert window.timer.isActive()
    assert window.canvas.parentWidget().width() == initial_center_width
    window.stop_play()
    window.toggle_full_screen()
    app.processEvents()
    assert window.isFullScreen()
    central = window.centralWidget()
    top_left = window.canvas.mapTo(central, QPoint(0, 0))
    assert top_left.x() >= 0 and top_left.y() >= 0
    assert top_left.x() + window.canvas.width() <= central.width()
    assert top_left.y() + window.canvas.height() <= central.height()
    window.toggle_full_screen()
    app.processEvents()
    assert not window.isFullScreen()


def test_rgb_slider_gesture_is_fixed_baseline_and_single_undo(window, app):
    original = pair(window, app)
    window._channel_started()
    window.channels[0].setValue(25)
    window.channels[0].setValue(50)
    window.channels[0].setValue(75)
    assert len(window.items[1]._undo) == 0
    np.testing.assert_allclose(window.items[1].pixels[..., 0], .875)
    window._channel_finished()
    settled(app, window)
    assert len(window.items[1]._undo) == 1
    assert window.items[1].channel_values == [.75, 0, 0]
    window.undo_edit()
    settled(app, window)
    np.testing.assert_array_equal(window.items[1].pixels, original)
    assert [slider.value() for slider in window.channels] == [0, 0, 0]
    window.channels[1].setValue(-100)
    np.testing.assert_array_equal(window.items[1].pixels[..., 1], 0)
    window.channels[2].setValue(100)
    np.testing.assert_array_equal(window.items[1].pixels[..., 2], 1)


def test_copy_roi_and_paste_adds_image_without_reframing(window, app):
    pair(window, app)
    window.canvas.roi = (4, 5, 12, 14)
    window._roi_changed(window.canvas.roi)
    before = (window.canvas.zoom, window.canvas.center)
    window.copy_image()
    copied = QApplication.clipboard().image()
    assert (copied.width(), copied.height()) == (12, 14)
    window.paste_image()
    settled(app, window)
    assert len(window.items) == 3
    assert window.items[2].pixels.shape == (14, 12, 4)
    assert (window.canvas.zoom, window.canvas.center) == before
    np.testing.assert_allclose(window.items[2].pixels[..., :3], 128/255)


def test_export_difference_is_16bit_difference_instead_of_source(window, app, monkeypatch, tmp_path):
    reference = solid((.2, .3, .4))
    candidate = solid((.8, .5, .1))
    window.add_arrays([("Reference", reference), ("Candidate", candidate)])
    window.select_image(1)
    choose(window.view_combo, "difference")
    window.canvas.roi = (3, 4, 17, 13)
    output = tmp_path / "difference.png"
    monkeypatch.setattr(QFileDialog, "getSaveFileName", staticmethod(lambda *a, **k: (str(output), "PNG")))
    window.export_image()
    pixels, info = image_read(output)
    assert info["bitdepth"] == 16
    assert pixels.shape[:2] == (13, 17)
    np.testing.assert_allclose(pixels[5, 5, :3] / 65535, [.6, .2, .3], atol=2/65535)
    np.testing.assert_array_equal(window.items[1].pixels, candidate)


def test_workspace_roundtrip_restores_samples_annotations_and_controls(window, app, tmp_path):
    pair(window, app)
    window.channels[0].setValue(40)
    choose(window.mode_combo, "wipe")
    choose(window.kernel_combo, "lanczos3")
    window.canvas.zoom_by(2)
    window.canvas.pan(1.25, -2.75)
    window.canvas.roi = (2, 3, 15, 16)
    window.canvas.wipe_position = .7
    window.canvas.annotations = [{"tool": "circle", "start": [5, 6], "end": [20, 22],
                                  "image_id": None, "width": 2, "color": "#ff32deab"}]
    window.play_all.setChecked(True)
    window.width_spin.setValue(7)
    window.font_spin.setValue(33)
    state = window.session_state()
    image_copy = window.items[1].pixels.copy()
    destination = tmp_path / "comparison.imspectw"
    window.save_session(destination)
    assert destination.is_file()
    assert not window.dirty
    window.items = []
    window._refresh()
    window.open_session(destination)
    settled(app, window)
    np.testing.assert_array_equal(window.items[1].pixels, image_copy)
    assert window.session_state() == state
    assert window.canvas.annotations[0]["tool"] == "circle"
    assert window.channels[0].value() == 40
    assert not window.dirty


def test_opening_related_workspaces_refreshes_histogram_and_metrics(window, app, tmp_path):
    pair(window, app)
    first = tmp_path / "original.imspectw"
    second = tmp_path / "edited.imspectw"
    window.save_session(first)
    window.items[1].apply(solid((.75, .75, .75)), "Changed candidate")
    window.save_session(second)

    window.open_session(first)
    settled(app, window)
    identity = [(item.id, item.revision) for item in window.items]
    assert candidate_result(window)["mse"] == 0
    np.testing.assert_array_equal(window.histogram.values.argmax(axis=1), [128, 128, 128])

    window.open_session(second)
    settled(app, window)
    # Loaded workspaces reset revisions, while stable IDs survive saved branches.
    assert [(item.id, item.revision) for item in window.items] == identity
    assert candidate_result(window)["mse"] == pytest.approx(.25 ** 2)
    np.testing.assert_array_equal(window.histogram.values.argmax(axis=1), [191, 191, 191])
    np.testing.assert_array_equal(window.histogram.reference.argmax(axis=1), [128, 128, 128])


def test_cancel_open_preserves_unsaved_comparison(window, app, monkeypatch, tmp_path):
    pair(window, app)
    incoming = tmp_path / "two-images.imspectw"
    window.save_session(incoming)
    window.remove_image()
    settled(app, window)
    existing = list(window.items)
    prompts = []
    monkeypatch.setattr(QMessageBox, "question", staticmethod(
        lambda *args, **kwargs: prompts.append(args) or QMessageBox.StandardButton.Cancel))
    window.testing = False
    try:
        window.open_session(incoming)
    finally:
        window.testing = True
    assert len(prompts) == 1
    assert window.dirty
    assert len(window.items) == 1
    assert window.items[0] is existing[0]


def test_invalid_regions_mismatched_sizes_and_fft_never_show_fabricated_scores(window, app):
    pair(window, app)
    window.add_arrays([("Different size", solid(width=20, height=20))])
    settled(app, window)
    assert "error" in window.metric_results[2]
    window.canvas.roi = (0, 0, 5, 5)
    window._roi_changed(window.canvas.roi)
    settled(app, window)
    assert window.metric_results[1]["ssim"] is None
    window.canvas.roi = (46, 38, 10, 10)
    window._roi_changed(window.canvas.roi)
    settled(app, window)
    assert "error" in window.metric_results[1]
    choose(window.view_combo, "fft")
    settled(app, window)
    assert "Metrics are spatial" in window.metric_label.text()
    assert "spatial-only" in window.pixel_label.text()
    assert window.metric_results == []


def test_metric_export_waits_for_new_crop_instead_of_exporting_stale_scores(window, app, monkeypatch):
    pair(window, app)
    assert candidate_result(window)["pixels"] == 48 * 40
    release = Event()
    original_metrics = engine.metrics
    messages = []
    dialogs = []

    def delayed_metrics(*args, **kwargs):
        assert release.wait(10), "Test did not release metric calculation."
        return original_metrics(*args, **kwargs)

    monkeypatch.setattr(engine, "metrics", delayed_metrics)
    monkeypatch.setattr(window, "notify_error", lambda error: messages.append(str(error)))
    monkeypatch.setattr(QFileDialog, "getSaveFileName", staticmethod(lambda *a, **k: (dialogs.append(True) or "", "")))
    try:
        window.canvas.roi = (2, 3, 20, 18)
        window._roi_changed(window.canvas.roi)
        wait_until(app, lambda: bool(window.jobs))
        assert window.metric_results == []
        window.export_metrics()
        assert messages and "Wait" in messages[-1]
        assert dialogs == []
    finally:
        release.set()
        settled(app, window)
    assert candidate_result(window)["pixels"] == 20 * 18


def test_changing_interpolation_preserves_samples_and_changes_preview(window, app):
    data = solid(width=24, height=24)
    data[::2, ::2, :3] = 0
    data[1::2, 1::2, :3] = 1
    window.add_arrays([("Target", data)])
    window.canvas.zoom = 9.5
    choose(window.kernel_combo, "nearest")
    before = window.canvas.grab().toImage()
    state = (window.canvas.zoom, window.canvas.center)
    choose(window.kernel_combo, "cubic")
    after = window.canvas.grab().toImage()
    assert before != after
    assert (window.canvas.zoom, window.canvas.center) == state
    np.testing.assert_array_equal(window.items[0].pixels, data)
