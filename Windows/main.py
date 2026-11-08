"""Imspect Windows desktop entry point; also runnable on macOS for development."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import traceback


def main():
    parser=argparse.ArgumentParser(description='Imspect: local image comparison for computer vision')
    parser.add_argument('--smoke-test',metavar='OUTPUT_DIR')
    parser.add_argument('--demo',action='store_true')
    parser.add_argument('images',nargs='*')
    args=parser.parse_args()
    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication
    from imspect.app import MainWindow,apply_style
    from imspect import __version__
    app=QApplication(sys.argv[:1])
    app.setApplicationName('Imspect')
    app.setOrganizationName('Imspect')
    app.setApplicationVersion(__version__)
    apply_style(app)
    window=MainWindow()
    app.setWindowIcon(window.windowIcon())
    window.testing=bool(args.smoke_test)
    if args.smoke_test:
        from imspect.smoke import run_smoke
        window.resize(1440,900)
        window.show()
        def verify():
            code=run_smoke(app,window,Path(args.smoke_test))
            window.close()
            app.exit(code)
        QTimer.singleShot(100,verify)
    else:
        window.show()
        if args.demo:
            window.load_demo()
        elif len(args.images)==1 and args.images[0].lower().endswith('.imspectw'):
            window.open_session(args.images[0])
        elif args.images:
            window.load_paths(args.images)
    return app.exec()


if __name__=='__main__':
    try:
        raise SystemExit(main())
    except Exception:
        # Windowed Windows builds have no terminal. Retain an actionable crash log.
        error=traceback.format_exc()
        try:
            if os.environ.get('LOCALAPPDATA'):
                directory=Path(os.environ['LOCALAPPDATA'])/'Imspect'
            elif sys.platform=='darwin':
                directory=Path.home()/'Library'/'Application Support'/'Imspect'
            else:
                directory=Path(os.environ.get('XDG_STATE_HOME',str(Path.home()/'.local'/'state')))/'Imspect'
            directory.mkdir(parents=True,exist_ok=True)
            (directory/'last-error.log').write_text(error,encoding='utf-8')
            if '--smoke-test' in sys.argv:
                output=Path(sys.argv[sys.argv.index('--smoke-test')+1])
                output.mkdir(parents=True,exist_ok=True)
                (output/'report.json').write_text(json.dumps({'ok':False,'startup_error':error},indent=2),encoding='utf-8')
            else:
                from PySide6.QtWidgets import QApplication,QMessageBox
                app=QApplication.instance() or QApplication([])
                QMessageBox.critical(None,'Imspect could not start',error+'\nLog: '+str(directory/'last-error.log'))
        except Exception:
            pass
        raise
