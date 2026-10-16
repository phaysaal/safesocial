package com.spheres.spheres_app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.autoear.v2.api.SegmentWindow
import org.autoear.v2.api.Session
import org.autoear.v2.state.Note
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Notes from this phone's side of a call, made on this phone.
 *
 * A second microphone capture (the call's own goes on untouched) is piped to
 * Android's on-device speech recogniser, which never sends audio anywhere,
 * and each finalised segment of text goes to one AutoEar engine session for
 * the call. What comes back is notes: facts, proposals, decisions, actions,
 * questions, corrections. The transcript is never kept and never logged; the
 * only thing that leaves this object is the notes and, at the end, the
 * engine's summary. Only our own voice is heard: the other party's audio is
 * not captured here.
 *
 * Needs Android 13: that is where the recogniser takes audio from a stream
 * instead of the microphone (with the call holding the microphone, a second
 * recogniser on it would have silenced the call) and reports segments as it
 * goes.
 */
object CallNotes {
    const val CHANNEL = "spheres/notes"
    private const val TAG = "CallNotes"
    private const val RATE = 16_000
    var channel: MethodChannel? = null

    private val main = Handler(Looper.getMainLooper())
    private var session: Session? = null
    private var recognizer: SpeechRecognizer? = null
    private var recorder: AudioRecord? = null
    private var writer: Thread? = null
    @Volatile private var out: OutputStream? = null
    private val running = AtomicBoolean(false)
    private var startedAt = 0L
    private var lastEndMs = 0L
    private var noteCount = 0

    /** Why notes cannot be taken on this phone, or null when they can. */
    fun unavailable(context: Context): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "Needs Android 13 or later"
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            return "This phone has no on-device speech recognition"
        }
        if (context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return "Microphone permission not granted"
        }
        return null
    }

    /** Start taking notes for a call. Returns why it could not, or null. Main thread. */
    fun start(context: Context, callId: String): String? {
        unavailable(context)?.let { return it }
        if (running.get()) return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return "Needs Android 13 or later"
        val minBuf = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) return "No 16 kHz microphone capture on this phone"
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, RATE))
        } catch (e: SecurityException) {
            return "Microphone permission not granted"
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return "The microphone could not be opened a second time"
        }
        session = Session(sessionId = callId)
        noteCount = 0
        startedAt = System.currentTimeMillis()
        lastEndMs = 0
        recorder = rec
        running.set(true)
        rec.startRecording()
        writer = Thread({
            val buf = ByteArray(RATE / 5 * 2) // 200 ms
            while (running.get()) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) continue
                try { out?.write(buf, 0, n) } catch (e: Exception) { /* the pipe is being rotated */ }
            }
        }, "call-notes-audio").also { it.start() }
        listen(context)
        Log.i(TAG, "Notes on")
        return null
    }

    /** One recogniser session on a fresh pipe; rotated whenever one ends while the call goes on. */
    private fun listen(context: Context) {
        if (!running.get() || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val pipe = ParcelFileDescriptor.createPipe()
        val read = pipe[0]
        val previous = out
        out = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
        try { previous?.close() } catch (e: Exception) { }
        recognizer?.destroy()
        val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onResults(results: Bundle?) { take(results); if (running.get()) main.post { listen(context) } }
            override fun onSegmentResults(segmentResults: Bundle) { take(segmentResults) }
            override fun onEndOfSegmentedSession() { if (running.get()) main.post { listen(context) } }
            override fun onError(error: Int) {
                // Codes only; never what was said.
                Log.i(TAG, "Recogniser error $error")
                if (running.get()) main.postDelayed({ listen(context) }, 500)
            }
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, read)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
            putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
        }
        r.startListening(intent)
    }

    /** A finalised segment of our own speech, into the engine. Main thread. */
    private fun take(bundle: Bundle?) {
        val text = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()
        if (text.isNullOrEmpty()) return
        val s = session ?: return
        val now = System.currentTimeMillis() - startedAt
        val window = SegmentWindow(lastEndMs, maxOf(now, lastEndMs))
        lastEndMs = window.endOffsetMs
        val admitted = try {
            s.analyze(text.take(16_000), window, "You").admitted
        } catch (e: Throwable) {
            // The class only: a message could carry the words.
            Log.w(TAG, "Engine failed: ${e.javaClass.simpleName}")
            return
        }
        for (note in admitted) {
            noteCount++
            channel?.invokeMethod("note", toMap(note))
        }
    }

    /** Stop, and hand back everything the engine holds. Main thread. */
    fun stop(): Map<String, Any?> {
        running.set(false)
        try { recorder?.stop() } catch (e: Exception) { }
        recorder?.release(); recorder = null
        try { out?.close() } catch (e: Exception) { }
        out = null
        writer = null
        recognizer?.destroy(); recognizer = null
        val s = session
        session = null
        if (s == null) return mapOf("markdown" to "", "notes" to emptyList<Any>())
        val markdown = try { s.markdown() } catch (e: Throwable) { "" }
        val notes = s.state.notes.values.map { toMap(it) }
        s.close()
        Log.i(TAG, "Notes off: ${notes.size} note(s)")
        return mapOf("markdown" to markdown, "notes" to notes)
    }

    private fun toMap(n: Note): Map<String, Any?> = mapOf(
        "id" to n.id,
        "kind" to n.kind.name,
        "description" to n.description,
        "topic" to n.topicKey,
        "relation" to n.relation,
        "value" to n.value,
        "polarity" to n.polarity,
        "modality" to n.modality,
        "status" to n.status.name,
        "owner" to n.owner,
        "deadline" to n.deadline,
        "uncertain" to n.uncertain,
        "revision" to n.revision,
        "at" to (n.provenance.firstOrNull()?.startOffsetMs ?: 0L),
    )
}
