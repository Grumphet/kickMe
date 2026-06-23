const std = @import("std");
const c = @import("miniaudio");

// oscillators
const Source = enum(u8) {
    sine = 0,
    filter_osc = 1
};

// drive Options
const Drives = enum(u8) {
    off = 0,
    arctan = 1,
    tanh = 2,
    cubic = 3,
    hard = 4,
};

// amp Options
const Amp = enum(u8) {
    vca = 0,
    lpg = 1,
};

const FoldPos = enum(u8) {
    pre = 0,
    post = 1,
};

// adjustments for self filter osc
const OSC_GAIN: f32 = 12.0;
const OSC_TUNE: f32 = 1.02;

// global variables that the Py GUI will change via ctypes
const Kick = struct {
    sample_rate: f32 = 44100.0,
    phase: f32 = 0.0,

    // osc
    frequency: f32 = 0.0,          // resting freqency
    fold: f32 = 0.0,
    fold_pos: FoldPos = .pre,
    drive: f32 = 1.0,
    driver: Drives = .off,

    // env
    pitch: f32 = 0.0,              // current pich in the env
    pitch_start: f32 = 0.0,        // pitch at start of env
    pitch_time: f32 = 0.0,         // multiplied by a rate (e.g. 0.998)
    pitch_coef: f32 = 0.0,

    // filter
    osc_impulse: f32 = 0.0,        // how hard the filter is 'struck'
    source: Source = .sine,
    osc_filter: MoogLadder = .{},  // Moogladdder has setPostCutoff and setResonance
    post_filter: MoogLadder = .{}, // osc_ is always self-resonant, post_ is set with knobs
    filter_cutoff: f32 = 8000.0,

    // amp
    amplitude: f32 = 0.0,
    decay_time: f32 = 0.2,
    decay_coef: f32 = 0.0,
    attack_coef: f32 = 0.0,
    attacking: bool = false,       // for fading amplitude between triggers
    amp_type: Amp = .vca,

    // buchla filter state (one pole, ~1.33 kHz)
    fold_lp_x1: f32 = 0.0,
    fold_lp_y1: f32 = 0.0,
    fold_lp_b0: f32 = 0.0,
    fold_lp_b1: f32 = 0.0,
    fold_lp_a1: f32 = 0.0,

        
    // reset everythign to start a new hit
    fn trigger(self: *Kick) void {
        self.attacking = true;
        self.pitch = self.pitch_start;
        self.phase = 0.0;
        self.osc_filter.setResonance(4.0); // TODO: add some knobs for osc res
        self.osc_impulse = 1.0;            // and impulse to overdrive even more
    }

    // per-sample multiplier for 60dB decay over time_s
    // take out of Kick IF multiple instruments become a thing..
    fn coefFromTime(time_s: f32, sr: f32) f32 {
        if (time_s <= 0.0 or sr <= 0.0) return 0.0;
        const ln_ratio: f32 = -6.907755;  // ln(0.001), ie -60dB
        return @exp(ln_ratio / (time_s * sr));
    }

    fn updateCoefs(self: *Kick) void {
        self.decay_coef = coefFromTime(self.decay_time, self.sample_rate);
        self.pitch_coef = coefFromTime(self.pitch_time, self.sample_rate);
        self.attack_coef = 1.0 / (0.002 * self.sample_rate); // 2ms linear rise per sample
                                                             // could maybe be reduced..
        // buchla output lowpass
        const fc: f32 = 1330.0;
        const wc = 2.0 * std.math.pi * fc;
        const t = 1.0 / self.sample_rate;
        const wct = wc * t;
        self.fold_lp_b0 = wct / (2.0 + wct);
        self.fold_lp_b1 = self.fold_lp_b0;
        self.fold_lp_a1 = (wct - 2.0) / (wct + 2.0);
    }

    // Buchla 259 from:
    //   F. Esqueda, H. Pontynen, V. Valimaki and J. D. Parker,
    //   "Virtual Analog Buchla 259 Wavefolder", Proc. 20th Int. Conf.
    //   Digital Audio Effects (DAFx-17), Edinburgh, UK, Sept. 2017,
    //   pp. 192-199.
    //
    // Folding cell branch equations (13)-(17) summing stage (18), and output lowpass(19)-(21)
 
    fn folder(self: *Kick, sample: f32) f32 {
        if (self.fold <= 0.0) return sample;

        const vin: f32 = sample * self.fold;
        const s: f32 = std.math.sign(vin);
        const a: f32 = @abs(vin);

        const v1: f32 = if (a > 0.6) 0.8333 * vin - 0.5000 * s else 0.0;
        const v2: f32 = if (a > 2.994) 0.3768 * vin - 1.1281 * s else 0.0;
        const v3: f32 = if (a > 5.46) 0.2829 * vin - 1.5446 * s else 0.0;
        const v4: f32 = if (a > 1.8) 0.5743 * vin - 1.0338 * s else 0.0;
        const v5: f32 = if ( a > 4.08) 0.2673 * vin - 1.0907 * s else 0.0;

        const out = -12.0 * v1 - 27.777 * v2 - 21.428 * v3
                         + 17.647 * v4 + 36.363 * v5 + 5.0 * vin;

        return out * 0.1; // scaled back down
    }

    fn foldLowpass(self: *Kick, x: f32) f32 {
        const y = self.fold_lp_b0 * x + self.fold_lp_b1 * self.fold_lp_x1 - self.fold_lp_a1 * self.fold_lp_y1;
        self.fold_lp_x1 = x;
        self.fold_lp_y1 = y;
        return y;
    }

    // produce one mono sample
    fn nextSample(self: *Kick) f32 {
        const two_pi = 2.0 * std.math.pi;

        // step comes from the current pitch and the real sample rate
        const phase_inc = two_pi * self.pitch / self.sample_rate;

        var raw: f32 = switch (self.source) {
            .sine => blk: {
                const s = @sin(self.phase) * 0.5;            // sin scaled down --
                break :blk s;                                     // less clipping and closer to filter osc gain
            },
            .filter_osc => blk: {
                self.osc_filter.setCutoff(self.pitch * OSC_TUNE); // ~1/2 step flat
                const s = self.osc_filter.process(self.osc_impulse);
                self.osc_impulse = 0.0;
                break :blk  s * OSC_GAIN;                         // and very quiet
            }
        };

        if (self.fold_pos == .pre) raw = self.folder(raw);

        var sample = switch (self.driver) {
            .off => raw,                                                      // atan clips to +/- pi/2
            .arctan => (2.0 / std.math.pi) * std.math.atan(raw * self.drive), // this is +/- 1
            .tanh => std.math.tanh(raw * self.drive),
            .cubic => blk: {
                const x = raw * self.drive;
                const t: f32 = 2.0 / 3.0;
                if (x >= t) break :blk 1.0;
                if (x <= -t) break :blk -1.0;
                break :blk x + (4.0 * x * x * x) / 27.0;
            },
            .hard => std.math.clamp(raw * self.drive, -1.0, 1.0),
        };

        if (self.fold_pos == .post) sample = self.folder(sample);

        // amplitude envelope
        // ramps up in the attack to soften digital clips
        if (self.attacking) {
            self.amplitude += self.attack_coef;
            if (self.amplitude >= 1.0) {
                self.amplitude = 1.0;
                self.attacking = false; // atack is done
            }
        } else {
            self.amplitude *= self.decay_coef;
        }

        switch (self.amp_type) {
            .vca => {
                self.post_filter.setCutoff(self.filter_cutoff); // needs to reset for mode switches
                sample = self.post_filter.process(sample);      // filter the tone
                sample *= self.amplitude;
            },
            .lpg => {
                const lpg_cutoff = 20.0 + self.amplitude * (self.filter_cutoff - 20.0);
                self.post_filter.setCutoff(lpg_cutoff);
                sample = self.post_filter.process(sample);
                sample *= self.amplitude;
            },
        }

        self.phase += phase_inc;                        // advance phase
        if (self.phase >= two_pi) self.phase -= two_pi; // keep phase bounded

        // pitch envelope
        self.pitch = self.frequency + (self.pitch - self.frequency) * self.pitch_coef;

        return sample;
    } 
};

// moog ladder filter, trapezoidal-integration model.
//
// ported from the reference C++ implementation by Stefano D'Angelo
// (ddiakopoulos/MoogLadders, ImprovedModel.h), which implements:
//   S. D'Angelo and V. Valimaki, "An Improved Virtual Analog Model
//   of the Moog Ladder Filter", Proc. ICASSP 2013, Vancouver.
// original code (c) 2012 Stefano D'Angelo, ISC-style permissive licence.


const MoogLadder = struct {
    const VT: f32 = 0.312;           // thermal voltage; 0.312 is the value used in the reference (not the
    sample_rate: f32 = 44100.0,      // physical 0.026 V), tuned so the filter self-oscillates correctly.

    v: [4]f32 = .{ 0, 0, 0, 0 },     // four stage states
    dv: [4]f32 = .{ 0, 0, 0, 0 },    // their previous derivatives
    tv: [4]f32 = .{ 0, 0, 0, 0 },    // and their tanh outputs

    cutoff: f32 = 1000.0,
    resonance: f32 = 0.1,            //  ~4 is self-oscillation
    g: f32 = 0.0,                    // derived from cutoff, set by setCutoff
    drive: f32 = 1.0,

    fn setCutoff(self: *MoogLadder, hz: f32) void {
        self.cutoff = hz;
        const x = (std.math.pi * hz) / self.sample_rate;

        // bilinear-style frequency prewarp folded into the gain coefficient
        self.g = 4.0 * std.math.pi * VT * hz * (1.0 - x) / (1.0 + x);
    }

    fn setResonance(self: *MoogLadder, r: f32) void {
        self.resonance = r;          // expects 0..4
    }

    fn setSampleRate(self: *MoogLadder, sr: f32) void {
        self.sample_rate = sr;
        self.setCutoff(self.cutoff); // g depends on sample rate, recompute
    }

    fn process(self: *MoogLadder, input: f32) f32 {
        const two_vt = 2.0 * VT;
        const denom = 2.0 * self.sample_rate;

        // stage 0: input mixed with feedback from stage 3
        const dv0 = -self.g * (std.math.tanh((self.drive * input + self.resonance * self.v[3]) / two_vt) + self.tv[0]);
        self.v[0] += (dv0 + self.dv[0]) / denom;
        self.dv[0] = dv0;
        self.tv[0] = std.math.tanh(self.v[0] / two_vt);

        const dv1 = self.g * (self.tv[0] - self.tv[1]);
        self.v[1] += (dv1 + self.dv[1]) / denom;
        self.dv[1] = dv1;
        self.tv[1] = std.math.tanh(self.v[1] / two_vt);

        const dv2 = self.g * (self.tv[1] - self.tv[2]);
        self.v[2] += (dv2 + self.dv[2]) / denom;
        self.dv[2] = dv2;
        self.tv[2] = std.math.tanh(self.v[2] / two_vt);

        const dv3 = self.g * (self.tv[2] - self.tv[3]);
        self.v[3] += (dv3 + self.dv[3]) / denom;
        self.dv[3] = dv3;
        self.tv[3] = std.math.tanh(self.v[3] / two_vt);

        return self.v[3];
    }
};

var synth: Kick = .{};
var device: c.ma_device = undefined;
const StartError  = error{ DeviceInitFailed, DeviceStartFailed };

// error handling
fn openDevice() StartError!void {
    var config = c.ma_device_config_init(c.ma_device_type_playback);
    config.playback.format = c.ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = 44100;
    config.dataCallback = audioCallback;

    if (c.ma_device_init(null, &config, &device) != c.MA_SUCCESS)
        return error.DeviceInitFailed;
    if (c.ma_device_start(&device) != c.MA_SUCCESS) {
        c.ma_device_uninit(&device);
        return error.DeviceStartFailed;
    }
}

// miniaudio is used for this output pipe
fn audioCallback(pDevice: [*c]c.ma_device, pOutput: ?*anyopaque, pInput: ?*const anyopaque, frameCount: c.ma_uint32) callconv(.c) void {
    _ = pInput;

    // read the device's real sample rate
    synth.sample_rate = @as(f32, @floatFromInt(pDevice.*.sampleRate));
    synth.updateCoefs();
    synth.osc_filter.sample_rate = synth.sample_rate;   // per-sample cutoff for osc filter
    synth.post_filter.setSampleRate(synth.sample_rate); // stable cutoff for post filter

    var output = @as([*]f32, @ptrCast(@alignCast(pOutput)))[0 .. frameCount * 2]; // * 2 for Stereo

    var i: usize = 0;
    while (i < output.len) : (i += 2) {
        const sample = synth.nextSample();
        output[i] = sample;                             // left
        output[i + 1] = sample;                         // right
    }
}

// ffi -  py can't poke inside a struct directly via ctypes
export fn triggerKick() callconv(.c) void {         // action
    synth.trigger();
}

export fn setFrequency(hz: f32) callconv(.c) void { //setters
    synth.frequency = hz;
}
export fn setDecay(seconds: f32) callconv(.c) void {
    synth.decay_time = seconds;
}
export fn setPitchStart(hz: f32) callconv(.c) void {
    synth.pitch_start = hz;
}
export fn setPitchDecay(seconds: f32) callconv(.c) void {
    synth.pitch_time = seconds;
}
export fn setDrive(amount: f32) callconv(.c) void {
    synth.drive = amount;
}
export fn setPostCutoff(hz: f32) callconv(.c) void {
    synth.filter_cutoff = hz;
    synth.post_filter.setCutoff(hz);
}
export fn setPostResonance(r: f32) callconv(.c) void {
    synth.post_filter.setResonance(r);
}
export fn setFold(amount: f32) callconv(.c) void {
    synth.fold = amount; // expects ~0..8
}
export fn setSource(kind: u8) callconv(.c) void {
    if (kind > 1) return;
    synth.source = @enumFromInt(kind);
}
export fn setFoldPos(pos: u8) callconv(.c) void {
    if (pos > 1) return;
    synth.fold_pos = @enumFromInt(pos);
}
export fn setDriver(drive: u8) callconv(.c) void {
    if (drive > 4) return;
    synth.driver = @enumFromInt(drive);
}
export fn setAmp(amp: u8) callconv(.c) void {
    if (amp > 1) return;
    synth.amp_type = @enumFromInt(amp);
}

export fn audioStart() callconv(.c) c_int {         // shim
    openDevice() catch |err| return switch(err) {
        error.DeviceInitFailed => -1,
        error.DeviceStartFailed => -2,
    };
    return 0;
}
export fn audioStop() callconv(.c) void {
    c.ma_device_uninit(&device);
}
