import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Grace period for playback to begin before we give up on it.
///
/// Only reached on a failure path (audio session refused, or `stop()` landing
/// before the first state update). Normal playback flips `playing` to true
/// synchronously inside `play()`, so this is never hit on the happy path. Kept
/// short so a stop cannot stall narration.
const Duration _startGrace = Duration(seconds: 3);

/// Waits until [player] has finished playing the current source.
///
/// `AudioPlayer.play()` resolves as soon as playback has been *requested*: it
/// only activates the audio session and flips `playing` to true. So a caller
/// that needs to know when an utterance really ended must watch the state
/// stream instead of treating `play()` as completion.
///
/// The narration loop used to sleep a fixed 600 ms after `speak()` returned,
/// which cut every page off mid-sentence and replaced it with the next one —
/// for the bundled/server engines that produced no audible speech at all.
/// Awaiting this instead keeps each page playing to its end.
///
/// Resolves early when playback is stopped, so interrupting narration never
/// leaves the caller suspended.
Future<void> waitForPlaybackEnd(AudioPlayer player) async {
  // Phase 1 — wait until playback actually starts. A clip that already
  // finished before we subscribed matches through `completed`.
  await player.playerStateStream
      .firstWhere(
        (state) =>
            state.playing ||
            state.processingState == ProcessingState.completed,
      )
      .timeout(_startGrace, onTimeout: () => player.playerState);

  // Phase 2 — wait until it stops. Covers both natural completion and an
  // explicit stop()/pause, since both clear `playing`.
  await player.playerStateStream.firstWhere(
    (state) =>
        state.processingState == ProcessingState.completed || !state.playing,
  );
}
