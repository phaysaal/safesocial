# Notes from your side of a call

Spheres can turn what *you* say in a call into notes, on the phone, with nothing
sent anywhere. It is off by default (Settings, Network, "Notes from your side of a
call") and says before it is turned on what it is and is not.

## How it starts and ends

A notes button in the call turns notes on for both phones: the call signalling carries
one `call_notes` line, the other phone starts its own notes, and each screen's chip says
who began. The setting "Notes from your side of a call" does the same at every connect.
Each phone only ever notes its own voice. When the call ends, a phone that has notes is
asked once whether to send them to the other person; a yes sends the summary (or the
notes as lines) as an ordinary chat message, marked as engine-made and possibly wrong.

## Times and the other side's notes

Every note carries the clock time it was said: the engine gives its offset into the
notes and the phone knows when they began. What is sent to the other person is a
`call_notes` chat message whose payload holds the notes with their times and the span
of the notes; the text of the message is the summary, so an older client still reads
it. The receiving phone matches the message to its own record of the call by that span,
with two minutes of slack either way for clocks that disagree, and the notes screen
shows both sides as one list in the order things were said, theirs labelled with their
name and left exactly as sent, ours editable.

## What it is

- **Your voice only.** A second microphone capture runs beside the call's own and is
  piped to Android's on-device speech recogniser (`SpeechRecognizer` created with
  `createOnDeviceSpeechRecognizer`, fed through `EXTRA_AUDIO_SOURCE` in a segmented
  session). The other person is not recorded, and the recogniser never leaves the
  phone. Needs Android 13: that is where the recogniser takes a stream instead of the
  microphone, which the call already holds. Elsewhere the switch says why not.
- **The engine is AutoEar v2**, a pure-JVM Kotlin library (no Android, no network) that
  turns English transcript text into notes by dictionary, grammar, a checker and an
  admission rule. It is deterministic. It is not a language model. One `Session` per
  call takes each finalised segment with its time window and the speaker "You"; what
  comes back is notes of kind fact, proposal, decision, action, question or correction,
  and at the end `markdown()`, an extractive summary grouped by topic.
- **What is kept:** the notes and the summary, sealed under the call's log entry
  (`spheres_call_notes_v1`). The transcript is never stored, never logged and never
  crosses the platform channel; the Kotlin side logs counts and error codes only.
- **What it is not:** finished note-taking. On the engine's own meeting benchmark about
  one admitted note in seven does not match what was said and most expected outcomes
  are missed. Every note is shown as engine-made and uncertain, and can be edited or
  deleted; the person's edit is kept over the engine's words.

## Where the code is

| Piece | Path |
|---|---|
| Engine jar | `safesocial_app/android/app/libs/autoear-engine.jar` (sha256 starts `8348b00a6c7f1344`) |
| Kotlin bridge | `android/app/src/main/kotlin/com/spheres/spheres_app/CallNotes.kt`, channel `spheres/notes` |
| JVM test | `android/app/src/test/kotlin/com/spheres/spheres_app/CallNotesEngineTest.kt` |
| Dart service | `lib/services/call_notes_service.dart` |
| Screens | `lib/screens/call/call_notes_screen.dart`; the chip on `call_screen.dart`; the icon on `call_history_screen.dart` |
| Shrink rules | `android/app/proguard-rules.pro` (keeps the engine and its serializers) |

The jar is built from the AutoEar repository (`v2/engine`, engine source hash
`d1ab0fd2` at the time of copying) with:

```bash
cd ~/code/hobby/AutoEar
export JAVA_HOME=~/app/android-studio-panda2-linux/android-studio/jbr GRADLE_USER_HOME=~/.gradle
./gradlew :v2:engine:test :v2:engine:jar --offline
cp v2/engine/build/libs/engine.jar ~/code/hobby/SafeSelf/safesocial/safesocial_app/android/app/libs/autoear-engine.jar
```

Its runtime needs are the Kotlin standard library (the app's own, 2.2.20) and
`kotlinx-serialization-json` 1.6.3, declared in `build.gradle.kts`. The dictionary is
derived from WordNet 3.1 (Princeton); its notice ships inside the jar.

```bash
cd safesocial_app/android && ./gradlew :app:testFossDebugUnitTest   # the engine test
```

## Rules kept

From the AutoEar project: local only, never a remote fallback; no logging of speech,
notes or exception messages that could carry words; notes are the only thing
persisted; source spans and review items stay in the engine and are dropped at the
end of the call; never described as finished.
