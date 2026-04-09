#!/usr/bin/env python3

import argparse
import pathlib
import wave

import numpy as np
from kokoro import KPipeline


def write_wav(output_path: pathlib.Path, audio: np.ndarray, sample_rate: int) -> None:
    clipped_audio = np.clip(audio, -1.0, 1.0)
    pcm16_audio = (clipped_audio * 32767.0).astype(np.int16)

    with wave.open(str(output_path), "wb") as wave_file:
        wave_file.setnchannels(1)
        wave_file.setsampwidth(2)
        wave_file.setframerate(sample_rate)
        wave_file.writeframes(pcm16_audio.tobytes())


def main() -> None:
    parser = argparse.ArgumentParser(description="Synthesize speech with Kokoro.")
    parser.add_argument("--text", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--voice", default="af_heart")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--lang-code", default="a")
    args = parser.parse_args()

    pipeline = KPipeline(lang_code=args.lang_code)
    segments = list(
        pipeline(
            args.text,
            voice=args.voice,
            speed=args.speed,
            split_pattern=r"\n+",
        )
    )

    if not segments:
        raise RuntimeError("Kokoro did not generate any audio.")

    stitched_audio = np.concatenate([segment_audio for _, _, segment_audio in segments])
    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    write_wav(output_path, stitched_audio, sample_rate=24000)


if __name__ == "__main__":
    main()
