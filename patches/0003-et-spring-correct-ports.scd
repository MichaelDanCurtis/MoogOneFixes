// et_spring, with the ports LADSPA 29153 actually has.
//
// The shipped SynthDef in synthdefs.scd passes the PLATE's argument list --
// distance, diffusion, modLvl, tone, highDamp, lowDamp, preDelay, size, decay --
// into a plugin whose ports are TREM-INTENSITY, TREM-RATE, MOD-LEVEL, RESONANCE,
// HIGH-DAMP, LOW-DAMP, NUM SPRINGS, TENSION, DECAY. Both are ten control ports,
// so it maps positionally and compiles without complaint; every knob is the wrong
// knob, and preDelay's default of 0.1 lands on NUM SPRINGS. It produces silence.
//
// The order below is ladspalist's output for 29153, read off the plugin.
//
// Its own metadata block already documents Trem Intensity, Trem Rate, Resonance,
// Num Springs and Tension -- the argument list simply never matched it.

SynthDef(\et_spring, {
    arg enable = 1,
        inBus = 0, outBus = 0,
        ctlIn = #[0, 0], ctlOut = #[0, 0],
        ctl = 0.5,
        g_in = 1,
        g_out = 1,

        /// parameters, in the plugin's port order
        tremIntensity = 0.2,
        tremRate = 0.3,
        modLevel = 0.2,
        resonance = 0.6,
        highDamp = 0.4,
        lowDamp = 0.3,
        numSprings = 0.8,
        tension = 0.5,
        decay = 0.6,
        mix = 1;

    var sig;
    var env = EnvGen.kr(Env.asr(0.1, 1, 2), enable, doneAction: 1);
    var input = In.ar(inBus, 2);

    mix = 1;
    sig = LADSPA.ar(2, 29153,
        tremIntensity, tremRate, modLevel, resonance, highDamp, lowDamp,
        numSprings, tension, decay, mix,
        input[0], input[1]);
    Out.ar(outBus, (sig * env * g_out));
}).store;
