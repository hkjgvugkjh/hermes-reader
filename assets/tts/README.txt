Place the sherpa-onnx Piper Chinese TTS model here:
  model.onnx
  tokens.txt
  model.onnx.json
  espeak-ng-data.zip   (phonemization data, required for synthesis)

These files are NOT committed to git (they are ~60 MB). Download them with:

  scripts/fetch_tts_model.sh assets/tts

or copy them in manually for offline / CI builds. The model is
piper-zh_CN-huayan-x_low from the k2-fsa/sherpa-onnx releases.
