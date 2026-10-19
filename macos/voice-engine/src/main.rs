#![allow(dead_code)]
// Compile the same inference and DSP implementation as the Linux daemon.
#[path = "../../../daemon/engine/src/vc_dsp.rs"]
mod vc_dsp;
#[path = "../../../daemon/engine/src/vc_rvc_config.rs"]
mod vc_rvc_config;
#[path = "../../../daemon/engine/src/vc_onnxruntime_detect.rs"]
mod vc_onnxruntime_detect;
#[path = "../../../daemon/engine/src/vc/inference/mod.rs"]
pub mod inference;
#[path = "../../../daemon/engine/src/vc/wav_io.rs"]
pub mod wav_io;
#[cfg(test)]
mod vc {
    pub use crate::inference;
    pub use crate::wav_io;
}
use inference::engine::{ContentVecSession, RmvpeSession, SynthSession};
use inference::pipeline::Pipeline;
use inference::retrieval::RetrievalIndex;
use serde::Deserialize;
use std::io::{Read, Write};
use std::path::PathBuf;

#[derive(Deserialize)]
struct Config {
    runtime: PathBuf,
    contentvec: PathBuf,
    rmvpe: PathBuf,
    model: PathBuf,
    index: Option<PathBuf>,
    #[serde(default)]
    params: vc_rvc_config::RvcParams,
    #[serde(default)]
    pitch: f32,
    #[serde(default)]
    coreml: bool,
}
fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let path = args.get(1).ok_or("Usage: arctis-voice-engine config.json [input.wav output.wav]")?;
    let cfg: Config = serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    if !cfg.pitch.is_finite() || !(-24.0..=24.0).contains(&cfg.pitch) { return Err("Pitch must be between -24 and 24 semitones".into()); }
    let p = &cfg.params;
    if !(0.5..=2.0).contains(&p.vtln_alpha) || !(0.0..=1.0).contains(&p.rms_mix_rate)
        || !(0.0..=1.0).contains(&p.index_rate) || !(0.001..=1.0).contains(&p.target_rms)
        || !(0.1..=1.0).contains(&p.limiter_thr) || !(1..=31).contains(&p.filter_radius) {
        return Err("Invalid inference parameters".into());
    }
    let providers = if cfg.coreml {
        vec![ort::ep::CoreML::default().build(), ort::ep::CPU::default().build()]
    } else { vec![ort::ep::CPU::default().build()] };
    ort::init_from(&cfg.runtime).map_err(|e| e.to_string())?
        .with_execution_providers(providers).commit();
    let hubert = ContentVecSession::load(&cfg.contentvec).map_err(|e| e.to_string())?;
    let rmvpe = RmvpeSession::load(&cfg.rmvpe).map_err(|e| e.to_string())?;
    let synth = SynthSession::load(&cfg.model).map_err(|e| e.to_string())?;
    let sr = synth.native_sample_rate().ok_or("Model lacks sample_rate metadata; re-export it with the project's exporter")?;
    if ![32000, 40000, 48000].contains(&sr) { return Err("Unsupported model sample rate".into()); }
    let index = cfg.index.as_ref().map(|p| RetrievalIndex::load(p).map_err(|e| e.to_string())).transpose()?;
    let mut pipeline = Pipeline::new(hubert, rmvpe, synth, sr, cfg.params, index);
    if args.len() == 4 {
        let (input, input_sr) = wav_io::read_mono_f32(args[2].as_ref()).map_err(|e| e.to_string())?;
        let input = inference::resample::resample(&input, input_sr, 16000);
        let mut output = Vec::new();
        if let Some(floor) = vc_dsp::detect_leading_noise_floor(&input, 16000) {
            let calibrated = vc_dsp::calibrate_gate_from_noise_floor(floor);
            pipeline.set_gate_calibration(inference::pipeline::GateCalibration { vad_rms: calibrated.vad_rms, knee_floor: calibrated.knee_floor });
        }
        for chunk in input.chunks(2048) {
            let mut padded = chunk.to_vec(); padded.resize(2048, 0.0);
            output.extend(pipeline.convert(&padded, 16000, cfg.pitch).map_err(|e| e.to_string())?);
        }
        // Flush look-ahead and crossfade state so the end of the utterance survives.
        for _ in 0..4 { output.extend(pipeline.convert(&[0.0; 2048], 16000, cfg.pitch).map_err(|e| e.to_string())?); }
        wav_io::write_mono_pcm16(args[3].as_ref(), &output, 48000).map_err(|e| e.to_string())?;
    } else {
        // Fixed-size, little-endian mono Float32: 2048 input frames at 16kHz,
        // exactly 6144 output frames at 48kHz. Diagnostics never enter stdout.
        eprintln!("READY");
        let mut input = std::io::stdin().lock();
        let mut output = std::io::stdout().lock();
        let mut bytes = [0u8; 2048 * 4];
        loop {
            match input.read_exact(&mut bytes) {
                Ok(()) => {},
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => return Err(e.to_string()),
            }
            let samples: Vec<f32> = bytes.chunks_exact(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())).collect();
            if samples.iter().any(|x| !x.is_finite()) { return Err("Non-finite input sample".into()); }
            let converted = pipeline.convert(&samples, 16000, cfg.pitch).map_err(|e| e.to_string())?;
            if converted.len() != 6144 { return Err("Unexpected inference frame count".into()); }
            for sample in converted { output.write_all(&sample.to_le_bytes()).map_err(|e| e.to_string())?; }
            output.flush().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
fn main() {
    if let Err(error) = run() { eprintln!("ERROR: {error}"); std::process::exit(1); }
}
