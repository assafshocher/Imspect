"""Real Qt rendering and end-to-end checks used against the Windows executable."""
from __future__ import annotations

import hashlib
import json
import math
import platform
from pathlib import Path
import sys
import time
import traceback

import numpy as np
from PySide6.QtCore import QPoint,Qt
from PySide6.QtTest import QTest
from PySide6.QtGui import QImage
from PySide6.QtWidgets import QApplication

from . import engine
from .model import save_workspace,load_workspace


def run_smoke(app,window,out):
    out.mkdir(parents=True,exist_ok=True)
    checks=[]
    report={'ok':False,'platform':platform.platform(),'python':platform.python_version(),
            'qt_platform':app.platformName(),'frozen':bool(getattr(sys,'frozen',False)),
            'executable':sys.executable,'checks':checks,'screenshots':[],
            'scope':'Automated Qt interactions and rendering, including installed executable. No physical mouse or monitor calibration validation.'}
    def check(condition,label):
        if not condition:raise AssertionError(label)
        checks.append(label)
    def wait_ready():
        deadline=time.monotonic()+40
        while time.monotonic()<deadline:
            app.processEvents()
            # qWait inside the smoke's timer callback can hold the Python GIL,
            # starving worker jobs. Pump Qt, then explicitly yield to workers.
            time.sleep(.01)
            if not window.jobs and not window.metric_timer.isActive() and not window.edit_busy:
                app.processEvents();return
        raise TimeoutError('Image/edit/metric operations did not finish in40seconds')
    def capture(name):
        app.processEvents()
        QTest.qWait(150)
        filename=name+'.png'
        check(window.grab().save(str(out/filename)),name+' screenshot saved')
        image=QImage(str(out/filename))
        check(image.width()>1000 and image.height()>600,name+' screenshot dimensions')
        report['screenshots'].append(filename)
    try:
        window.testing=True
        window.load_demo()
        wait_ready()
        check(len(window.items)>=3,'demo images loaded')
        check(window.canvas.width()>300 and window.canvas.height()>300,'expanding comparison layout')
        check(window.metric_results and any('psnr' in r for r in window.metric_results),'reference metrics calculated')
        capture('01-split')
        window.select_image(1)
        window.mode_combo.setCurrentIndex(1)
        window.canvas.setFocus()
        window.canvas.zoom_by(2.5)
        window.canvas.pan(3.25,-1.5)
        center,zoom=window.canvas.center,window.canvas.zoom
        previous=window.selected
        QTest.keyClick(window.canvas,Qt.Key.Key_Space)
        check(window.selected!=previous,'Space flickers pair')
        check(window.canvas.center==center and window.canvas.zoom==zoom,'flicker preserves shared viewport')
        QTest.keyClick(window.canvas,Qt.Key.Key_3)
        check(window.selected==2,'number key selects image')
        window.play_all.setChecked(True)
        window.speed.setValue(100)
        window.toggle_play()
        initial=window.selected
        seen={initial}
        deadline=time.monotonic()+.7
        while time.monotonic()<deadline:
            QTest.qWait(30);seen.add(window.selected)
        window.stop_play()
        check(len(seen)>=3,'sequential playback visits all images')
        check(window.canvas.center==center and window.canvas.zoom==zoom,'playback preserves viewport')
        capture('02-flicker')
        window.mode_combo.setCurrentIndex(2)
        window.canvas.fit()
        panel=window.canvas._panels()[0][2]
        start=QPoint(round(panel.left()+panel.width()*.5),round(panel.center().y()))
        end=QPoint(round(panel.left()+panel.width()*.75),round(panel.center().y()))
        QTest.mousePress(window.canvas,Qt.MouseButton.LeftButton,Qt.KeyboardModifier.NoModifier,start)
        QTest.mouseMove(window.canvas,end,30)
        QTest.mouseRelease(window.canvas,Qt.MouseButton.LeftButton,Qt.KeyboardModifier.NoModifier,end)
        check(window.canvas.wipe_position>.65,'manual wipe boundary moves')
        window.toggle_play();QTest.qWait(200);window.stop_play()
        check(window.canvas.wipe_position!=.75,'wipe autoplay moves boundary')
        capture('03-wipe')
        window.mode_combo.setCurrentIndex(0)
        window.select_image(1)
        window.edits_all.setChecked(False)
        before_ref=window.items[0].pixels.copy()
        before=window.items[1].pixels.copy()
        center,zoom=window.canvas.center,window.canvas.zoom
        window.edit_combo.setCurrentIndex(window.edit_combo.findData('noise'))
        window.amount_spin.setValue(20)
        window.apply_edit();wait_ready()
        check(window.selected==1,'single edit retains selected image')
        check(window.canvas.center==center and window.canvas.zoom==zoom,'edit retains viewport')
        check(np.array_equal(window.items[0].pixels,before_ref),'single edit leaves reference unchanged')
        check(not np.array_equal(window.items[1].pixels,before),'noise actually changes selected pixels')
        noisy_mse=engine.metrics(before_ref,window.items[1].pixels)['mse']
        window.edit_combo.setCurrentIndex(window.edit_combo.findData('bilateral'))
        window.amount_spin.setValue(.15)
        window.apply_edit();wait_ready()
        filtered_mse=engine.metrics(before_ref,window.items[1].pixels)['mse']
        check(math.isfinite(noisy_mse) and math.isfinite(filtered_mse) and noisy_mse!=filtered_mse,'metrics recalculate after noise and bilateral filter')
        window.edits_all.setChecked(True)
        window.edit_combo.setCurrentIndex(window.edit_combo.findData('grayscale'))
        window.apply_edit();wait_ready()
        check(all(np.allclose(i.pixels[...,0],i.pixels[...,1]) for i in window.items),'linked edit applies to every image')
        window.undo_edit();wait_ready()
        check(np.array_equal(window.items[0].pixels,before_ref),'linked undo restores reference pixels')
        window.edits_all.setChecked(False)
        before_channels=window.items[1].pixels.copy()
        window._channel_started()
        window.channels[0].setValue(-20)
        window.channels[0].setValue(-70)
        window._channel_finished()
        check(np.allclose(window.items[1].pixels[...,0],before_channels[...,0]*.3),'RGB gain has fixed baseline')
        window.undo_edit();wait_ready()
        check(np.array_equal(window.items[1].pixels,before_channels),'one slider gesture is one undo')
        window.canvas.roi=(20,20,40,35)
        window._roi_changed(window.canvas.roi);wait_ready()
        check(any(r.get('pixels')==1400 for r in window.metric_results),'matched crop changes metric pixel count')
        window.copy_image()
        check(QApplication.clipboard().image().size().width()==40,'crop copied to clipboard')
        count=len(window.items)
        window.paste_image()
        check(len(window.items)==count+1,'clipboard image added to comparison')
        window.select_image(len(window.items)-1)
        window.list.setFocus();QTest.keyClick(window.list,Qt.Key.Key_Delete)
        check(len(window.items)==count,'Delete removes focused sidebar image')
        window.clear_roi()
        window.canvas.annotations=[{'id':'smoke-circle','tool':'circle','start':[50,50],'end':[120,120],
            'image_id':None,'width':3,'color':'#ffffc857','font_size':24}]
        window.canvas.invalidate()
        annotated=window.canvas.export_image(0)
        check(not annotated.isNull(),'annotation export works')
        annotated.save(str(out/'annotation-export.png'))
        session=out/'smoke.imspectw'
        save_workspace(session,window.items,window.session_state(),window.canvas.annotations)
        restored,state,annotations=load_workspace(session)
        check(len(restored)==len(window.items) and len(annotations)==1,'workspace restores image set and annotations')
        check(all(np.array_equal(a.pixels,b.pixels) for a,b in zip(window.items,restored)),'workspace pixels roundtrip losslessly')
        window.open_session(str(session));wait_ready()
        for view in ['difference','mse','ssim','fft']:
            window.view_combo.setCurrentIndex(window.view_combo.findData(view));wait_ready()
            check(not window.canvas.export_image(0).isNull(),view+' derived view renders')
        capture('04-fft')
        window.view_combo.setCurrentIndex(0)
        window.kernel_combo.setCurrentIndex(0)
        window.canvas.zoom=12
        window.canvas.center=(80,80)
        window.canvas.invalidate()
        app.processEvents()
        nearest=window.canvas.grab().toImage()
        window.kernel_combo.setCurrentIndex(2)
        app.processEvents()
        cubic=window.canvas.grab().toImage()
        check(nearest!=cubic,'changing kernel changes deep-zoom pixels immediately')
        window.canvas.fit();wait_ready()
        window.toggle_full_screen();QTest.qWait(150)
        check(window.isFullScreen(),'full screen enters')
        window.toggle_full_screen();QTest.qWait(150)
        check(not window.isFullScreen(),'full screen exits')
        capture('05-final')
        report['ok']=True
        report['metrics_example']={'noise_mse':noisy_mse,'bilateral_mse':filtered_mse}
        return 0
    except Exception:
        report['error']=traceback.format_exc()
        try:capture('failure')
        except Exception:pass
        return 1
    finally:
        window.stop_play()
        report['check_count']=len(checks)
        (out/'report.json').write_text(json.dumps(report,indent=2,allow_nan=False),encoding='utf-8')
