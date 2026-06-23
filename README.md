# kickMe

## A digital kick drum synthesizer

### Video Demo: <URL>

### Description

The initial goal for KickPlayground was to try and digitally recreate some of the magic from one of my favorite synthesizers:
the Korg Volca Kick

The Volca Kick uses a reproduction of the classic (rev1) MS-20 filter. This filter self-resonating is the core.
oscillator for the kick drum.

This self-resonant filter then has a pitch envelope applied to create lovely, snappy kicks. A few coloring options are then used
to create a wide range of kick flavours.

Although the original idea I had was to create this a sound design tool that is then re-sampled into the DAW/sampler being used for the actual composition, a 16 step sequencer with active step controls was added as it vastly improves the enjoyment of 
the sound design.

### Key Components

#### Back-end: DSP built in Zig

The heart of this is a DSP that generates or processes the audio. Speed was my primary concern here as any glitches, skips, or 
lags in DSP have a huge impact on the final sound of the synth.

Because of this consideration, a low-level language was chosen. I did really enjoy using C in the course and problem sets, and 
recently heard about Zig. Zig's compatability with C libraries really solidified my choice, and I completed the Ziglings
exercises to learn the language (which I really enjoyed).

The miniaudio.c library is used purely to pipe the generated signal to the user's output via `ma_device`. It opens the audio device, runs the callback, and hands a buffer.

The compiled DSP produces a shared library (libdsp.so) which the front-end loads. Parameters have functions the GUI can call to
change.

#### Front-end: GUI built in Python with PySide6 (Qt)

The interface is oganised to be representative of the signal flow. Knobs, radios, and drop-downs are used to change the values 
in the DSP via their functions.

A 16 step sequencer reminiscent of that on the Korg Volca is added below the synth controls. A moving border indicates the current step in the play loop, and each step of the sequencer has two independent per-step states:

- active (fires a kick):  shown by a red light.
- enabled (step is included in the loop): shown by a yellow light.

The sequencer lives completely in the font-end. It only fires a 'bang!' to the DSP when an active and enabled step is reached
in the loop.

There is an opportunity for improvement here by moving the actual sequencer function to the DSP and just control it through the GUI; at rapid tempo using 16th notes above ~200bpm the rhythm drags in a perceptible way. However, as the original use case for this is for re-sampling, rather than a stand-alone musical instrument, this is left as-is. The dragging also has its use cases 
for creating interesting rhythms and its limitation can become a tool.

### Signal flow

 [oscillator] -> [wavefolder(pre)] -> [driver] -> [wavefolder(post)] -> [pitch envelope] -> [filter] -> [amp]

[OSCILLATOR]
The base sound of a good kick synth is a sine wave. The initial implimentation uses a plain digital sine generated with `@
sin()`.

Later, to capture some of the character and magic of the Korg, a hardware filter emulation was added as a second oscillator 
source. Documentation and resoures for the modelling of the Korg filter was too complex and dense for this project, so I found a
classic filter model with more documentation and a simpler implimentation: a Moog-style ladder filter (the improved virtual 
analog model by D'Angelo and Valimaki).

Struck with an impulse on each trigger, it produces a tuned tone with a rounder, less sterile character than the pure sine. A 
tuning correction keeps its pitch in line with the sine and an amplitude correction keeps the signals relatively consistent in 
dynamic response.

[WAVEFOLDER]
I wanted to give more of a mixed-coast approach to this synth, so it includes an emulation of the Buchla 259 wavefolder.

I provided two routing options for this: pre and post Driver. This allows for greater sound design possibilities. It is bypassed
entirely when the knob is set at 0.

[DRIVER]
The signal then passes into a driver to add saturation and further harmonic complexity to the oscillator.

Four models are offered: Arctan, Tanh, Cubic, and Hard.

[PICH ENVELOPE]
The other key component to kick drum synthesis is a pich envelope taking the oscilator from a high to low pitch rapidly --
creating a kick drum.

There are two main parameters for this envelope:

- amount: how high does the pitch start
- decay: how quickly will the resting frequency (set in osc freq) be reached from the amount selected

[FILTER]
Next is a more west-coast style addition, re-using the Moog-style ladder filter emulation. This time the resonance is a 
controllable parameter (unlike the persistent self-resonance of the oscillator)

[AMP]
The amplitude envelope only has one controllable parameter for decay. Attack could be added at a later stage to better emulate
the functionality of the Korg Volca.

The amp envelope also has a toggle option:

- vca: standard amp envelope behaviour, reminiscent of a west-coast voltage-controlled amplifier (not literally voltage-
controlled in this case
- lpg: a east-coast style low-pass gate, where the amplitude envelope also controls the filter cutoff. This 'squashes' harmonics
as the amplitude decays which is more reminiscent of how acoustic objects sound.

#### Key considerations

- The user's audio device sets its own sample rate in the DSP. This means all time-based functions are calculated as real-time 
values, then converted using the device's sample rate. This allows for consistent outputs across devices.

- The Moog-style filter emulation is slightly off pitch compared to the raw `@sin`, and rings at a much lower amplitude. There
are two constants added to the emulation used for the filter oscillator to bring its pitch and amplitude in-line with the `@sin`
oscillator.

- The amplitude envelope was creating digital clipping at the beginning of each kick as the amplitude jumps up instantly. A 
very short (2ms) 'fade-in' at the start of each hit was added to the amp to remove this.

- build.zig was created to easily compile the dsp.zig against the miniaudio library. Outputs the shared library to zig-out/
lib/

#### Refrences

S. D'Angelo and V. Valimaki, 
"An Improved Virtual Analog Model of the Moog Ladder Filter", Proc. ICASSP 2013, Vancouver, pp. 729-733.
Reference C++ implementation: ddiakopoulos/MoogLadders, ImprovedModel.h.

F. Esqueda, H. Pontynen, V. Valimaki and J. D. Parker,
"Virtual Analog Buchla 259 Wavefolder", Proc. DAFx-17, Edinburgh, pp. 192-199.
