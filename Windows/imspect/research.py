"""Optional model worker integration; the core executable needs no Python install."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

import numpy as np
from PIL import Image
from PySide6.QtCore import QProcess, QSettings, QStandardPaths, Qt
from PySide6.QtWidgets import (QDialog,QVBoxLayout,QHBoxLayout,QLabel,QLineEdit,QPushButton,
    QComboBox,QCheckBox,QPlainTextEdit,QFileDialog,QMessageBox)

from . import engine


def worker_path():
    root=Path(getattr(sys,'_MEIPASS',Path(__file__).resolve().parents[2]))
    return root/'Research'/'backend.py'


class ResearchDialog(QDialog):
    def __init__(self,item,reference,roi,parent=None):
        super().__init__(parent)
        self.item,self.reference,self.roi=item,reference,roi
        self.map_result=None
        self.map_name='LPIPS map'
        self.result=None
        self.setWindowTitle('Research models · local processing')
        self.resize(690,650)
        self.temp=tempfile.TemporaryDirectory(prefix='imspect-model-')
        self.process=QProcess(self)
        self.process.readyReadStandardOutput.connect(self.read_log)
        self.process.readyReadStandardError.connect(self.read_log)
        self.process.finished.connect(self.finished)
        self.process.errorOccurred.connect(self.process_error)
        self.operation=None
        self.stage=None
        self.settings=QSettings('Imspect','Imspect')
        self.local=Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppLocalDataLocation))
        self.env_path=self.local/'research-env'
        self.env_python=self.env_path/('Scripts/python.exe' if sys.platform=='win32' else 'bin/python')
        layout=QVBoxLayout(self)
        text=QLabel('Optional LPIPS, NIQE, MUSIQ and TOPIQ-NR. Images stay on this computer.\nModel packages and weights are downloaded only when you request them.\nInputs are explicitly converted to 8-bit sRGB. Core app features need no Python.')
        text.setWordWrap(True)
        layout.addWidget(text)
        row=QHBoxLayout();layout.addLayout(row)
        row.addWidget(QLabel('Python 3.10+'))
        default=str(self.env_python) if self.env_python.exists() else (sys.executable if not getattr(sys,'frozen',False) else '')
        self.python=QLineEdit(str(self.settings.value('research_python',default)))
        row.addWidget(self.python,1)
        browse=QPushButton('Browse…');browse.clicked.connect(self.browse);row.addWidget(browse)
        row=QHBoxLayout();layout.addLayout(row)
        self.check=QPushButton('Check environment');self.check.clicked.connect(self.check_environment);row.addWidget(self.check)
        self.install=QPushButton('Set up model environment…');self.install.clicked.connect(self.install_environment);row.addWidget(self.install)
        self.metric=QComboBox()
        for label,value in [('LPIPS · fidelity to reference','lpips'),('NIQE · no reference','niqe'),('MUSIQ · no reference','musiq'),('TOPIQ-NR · no reference','topiq_nr')]:self.metric.addItem(label,value)
        layout.addWidget(self.metric)
        self.device=QComboBox()
        self.device.addItem('CPU','cpu');self.device.addItem('NVIDIA CUDA (requires compatible PyTorch)','cuda')
        if sys.platform=='darwin':self.device.addItem('Apple MPS','mps')
        layout.addWidget(self.device)
        self.allow=QCheckBox('Allow pretrained-weight downloads when running a metric')
        layout.addWidget(self.allow)
        self.map=QCheckBox('Calculate LPIPS spatial map as well (fixed display range 0–1)')
        layout.addWidget(self.map)
        row=QHBoxLayout();layout.addLayout(row)
        self.run=QPushButton('Run selected metric');self.run.clicked.connect(self.run_metric);row.addWidget(self.run)
        self.cancel=QPushButton('Cancel operation');self.cancel.clicked.connect(self.cancel_process);row.addWidget(self.cancel)
        self.log=QPlainTextEdit();self.log.setReadOnly(True);layout.addWidget(self.log,1)
        row=QHBoxLayout();layout.addLayout(row)
        self.save=QPushButton('Save detailed report…');self.save.clicked.connect(self.save_report);row.addWidget(self.save)
        self.add_map=QPushButton('Add map to comparison');self.add_map.setEnabled(False);self.add_map.clicked.connect(self.accept_map);row.addWidget(self.add_map)
        close=QPushButton('Close');close.clicked.connect(self.reject);row.addWidget(close)

    def browse(self):
        p,_=QFileDialog.getOpenFileName(self,'Choose Python executable','','Python executable (*)')
        if p:self.python.setText(p)

    def busy(self,value):
        for control in [self.run,self.check,self.install,self.python]:control.setEnabled(not value)
        self.cancel.setEnabled(value)

    def start(self,args,stage):
        python=self.python.text().strip()
        if not python or not Path(python).is_file():
            QMessageBox.warning(self,'Python needed','Choose a Python 3.10 or newer executable. Install Python from python.org if it is not available. The core Imspect app works without it.')
            return False
        self.settings.setValue('research_python',python)
        self.stage=stage
        self.busy(True)
        self.process.setProgram(python)
        self.process.setArguments([str(a) for a in args])
        self.process.start()
        return True

    def request(self,payload):
        base=Path(self.temp.name)
        (base/'request.json').write_text(json.dumps(payload),encoding='utf-8')
        (base/'response.json').unlink(missing_ok=True)
        self.start([worker_path(),'--request',base/'request.json','--response',base/'response.json'],'metric')

    def check_environment(self):
        self.log.clear()
        self.request({'protocol':1,'operation':'capabilities'})

    def install_environment(self):
        answer=QMessageBox.question(self,'Set up optional models','Create a separate model environment and download PyTorch, LPIPS and IQA dependencies? This can use several gigabytes. Pretrained weights are downloaded separately when you run a metric.')
        if answer!=QMessageBox.StandardButton.Yes:return
        self.log.clear()
        self.local.mkdir(parents=True,exist_ok=True)
        self.start(['-m','venv',self.env_path],'create_env')

    def run_metric(self):
        if not self.allow.isChecked():
            QMessageBox.information(self,'Download choice','Enable the pretrained-weight download checkbox to run model metrics.')
            return
        try:
            arrays=[('image',self.item.pixels)]
            op=self.metric.currentData()
            if op=='lpips':
                if self.item.pixels.shape!=self.reference.pixels.shape:raise ValueError('LPIPS requires matching source dimensions.')
                arrays.append(('reference',self.reference.pixels))
            base=Path(self.temp.name)
            request={'protocol':1,'operation':op,'device':self.device.currentData(),'allow_downloads':True,'roi':list(self.roi) if self.roi else None,'model_cache':str(self.local/'models')}
            for name,pixels in arrays:
                engine.crop(pixels,self.roi)
                if np.any(np.abs(pixels[...,3]-1)>1e-5) or np.any(pixels[...,:3]<0) or np.any(pixels[...,:3]>1):
                    raise ValueError('Model metrics require opaque RGB in [0,1]. Composite or clip explicitly first.')
                path=base/(name+'.png')
                Image.fromarray(np.rint(pixels[...,:3]*255).astype(np.uint8)).save(path)
                request[name]=str(path)
            if op=='lpips' and self.map.isChecked():
                request['heatmap']=str(base/'lpips-map.png')
                request['heatmap_max']=1.0
            self.log.clear()
            self.log.appendPlainText('Running locally. First use may download pretrained weights…')
            self.request(request)
        except Exception as exc:
            QMessageBox.warning(self,'Model input',str(exc))

    def read_log(self):
        data=bytes(self.process.readAllStandardOutput())+bytes(self.process.readAllStandardError())
        if data:self.log.appendPlainText(data.decode('utf-8',errors='replace'))

    def process_error(self,error):
        self.busy(False)
        self.log.appendPlainText(self.process.errorString())

    def finished(self,code,status):
        self.read_log()
        self.busy(False)
        if self.stage=='create_env' and code==0:
            self.python.setText(str(self.env_python))
            self.start(['-m','pip','install','-r',worker_path().parent/'requirements.txt'],'install')
            return
        if self.stage=='install':
            self.log.appendPlainText('Environment ready. Check environment, then choose a metric.' if code==0 else 'Setup failed; the error above includes the package or download problem.')
            return
        response=Path(self.temp.name)/'response.json'
        if self.stage=='metric' and response.exists():
            try:
                self.result=json.loads(response.read_text())
                self.log.appendPlainText(json.dumps(self.result,indent=2))
                self.add_map.setEnabled(bool(self.result.get('ok') and self.result.get('heatmap')))
            except Exception as e:self.log.appendPlainText(str(e))
        elif code:self.log.appendPlainText(f'Worker exited with code {code}; no score was substituted.')

    def save_report(self):
        if self.result is None:return
        path,_=QFileDialog.getSaveFileName(self,'Save model report','Imspect-research.json','JSON report (*.json)')
        if path:Path(path).write_text(json.dumps(self.result,indent=2),encoding='utf-8')

    def accept_map(self):
        if self.result and self.result.get('heatmap'):
            self.map_result=engine.load_image(self.result['heatmap'])
            self.map_name='LPIPS spatial map · '+self.item.name
            self.accept()

    def cancel_process(self):
        if self.process.state()!=QProcess.ProcessState.NotRunning:
            self.stage='cancelled'
            self.process.kill()
            self.process.waitForFinished(2000)
            self.log.appendPlainText('Cancelled.')
        self.busy(False)

    def done(self,result):
        self.cancel_process()
        self.temp.cleanup()
        super().done(result)
