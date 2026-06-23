import ctypes
import sys 
from pathlib import Path
from PySide6 import QtCore, QtWidgets, QtGui
Qt = QtCore.Qt

def _load_dsp():
    if sys.platform.startswith('win'):
        lib_name = 'dsp.dll'
    elif sys.platform.startswith('darwin'):
        lib_name = 'libdsp.dylib'
    else:
        lib_name = 'libdsp.so'

    if getattr(sys, 'frozen', False):
        candidates = [Path(sys._MEIPASS) / lib_name]
    else:
        root = Path(__file__).resolve().parent
        candidates = [
            root / 'zig-out' / 'lib' / lib_name,
            root / 'zig-out' / 'bin' / lib_name,
        ]
    
    for path in candidates:
        if path.exists():
            return ctypes.CDLL(str(path))
    raise FileNotFoundError(f'{lib_name} not found in {[str(c) for c in candidates]}')

dsp = _load_dsp()

# data types zig expects
# not all of these are needed to be stated..
dsp.audioStart.argtypes = []
dsp.audioStart.restype = ctypes.c_int
dsp.audioStop.argtypes = []
dsp.audioStop.restype = None
dsp.triggerKick.argtypes = []
dsp.triggerKick.restype = None
dsp.setFrequency.argtypes = [ctypes.c_float]
dsp.setFrequency.restype = None
dsp.setDecay.argtypes = [ctypes.c_float]
dsp.setDecay.restype = None
dsp.setPitchStart.argtypes = [ctypes.c_float]
dsp.setPitchStart.restype = None
dsp.setPitchDecay.argtypes = [ctypes.c_float]
dsp.setPitchDecay.restype = None
dsp.setDrive.argtypes = [ctypes.c_float]
dsp.setDrive.restype = None
dsp.setPostCutoff.argtypes = [ctypes.c_float]
dsp.setPostCutoff.restype = None
dsp.setPostResonance.argtypes = [ctypes.c_float]
dsp.setPostResonance.restype = None
dsp.setFold.argtypes = [ctypes.c_float]
dsp.setFold.restype = None
dsp.setSource.argtypes = [ctypes.c_uint8]
dsp.setSource.restype = None
dsp.setDriver.argtypes = [ctypes.c_uint8]
dsp.setDriver.restype = None
dsp.setAmp.argtypes = [ctypes.c_uint8]
dsp.setAmp.restype = None
dsp.setFoldPos.argtypes = [ctypes.c_uint8]
dsp.setFoldPos.restype = None


# 0 OK, -1 DeviceInitFail, -2 DeviceStartFail
def start():
    rc = dsp.audioStart()
    if rc != 0:
        raise RuntimeError(f'audio start failed. code {rc}')


##################################################################
#  .     .   .      o       .          .       *  . .     .      #
#    .  *  |     .    .            .   .     .   .     * .    .  #
#        --o--              app           *    |      ..    .    #
#     *    |       *  .        .    .   .    --*--  .     *  .   #
#  .     .    .    .   . . .      .        .   |   .    .  .     #
##################################################################

class MyWidget(QtWidgets.QWidget):

    # step button styles: border is the playhead indicator
    STEP_BASE = 'QPushButton { background:#222; border:2px solid #444; min-width:26px; min-height:26px; }'
    STEP_HEAD = 'QPushButton { background:#222; border:2px solid #ffffff; min-width:26px; min-height:26px; }'

    def __init__(self):
        super().__init__()

        # per-step state
        # this is okay at <~160 bpm -- starts to drag BAD
        # probably better to handle the sequencer in the dsp and just control it here
        self.step_active = [False] * 16   # red light: fires a bang
        self.step_enabled = [True] * 16   # yellow light: active step
        self.seq_pos = -1                 # index into the enabled-steps list

        outer = QtWidgets.QGridLayout(self)

        # ---- main knob row --------------------------------------------
        kg = QtWidgets.QGridLayout()

        osc_box = QtWidgets.QGroupBox('Osc')
        og = QtWidgets.QGridLayout(osc_box)

        source_box = QtWidgets.QGroupBox()
        sb = QtWidgets.QHBoxLayout(source_box)
        sb.addWidget(QtWidgets.QLabel('Source'))
        self.source = QtWidgets.QComboBox()
        self.source.addItems(['Sine', 'Filter'])
        self.source.currentIndexChanged.connect(lambda i: dsp.setSource(i))
        sb.addWidget(self.source)
        og.addWidget(source_box, 0, 0, 1, 2)
        og.setVerticalSpacing(2)

        self.freq   = self._add_dial(og, 1, 0, 'Freq',   30, 200, 55,  lambda v: dsp.setFrequency(float(v)), ' Hz')
        self.fold   = self._add_dial(og, 1, 1, 'Fold',   0, 100, 0, lambda v: dsp.setFold(v / 12.0), '%')       # ~ 0.0..8.3
        self.drive  = self._add_dial(og, 3, 0, 'Drive',  0, 100, 0,  lambda v: dsp.setDrive(1.0 + v / 20.0), '%') # 1.0..6.0

        sel = QtWidgets.QVBoxLayout()
        sel.setContentsMargins(0, 12, 0, 0)
        sel.addSpacing(50)
        sel.addStretch(2)
        self.fold_group = QtWidgets.QButtonGroup(self)
        self.fold_pre = QtWidgets.QRadioButton('Pre')
        self.fold_post = QtWidgets.QRadioButton('Post')
        self.fold_pre.setChecked(True)
        self.fold_group.addButton(self.fold_pre, 0)
        self.fold_group.addButton(self.fold_post, 1)
        self.fold_group.idClicked.connect(lambda i: dsp.setFoldPos(i))
        radio_row = QtWidgets.QHBoxLayout()
        radio_row.addWidget(self.fold_pre)
        radio_row.addWidget(self.fold_post)
        sel.addLayout(radio_row)
        sel.addStretch(1)

        sel.addWidget(QtWidgets.QLabel('Drive Type'))
        self.driver = QtWidgets.QComboBox()
        self.driver.addItems(['Off', 'Arctan', 'Tanh', 'Cubic', 'Hard'])
        self.driver.setCurrentIndex(0)
        self.driver.currentIndexChanged.connect(lambda i: dsp.setDriver(i))
        sel.addWidget(self.driver)
        sel.addStretch(1)
        og.addLayout(sel, 1, 1, 4, 1)
        kg.addWidget(osc_box, 0, 1, 4, 1)

        env_box = QtWidgets.QGroupBox('Env')
        eg = QtWidgets.QGridLayout(env_box)
        self.pstart = self._add_dial(eg, 0, 0, 'Amount', 100, 1000, 200, lambda v: dsp.setPitchStart(float(v)), ' Hz')
        self.pdecay = self._add_dial(eg, 0, 1, 'Decay', 20, 1000, 400, lambda v: dsp.setPitchDecay(v / 1000.0), ' ms')
        kg.addWidget(env_box, 0, 2, 4, 1) 

        filt_box = QtWidgets.QGroupBox('Filter')
        fg = QtWidgets.QGridLayout(filt_box)
        self.fcut = self._add_dial(fg, 0, 0, 'Freq', 20, 8000, 8000, lambda v: dsp.setPostCutoff(float(v)), 'Hz')
        self.fres = self._add_dial(fg, 2, 0, 'Res', 0, 40, 0, lambda v: dsp.setPostResonance(v / 10.0))
        kg.addWidget(filt_box, 0, 3, 4, 1)
        
        amp_box = QtWidgets.QGroupBox('Amp')
        ag = QtWidgets.QGridLayout(amp_box)
        self.adecay = self._add_dial(ag, 0, 0, 'Decay',   50, 2000, 200, lambda v: dsp.setDecay(v / 1000.0), ' ms')

        self.amp_group = QtWidgets.QButtonGroup(self)
        self.amp_vca = QtWidgets.QRadioButton('vca')
        self.amp_lpg = QtWidgets.QRadioButton('lpg')
        self.amp_vca.setChecked(True)
        self.amp_group.addButton(self.amp_vca, 0)
        self.amp_group.addButton(self.amp_lpg, 1)
        self.amp_group.idClicked.connect(lambda i: dsp.setAmp(i))

        toggle_row = QtWidgets.QHBoxLayout()
        toggle_row.addWidget(self.amp_vca)
        toggle_row.addWidget(self.amp_lpg)
        ag.addLayout(toggle_row, 2, 0)
        kg.addWidget(amp_box, 0, 4, 4, 1)

        outer.addLayout(kg, 1, 0)

        # ---- sequencer block ------------------------------------------
        seq_box = QtWidgets.QGroupBox('Sequencer')
        sg = QtWidgets.QGridLayout(seq_box)

        self.step_edit = QtWidgets.QCheckBox('Step Edit')  # toggles what a click does
        sg.addWidget(self.step_edit, 0, 0, 1, 16)

        self.red_lights = []
        self.step_buttons = []
        self.yellow_lights = []
        for i in range(16):
            red = self._make_light()
            sg.addWidget(red, 1, i, alignment=Qt.AlignmentFlag.AlignCenter)
            self.red_lights.append(red)

            btn = QtWidgets.QPushButton()
            btn.setStyleSheet(self.STEP_BASE)
            btn.clicked.connect(lambda checked=False, idx=i: self._step_clicked(idx))
            sg.addWidget(btn, 2, i)
            self.step_buttons.append(btn)

            yel = self._make_light()
            sg.addWidget(yel, 3, i, alignment=Qt.AlignmentFlag.AlignCenter)
            self.yellow_lights.append(yel)
            self._refresh_step(i)  # paint initial light state

        outer.addWidget(seq_box, 2, 0)

        # ---- transport ------------------------------------------------
        tr_box = QtWidgets.QGroupBox()
        tg = QtWidgets.QGridLayout(tr_box)
        self.run = QtWidgets.QPushButton('Start')
        self.run.setCheckable(True)
        self.run.toggled.connect(self.toggle_run)
        tg.addWidget(self.run, 0, 0)
        self.kick_btn = QtWidgets.QPushButton('Kick')
        self.kick_btn.clicked.connect(lambda: dsp.triggerKick())
        tg.addWidget(self.kick_btn, 0, 1)
        tg.addWidget(QtWidgets.QLabel('Tempo'), 0, 2)
        self.tempo = QtWidgets.QSlider(Qt.Orientation.Horizontal)
        self.tempo.setRange(60, 200)
        self.tempo.setValue(120)
        self.tempo.setTickPosition(QtWidgets.QSlider.TickPosition.TicksBelow)
        self.tempo.setTickInterval(10)
        self.tempo.valueChanged.connect(self._set_tempo)
        tg.addWidget(self.tempo, 0, 3)
        self.tempo_label = QtWidgets.QLabel('120 BPM')
        self.tempo.setStyleSheet("""
            QSlider::groove:horizontal { height: 4px; background: #333; border-radius: 2px; }
            QSlider::sub-page:horizontal { background: #ff3030; border-radius: 2px; }
            QSlider::handle:horizontal { background: #ff3030; width: 12px; margin: -5px 0;border-radius: 6px; }
        """)
        tg.addWidget(self.tempo_label, 0, 4)
        outer.addWidget(tr_box, 3, 0)

        # timer for sequencer clock
        self.timer = QtCore.QTimer()
        self.timer.timeout.connect(self._bang)
        self._set_tempo(self.tempo.value())

        self.push_all()  # send starting values to the synth

    # ---- helpers ------------------------------------------------------
    def _add_dial(self, grid, row, col, label, lo, hi, start, on_change, suffix=''):
        grid.addWidget(QtWidgets.QLabel(label), row, col, alignment=Qt.AlignmentFlag.AlignCenter)
        d = QtWidgets.QDial()
        d.setRange(lo, hi)
        d.setValue(start)
        d.setNotchesVisible(True)
        d.setWrapping(False)
        d.valueChanged.connect(lambda v: self._dial_changed(v, on_change, suffix))
        grid.addWidget(d, row + 1, col)
        return d

    # value popup at the cursor while turning
    def _dial_changed(self, v, on_change, suffix):
        on_change(v)
        QtWidgets.QToolTip.showText(QtGui.QCursor.pos(), f'{v}{suffix}')

    def _make_light(self):
        lbl = QtWidgets.QLabel()
        lbl.setFixedSize(14, 14)
        return lbl

    def _light_style(self, on, color):
        return f"background-color: {color if on else '#333'}; border-radius: 7px;"

    def _refresh_step(self, i):
        self.red_lights[i].setStyleSheet(self._light_style(self.step_active[i], '#ff3030'))
        self.yellow_lights[i].setStyleSheet(self._light_style(self.step_enabled[i], '#ffd000'))

    def _step_clicked(self, idx):
        if self.step_edit.isChecked():
            self.step_enabled[idx] = not self.step_enabled[idx]
        else:
            self.step_active[idx] = not self.step_active[idx]
        self._refresh_step(idx)

    def _set_tempo(self, bpm):
        self.timer.setInterval(round(60000 / bpm / 4)) # 16th notes, so divide bpm by 4
        self.tempo_label.setText(f'{bpm} BPM')

    def toggle_run(self, running):
        if running:
            self.seq_pos = -1
            self.timer.start()
            self.run.setText('Stop')
        else:
            self.timer.stop()
            self.run.setText('Start')
            for b in self.step_buttons:                 # clear the playhead border
                b.setStyleSheet(self.STEP_BASE)

    def _bang(self):
        enabled = [i for i in range(16) if self.step_enabled[i]]
        if not enabled:                                 # nothing in the loop
            return
        self.seq_pos = (self.seq_pos + 1) % len(enabled)
        step = enabled[self.seq_pos]
        for i, b in enumerate(self.step_buttons):       # border = playhead
            b.setStyleSheet(self.STEP_HEAD if i == step else self.STEP_BASE)
        if self.step_active[step]:
            dsp.triggerKick()

    def push_all(self):
        dsp.setFrequency(float(self.freq.value()))
        dsp.setPitchStart(float(self.pstart.value()))
        dsp.setPitchDecay(self.pdecay.value() / 1000.0)
        dsp.setDecay(self.adecay.value() / 1000.0)
        dsp.setDrive(1.0 + self.drive.value() / 20.0)
        dsp.setSource(self.source.currentIndex())
        dsp.setPostCutoff(float(self.fcut.value()))
        dsp.setPostResonance(self.fres.value() /10.0)
        dsp.setAmp(self.amp_group.checkedId())
        dsp.setFold(self.fold.value() / 12.0)
        dsp.setFoldPos(self.fold_group.checkedId())

##################################################################

if __name__ == '__main__':
    app = QtWidgets.QApplication([])
    app.styleHints().setColorScheme(QtCore.Qt.ColorScheme.Dark)
    widget = MyWidget()
    widget.resize(800, 400)
    widget.show()

    start()
    exit_code = app.exec()
    dsp.audioStop()
    sys.exit(exit_code)

