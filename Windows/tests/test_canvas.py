"""Native widget interaction checks, run unchanged on macOS and Windows."""
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from types import SimpleNamespace

import numpy as np
import pytest
from PySide6.QtCore import QPoint, QPointF, Qt
from PySide6.QtGui import QColor
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from imspect.canvas import ComparisonCanvas


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def make_item(name, rgb, width=80, height=60):
    pixels = np.ones((height, width, 4), np.float32)
    pixels[..., :3] = rgb
    return SimpleNamespace(id=name, name=name, pixels=pixels, revision=0)


@pytest.fixture
def canvas(app):
    widget = ComparisonCanvas()
    widget.resize(900, 420)
    widget.kernel = "nearest"
    widget.set_images([make_item("red", (1, 0, 0)), make_item("blue", (0, 0, 1))])
    widget.show()
    widget.one_to_one()
    app.processEvents()
    yield widget
    widget.close()
    widget.deleteLater()
    app.processEvents()


def point(widget, source, index=0):
    content = next(content for item, _, content in widget._panels() if item == index)
    return widget._canvas_point(source, content).toPoint()


def color_at_center(widget, index=0):
    content = next(content for item, _, content in widget._panels() if item == index)
    screenshot = widget.grab().toImage()
    dpr = screenshot.devicePixelRatio()
    center = content.center()
    return screenshot.pixelColor(round(center.x() * dpr), round(center.y() * dpr))


def test_split_panels_show_different_images_without_different_geometry(canvas, app):
    assert color_at_center(canvas, 0).red() > 250
    assert color_at_center(canvas, 1).blue() > 250
    canvas.pan(7, -3)
    app.processEvents()
    a, b = canvas._panels()
    sample_a = canvas._source_point(a[2].center(), a[2])
    sample_b = canvas._source_point(b[2].center(), b[2])
    assert sample_a == sample_b == QPointF(47, 27)


def test_flicker_selection_and_edit_never_recenter_or_rescale(canvas, app):
    canvas.set_mode("flicker")
    canvas.zoom_by(2.5)
    canvas.pan(5.25, -2.5)
    state = (canvas.zoom, canvas.center)
    assert color_at_center(canvas).red() > 250
    canvas.set_images(canvas.items, selected=1, partner=0, reference=0)
    app.processEvents()
    assert color_at_center(canvas, 1).blue() > 250
    edited = canvas.items[1]
    edited.pixels = edited.pixels.copy()
    edited.pixels[..., :3] = (.25, .75, .5)
    edited.revision += 1
    canvas.set_images(canvas.items, selected=1, partner=0, reference=0)
    app.processEvents()
    assert (canvas.zoom, canvas.center) == state
    assert canvas.selected_index == 1
    color = color_at_center(canvas, 1)
    assert abs(color.green() - 191) <= 1


def test_zoom_around_mouse_keeps_source_point_under_pointer(canvas, app):
    content = canvas._panels()[0][2]
    anchor = content.center() + QPointF(19, -13)
    before = canvas._source_point(anchor, content)
    canvas.zoom_by(4, anchor)
    after = canvas._source_point(anchor, content)
    assert abs(before.x() - after.x()) < 1e-8
    assert abs(before.y() - after.y()) < 1e-8
    assert canvas.zoom == 4


def test_keyboard_numbers_space_tab_and_pixel_pan(canvas, app):
    selected, cycles, modes = [], [], []
    canvas.selected.connect(selected.append)
    canvas.cycleRequested.connect(cycles.append)
    canvas.modeRequested.connect(lambda: modes.append(True))
    QTest.keyClick(canvas, Qt.Key.Key_2)
    QTest.keyClick(canvas, Qt.Key.Key_Space)
    QTest.keyClick(canvas, Qt.Key.Key_N)
    QTest.keyClick(canvas, Qt.Key.Key_BracketLeft)
    QTest.keyClick(canvas, Qt.Key.Key_Tab)
    previous = canvas.center
    QTest.keyClick(canvas, Qt.Key.Key_Right, Qt.KeyboardModifier.AltModifier)
    assert selected == [1]
    assert cycles == [0, 1, -1]
    assert len(modes) == 1
    assert canvas.center == (previous[0] + 1, previous[1])


def test_inspect_and_roi_are_source_pixels_and_match_both_views(canvas, app):
    pixels, regions = [], []
    canvas.zoom_by(4)
    canvas.pixelPicked.connect(pixels.append)
    canvas.roiChanged.connect(regions.append)
    canvas.set_tool("inspect")
    QTest.mouseClick(canvas, Qt.MouseButton.LeftButton, pos=point(canvas, (12.5, 18.5)))
    assert pixels[-1] == (12, 18)
    canvas.set_tool("select")
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=point(canvas, (10, 10)))
    QTest.mouseMove(canvas, point(canvas, (30, 35)))
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=point(canvas, (30, 35)))
    assert regions[-1] == canvas.roi
    x, y, width, height = canvas.roi
    # Half-point panel boundaries can round the OS integer mouse coordinates.
    assert abs(x - 10) <= 1 and abs(y - 10) <= 1
    assert abs(width - 20) <= 1 and abs(height - 25) <= 1
    result = canvas.export_image(1, canvas.roi)
    assert (result.width(), result.height()) == (width, height)
    assert result.pixelColor(width // 2, height // 2).blue() > 250
    QTest.keyClick(canvas, Qt.Key.Key_Escape)
    assert canvas.roi is None and regions[-1] is None


def test_brush_shared_annotation_is_exported_on_both_and_delete_undoes(canvas, app):
    canvas.draw_color = QColor("#00ff00")
    canvas.draw_width = 8
    canvas.set_tool("brush")
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=point(canvas, (20, 30)))
    QTest.mouseMove(canvas, point(canvas, (35, 30)))
    QTest.mouseMove(canvas, point(canvas, (45, 30)))
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=point(canvas, (50, 30)))
    assert len(canvas.annotations) == 1
    assert canvas.annotations[0]["image_id"] is None
    assert len(canvas.annotations[0]["points"]) >= 3
    for index in (0, 1):
        result = canvas.export_image(index)
        assert result.pixelColor(35, 30).green() > 245
    # Overlay drawing must never alter measured source samples.
    assert canvas.items[0].pixels[30, 35, 1] == 0
    QTest.keyClick(canvas, Qt.Key.Key_Delete)
    assert canvas.annotations == []
    assert canvas.export_image(0).pixelColor(35, 30).red() > 250


def test_image_specific_dot_does_not_leak_to_other_images(canvas, app):
    canvas.shared_annotations = False
    canvas.draw_color = QColor("#00ff00")
    canvas.draw_width = 9
    canvas.set_tool("dot")
    QTest.mouseClick(canvas, Qt.MouseButton.LeftButton, pos=point(canvas, (40.5, 30.5)))
    assert canvas.annotations[0]["image_id"] == "red"
    assert canvas.export_image(0).pixelColor(40, 30).green() > 245
    assert canvas.export_image(1).pixelColor(40, 30).blue() > 250


def test_wipe_has_both_sources_and_can_drag_boundary(canvas, app):
    canvas.set_images(canvas.items, selected=1, partner=0, reference=0)
    canvas.set_mode("wipe")
    canvas.zoom = 5
    canvas.wipe_position = .5
    canvas.invalidate()
    app.processEvents()
    content = canvas._panels()[0][2]
    snapshot = canvas.grab().toImage()
    dpr = snapshot.devicePixelRatio()
    left = content.center() + QPointF(-30, 0)
    right = content.center() + QPointF(30, 0)
    assert snapshot.pixelColor(round(left.x()*dpr), round(left.y()*dpr)).red() > 250
    assert snapshot.pixelColor(round(right.x()*dpr), round(right.y()*dpr)).blue() > 250
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=content.center().toPoint())
    target = QPoint(round(content.left() + .8 * content.width()), round(content.center().y()))
    QTest.mouseMove(canvas, target)
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=target)
    assert abs(canvas.wipe_position - .8) < .01


def test_flicker_click_switches_but_drag_only_pans(canvas, app):
    canvas.set_mode("flicker")
    cycles = []
    canvas.cycleRequested.connect(cycles.append)
    content = canvas._panels()[0][2]
    start = content.center().toPoint()
    QTest.mouseClick(canvas, Qt.MouseButton.LeftButton, pos=start)
    previous = canvas.center
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=start)
    QTest.mouseMove(canvas, start + QPoint(30, 20))
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=start + QPoint(30, 20))
    assert cycles == [0]
    assert canvas.center == (previous[0] - 30, previous[1] - 20)


def test_fft_keeps_spatial_annotations_out_of_frequency_export(canvas, app):
    canvas.annotations = [{"tool": "rectangle", "start": [0, 0], "end": [100, 100],
                           "width": 30, "color": "#ff00ff00", "image_id": None}]
    canvas.view_mode = "fft"
    canvas.roi = (10, 10, 5, 5)
    canvas.invalidate()
    exported = canvas.export_image(0, canvas.roi)
    assert (exported.width(), exported.height()) == (128, 64)
    canvas.set_tool("inspect")
    calls = []
    canvas.pixelPicked.connect(calls.append)
    QTest.mouseClick(canvas, Qt.MouseButton.LeftButton, pos=canvas._panels()[0][2].center().toPoint())
    assert calls == []


def test_many_images_and_small_canvas_remain_regular_and_clearable(canvas, app):
    images = [make_item(str(i), (i / 8, 0, .3)) for i in range(8)]
    canvas.resize(240, 200)
    canvas.set_images(images)
    canvas.fit()
    app.processEvents()
    assert len(canvas._panels()) == 8
    content_sizes = {(round(p.width(), 5), round(p.height(), 5)) for _, _, p in canvas._panels()}
    assert len(content_sizes) == 1
    assert not canvas.grab().isNull()
    canvas.set_images([])
    app.processEvents()
    assert canvas._panels() == []
    assert not canvas.grab().isNull()


def test_invalid_difference_shows_error_instead_of_crashing(canvas, app):
    canvas.items[1].pixels = np.ones((20, 30, 4), np.float32)
    canvas.items[1].revision += 1
    canvas.view_mode = "difference"
    canvas.invalidate()
    app.processEvents()
    assert not canvas.grab().isNull()
    assert canvas._last_error
